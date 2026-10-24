import Foundation
import NotchShell

/// Connects coding agents to NotchPilot by adding a tiny hook script to their
/// config files. Every entry NotchPilot adds references `notch-agent-hook`, so
/// disconnecting removes exactly those entries and nothing else.
struct HookInstaller: Sendable {
    enum Status: Equatable, Sendable {
        case notInstalled          // the agent isn't on this Mac
        case disconnected
        case connected
        case conflict(String)      // can't connect automatically; message explains why
    }

    enum InstallError: Error, Equatable {
        case unreadableConfig(String)
        case conflict(String)
    }

    static let marker = "notch-agent-hook"

    let home: URL
    let eventsDirectory: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, eventsDirectory: URL) {
        self.home = home
        self.eventsDirectory = eventsDirectory
    }

    /// Lives in a path without spaces because some agents run hook commands without a shell.
    var scriptURL: URL { home.appendingPathComponent(".notch/\(Self.marker)") }

    private var claudeSettings: URL { home.appendingPathComponent(".claude/settings.json") }
    private var codexConfig: URL { home.appendingPathComponent(".codex/config.toml") }
    private var cursorHooks: URL { home.appendingPathComponent(".cursor/hooks.json") }

    static let claudeEvents: [(event: String, matcher: String?)] = [
        ("SessionStart", nil), ("UserPromptSubmit", nil), ("PostToolUse", "*"), ("Notification", nil),
        ("Stop", nil), ("StopFailure", nil), ("SessionEnd", nil),
    ]
    static let cursorEvents = ["beforeSubmitPrompt", "stop", "sessionEnd"]

    // MARK: - Status

    func status(_ agent: AgentKind) -> Status {
        let fm = FileManager.default
        switch agent {
        case .claude:
            guard fm.fileExists(atPath: home.appendingPathComponent(".claude").path) else { return .notInstalled }
            return fileMentionsMarker(claudeSettings) ? .connected : .disconnected
        case .codex:
            guard fm.fileExists(atPath: home.appendingPathComponent(".codex").path) else { return .notInstalled }
            if fileMentionsMarker(codexConfig) { return .connected }
            if let text = try? String(contentsOf: codexConfig, encoding: .utf8), Self.topLevelNotifyLine(in: text) != nil {
                return .conflict("Codex already runs another notify command. Only one is allowed, so \(AppInfo.name) left it alone.")
            }
            return .disconnected
        case .cursor:
            guard fm.fileExists(atPath: home.appendingPathComponent(".cursor").path) else { return .notInstalled }
            return fileMentionsMarker(cursorHooks) ? .connected : .disconnected
        }
    }

    private func fileMentionsMarker(_ url: URL) -> Bool {
        (try? String(contentsOf: url, encoding: .utf8))?.contains(Self.marker) ?? false
    }

    // MARK: - Connect / disconnect

    func connect(_ agent: AgentKind) throws {
        try installScript()
        switch agent {
        case .claude: try editJSON(claudeSettings) { Self.addingClaudeHooks(to: $0, command: scriptURL.path) }
        case .codex: try connectCodex()
        case .cursor: try editJSON(cursorHooks) { Self.addingCursorHooks(to: $0, command: scriptURL.path) }
        }
    }

    func disconnect(_ agent: AgentKind) throws {
        switch agent {
        case .claude: try editJSON(claudeSettings) { Self.removingClaudeHooks(from: $0) }
        case .codex:
            guard let text = try? String(contentsOf: codexConfig, encoding: .utf8) else { return }
            try Self.removingCodexNotify(from: text).write(to: codexConfig, atomically: true, encoding: .utf8)
        case .cursor: try editJSON(cursorHooks) { Self.removingCursorHooks(from: $0) }
        }
    }

    /// Rewrites the script so an updated app ships an updated hook.
    func refreshScriptIfConnected() {
        guard AgentKind.allCases.contains(where: { status($0) == .connected }) else { return }
        try? installScript()
    }

    func installScript() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)
        try Self.script(eventsDirectory: eventsDirectory.path).write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    static func script(eventsDirectory: String) -> String {
        """
        #!/bin/sh
        # Installed by \(AppInfo.name): forwards coding-agent events to the \(AppInfo.name) island.
        # Disconnect in \(AppInfo.name) → Settings → AI, or delete this file; agents ignore a missing hook.
        agent="$1"; event="$2"; payload="$3"
        dir='\(eventsDirectory.replacingOccurrences(of: "'", with: "'\\''"))'
        if [ "$agent" = cursor ] && [ "$event" = beforeSubmitPrompt ]; then printf '{"continue":true}'; fi
        [ -d "$dir" ] || { [ -n "$payload" ] || cat >/dev/null; exit 0; }
        clean() { printf '%s' "$1" | tr -cd 'A-Za-z0-9._-'; }
        tmp=$(mktemp "$dir/.event.XXXXXX") || exit 0
        {
          printf '{"agent":"%s","event":"%s","time":%s,"app":"%s"}\\n' \\
            "$(clean "$agent")" "$(clean "$event")" "$(date +%s)" "$(clean "${__CFBundleIdentifier:-}")"
          if [ -n "$payload" ]; then printf '%s' "$payload"; else cat; fi
        } > "$tmp" 2>/dev/null
        mv "$tmp" "$dir/event${tmp##*/.event}.json"
        exit 0

        """
    }

    // MARK: - JSON configs (Claude Code, Cursor)

    private func editJSON(_ url: URL, _ transform: ([String: Any]) -> [String: Any]) throws {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw InstallError.unreadableConfig("\(url.path) isn't valid JSON, so \(AppInfo.name) didn't change it.")
            }
            root = parsed
            // Keep one copy of the user's original file.
            let backup = url.appendingPathExtension("notch-backup")
            if !FileManager.default.fileExists(atPath: backup.path) { try? data.write(to: backup) }
        }
        let updated = transform(root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: updated,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    static func addingClaudeHooks(to root: [String: Any], command: String) -> [String: Any] {
        var root = removingClaudeHooks(from: root)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, matcher) in claudeEvents {
            var groups = hooks[event] as? [Any] ?? []
            var group: [String: Any] = [
                "hooks": [["type": "command", "command": "\(command) claude \(event)", "async": true, "timeout": 10]],
            ]
            if let matcher { group["matcher"] = matcher }
            groups.append(group)
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return root
    }

    static func removingClaudeHooks(from root: [String: Any]) -> [String: Any] {
        guard var hooks = root["hooks"] as? [String: Any] else { return root }
        var root = root
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            let kept: [Any] = groups.compactMap { item in
                guard var group = item as? [String: Any], let handlers = group["hooks"] as? [Any] else { return item }
                let remaining = handlers.filter { !(($0 as? [String: Any])?["command"] as? String ?? "").contains(marker) }
                if remaining.isEmpty { return nil }
                group["hooks"] = remaining
                return group
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        return root
    }

    static func addingCursorHooks(to root: [String: Any], command: String) -> [String: Any] {
        var root = removingCursorHooks(from: root)
        if root["version"] == nil { root["version"] = 1 }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in cursorEvents {
            var list = hooks[event] as? [Any] ?? []
            list.append(["command": "\(command) cursor \(event)"])
            hooks[event] = list
        }
        root["hooks"] = hooks
        return root
    }

    static func removingCursorHooks(from root: [String: Any]) -> [String: Any] {
        guard var hooks = root["hooks"] as? [String: Any] else { return root }
        var root = root
        for (event, value) in hooks {
            guard let list = value as? [Any] else { continue }
            let kept = list.filter { !(($0 as? [String: Any])?["command"] as? String ?? "").contains(marker) }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        root["hooks"] = hooks
        return root
    }

    // MARK: - Codex (TOML)

    private func connectCodex() throws {
        let text = (try? String(contentsOf: codexConfig, encoding: .utf8)) ?? ""
        let cleaned = Self.removingCodexNotify(from: text)
        if Self.topLevelNotifyLine(in: cleaned) != nil {
            throw InstallError.conflict("Codex already runs another notify command. Only one is allowed, so \(AppInfo.name) left it alone.")
        }
        if !text.isEmpty {
            let backup = codexConfig.appendingPathExtension("notch-backup")
            if !FileManager.default.fileExists(atPath: backup.path) { try? text.write(to: backup, atomically: true, encoding: .utf8) }
        }
        try Self.addingCodexNotify(to: cleaned, command: scriptURL.path)
            .write(to: codexConfig, atomically: true, encoding: .utf8)
    }

    /// Top-level keys must come before the first [table], so NotchPilot's line goes first.
    static func addingCodexNotify(to text: String, command: String) -> String {
        "notify = [\"\(command)\", \"codex\", \"agent-turn-complete\"] # added by \(AppInfo.name)\n" + text
    }

    static func removingCodexNotify(from text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains(marker) }
            .joined(separator: "\n")
    }

    /// The line number of a `notify = …` key outside any table, if present.
    static func topLevelNotifyLine(in text: String) -> Int? {
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { return nil }
            if line.hasPrefix("notify"), line.dropFirst(6).trimmingCharacters(in: .whitespaces).hasPrefix("=") {
                return index
            }
        }
        return nil
    }
}
