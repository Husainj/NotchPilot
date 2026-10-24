import Foundation

/// Reads Claude Code transcripts and Codex session logs incrementally:
/// each file is parsed once and later scans read only the bytes appended
/// since. Only files touched in the last 8 days are considered.
actor UsageScanner {
    private struct FileState {
        var offset: UInt64 = 0
        var claude: [String: UsageEntry] = [:]
        var codex: [(date: Date, tokens: Int)] = []
        var codexTotal = 0
        var codexLimits: CodexLimits?
    }

    private var files: [URL: FileState] = [:]
    private let home: URL
    private static let lookback: TimeInterval = 8 * 86400

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    var claudeRoots: [URL] {
        [home.appendingPathComponent(".claude/projects"), home.appendingPathComponent(".config/claude/projects")]
    }

    var codexRoot: URL { home.appendingPathComponent(".codex/sessions") }

    func scan(now: Date = Date()) -> UsageSnapshot {
        let cutoff = now.addingTimeInterval(-Self.lookback)
        let claudeFiles = claudeRoots.flatMap { Self.jsonlFiles(under: $0, modifiedAfter: cutoff) }
        let codexFiles = Self.jsonlFiles(under: codexRoot, modifiedAfter: cutoff)
        let live = Set(claudeFiles + codexFiles)
        files = files.filter { live.contains($0.key) }

        for url in claudeFiles { update(url, parser: Self.parseClaudeLine) }
        for url in codexFiles { update(url, parser: Self.parseCodexLine) }

        // Resumed sessions copy earlier messages into a new file, so dedupe across files.
        var claude: [String: UsageEntry] = [:]
        var codex: [(date: Date, tokens: Int)] = []
        var limits: CodexLimits?
        for url in claudeFiles { claude.merge(files[url]?.claude ?? [:]) { a, _ in a } }
        for url in codexFiles {
            guard let state = files[url] else { continue }
            codex += state.codex
            if let l = state.codexLimits, l.observedAt > (limits?.observedAt ?? .distantPast) { limits = l }
        }
        let hasClaude = claudeRoots.contains { FileManager.default.fileExists(atPath: $0.path) }
        let hasCodex = FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path)
        return UsageSnapshot.make(claude: claude.values.filter { $0.date >= cutoff }, codex: codex,
                                  codexLimits: limits, hasClaude: hasClaude, hasCodex: hasCodex, now: now)
    }

    // MARK: - Files

    private static func jsonlFiles(under root: URL, modifiedAfter cutoff: Date) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, (values?.contentModificationDate ?? .distantPast) >= cutoff else { continue }
            result.append(url)
        }
        return result
    }

    private func update(_ url: URL, parser: (Substring, inout FileState) -> Void) {
        var state = files[url] ?? FileState()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < state.offset { state = FileState() } // truncated or replaced
        guard size > state.offset else { files[url] = state; return }
        try? handle.seek(toOffset: state.offset)
        guard let data = try? handle.readToEnd(), let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
            files[url] = state
            return
        }
        // Only consume complete lines; a half-written last line is read next time.
        let complete = data[data.startIndex...lastNewline]
        state.offset += UInt64(complete.count)
        let text = String(decoding: complete, as: UTF8.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            parser(line, &state)
        }
        files[url] = state
    }

    // MARK: - Parsing

    private static func parseClaudeLine(_ line: Substring, _ state: inout FileState) {
        guard let (key, entry) = parseClaude(line) else { return }
        state.claude[key] = entry
    }

    /// Returns a dedupe key and entry for an assistant message with usage.
    /// Claude Code writes one line per content block, all repeating the same usage.
    static func parseClaude(_ line: Substring) -> (String, UsageEntry)? {
        guard line.contains("\"usage\""), line.contains("\"assistant\"") else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let timestamp = object["timestamp"] as? String,
              let date = parseDate(timestamp) else { return nil }
        let model = message["model"] as? String ?? "unknown"
        guard model != "<synthetic>" else { return nil }

        func int(_ dict: [String: Any]?, _ key: String) -> Int { (dict?[key] as? NSNumber)?.intValue ?? 0 }
        var tokens = TokenUsage(input: int(usage, "input_tokens"), output: int(usage, "output_tokens"),
                                cacheRead: int(usage, "cache_read_input_tokens"))
        let creation = int(usage, "cache_creation_input_tokens")
        if let split = usage["cache_creation"] as? [String: Any] {
            tokens.cacheWrite1h = int(split, "ephemeral_1h_input_tokens")
            tokens.cacheWrite5m = max(creation - tokens.cacheWrite1h, int(split, "ephemeral_5m_input_tokens"))
        } else {
            tokens.cacheWrite5m = creation
        }
        guard tokens.total > 0 else { return nil }

        let messageID = message["id"] as? String ?? object["uuid"] as? String ?? UUID().uuidString
        let key = messageID + ":" + (object["requestId"] as? String ?? "")
        return (key, UsageEntry(date: date, model: model, usage: tokens))
    }

    private static func parseCodexLine(_ line: Substring, _ state: inout FileState) {
        guard line.contains("\"token_count\"") else { return }
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let date = (object["timestamp"] as? String).flatMap(parseDate) else { return }

        if let info = payload["info"] as? [String: Any] {
            // Totals are cumulative per session; the delta is this turn's usage.
            // Repeated events with an unchanged total are skipped.
            if let total = (info["total_token_usage"] as? [String: Any])?["total_tokens"] as? NSNumber {
                let delta = total.intValue - state.codexTotal
                if delta > 0 { state.codex.append((date, delta)) }
                state.codexTotal = max(state.codexTotal, total.intValue)
            } else if let last = (info["last_token_usage"] as? [String: Any])?["total_tokens"] as? NSNumber {
                state.codex.append((date, last.intValue))
            }
        }
        if let limits = payload["rate_limits"] as? [String: Any] {
            state.codexLimits = CodexLimits(primary: parseCodexLimit(limits["primary"], observed: date),
                                            secondary: parseCodexLimit(limits["secondary"], observed: date),
                                            observedAt: date)
        }
    }

    static func parseCodexLimit(_ value: Any?, observed: Date) -> CodexLimit? {
        guard let dict = value as? [String: Any], let used = dict["used_percent"] as? NSNumber else { return nil }
        var resets: Date?
        if let at = dict["resets_at"] as? NSNumber {
            resets = Date(timeIntervalSince1970: at.doubleValue)
        } else if let inSeconds = (dict["resets_in_seconds"] ?? dict["resets_after_seconds"]) as? NSNumber {
            resets = observed.addingTimeInterval(inSeconds.doubleValue)
        }
        return CodexLimit(usedPercent: used.doubleValue, windowMinutes: (dict["window_minutes"] as? NSNumber)?.intValue ?? 300,
                          resetsAt: resets)
    }

    static func parseDate(_ string: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string))
            ?? (try? Date.ISO8601FormatStyle().parse(string))
    }
}
