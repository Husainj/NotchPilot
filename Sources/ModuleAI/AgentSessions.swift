import Foundation

enum AgentKind: String, Sendable, CaseIterable {
    case claude, codex, cursor

    var name: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }

    var shortName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }

    var symbol: String {
        switch self {
        case .claude: "asterisk"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .cursor: "cursorarrow.rays"
        }
    }
}

/// One hook invocation forwarded by `notch-agent-hook`.
/// File format: a metadata JSON line written by the script, then the agent's own payload.
struct AgentEvent: Equatable, Sendable {
    var agent: AgentKind
    var name: String
    var date: Date
    var sessionID: String
    var cwd: String?
    /// Bundle id of the app the agent runs in (Terminal, iTerm, VS Code, Cursor…).
    var appBundleID: String?
    var notificationType: String?
    var message: String?
    var status: String?

    static func parse(_ data: Data, fallbackDate: Date) -> AgentEvent? {
        let text = String(decoding: data, as: UTF8.self)
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let header = parts.first,
              let meta = try? JSONSerialization.jsonObject(with: Data(header.utf8)) as? [String: Any],
              let agent = (meta["agent"] as? String).flatMap(AgentKind.init(rawValue:)) else { return nil }
        let body = parts.count > 1 ? Data(parts[1].utf8) : Data()
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]

        var name = meta["event"] as? String ?? ""
        if name.isEmpty { name = payload["hook_event_name"] as? String ?? payload["type"] as? String ?? "" }
        let date = (meta["time"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? fallbackDate
        let app = (meta["app"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        let cwd = payload["cwd"] as? String ?? (payload["workspace_roots"] as? [String])?.first
        let sessionID = payload["session_id"] as? String
            ?? payload["conversation_id"] as? String
            ?? payload["thread-id"] as? String
            ?? cwd
            ?? agent.rawValue
        let message = payload["message"] as? String
            ?? payload["last_assistant_message"] as? String
            ?? payload["last-assistant-message"] as? String
        return AgentEvent(agent: agent, name: name, date: date, sessionID: sessionID, cwd: cwd, appBundleID: app,
                          notificationType: payload["notification_type"] as? String, message: message,
                          status: payload["status"] as? String)
    }
}

struct AgentSession: Equatable, Sendable, Identifiable {
    enum Status: Equatable, Sendable {
        case working, needsInput, done, failed, idle
    }

    let agent: AgentKind
    let sessionID: String
    var cwd: String?
    var appBundleID: String?
    var status: Status
    /// When the current status began.
    var since: Date
    var lastEvent: Date
    var message: String?

    var id: String { agent.rawValue + ":" + sessionID }

    var project: String {
        guard let cwd, !cwd.isEmpty else { return agent.name }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }
}

/// Pure state machine from hook events to live sessions, so it can be tested.
struct SessionBoard: Equatable, Sendable {
    enum Alert: Equatable, Sendable {
        case needsInput(AgentSession)
        case finished(AgentSession, workedFor: TimeInterval)
        case failed(AgentSession)
    }

    private(set) var sessions: [String: AgentSession] = [:]

    var sorted: [AgentSession] {
        sessions.values.sorted { a, b in
            if a.status.rank != b.status.rank { return a.status.rank < b.status.rank }
            return a.lastEvent > b.lastEvent
        }
    }

    @discardableResult
    mutating func apply(_ event: AgentEvent) -> Alert? {
        let key = event.agent.rawValue + ":" + event.sessionID
        var session = sessions[key] ?? AgentSession(agent: event.agent, sessionID: event.sessionID, cwd: event.cwd,
                                                    appBundleID: event.appBundleID, status: .idle,
                                                    since: event.date, lastEvent: event.date)
        if let cwd = event.cwd { session.cwd = cwd }
        if let app = event.appBundleID { session.appBundleID = app }
        session.lastEvent = max(session.lastEvent, event.date)
        let previous = session

        func set(_ status: AgentSession.Status, message: String? = nil) {
            if session.status != status { session.since = event.date }
            session.status = status
            session.message = message
        }

        var alert: Alert?
        switch Self.classify(event) {
        case .ignore:
            return nil
        case .end:
            sessions[key] = nil
            return nil
        case .ready:
            set(.idle)
        case .working:
            set(.working)
        case .needsInput:
            set(.needsInput, message: event.message)
            if previous.status != .needsInput { alert = .needsInput(session) }
        case .done:
            set(.done, message: event.message.map(Self.firstLine))
            // Codex only reports turn completion, so treat a fresh session as having worked.
            if previous.status == .working || previous.status == .needsInput || event.agent == .codex {
                let started = previous.status == .working ? previous.since : event.date
                alert = .finished(session, workedFor: event.date.timeIntervalSince(started))
            }
        case .failed:
            set(.failed, message: event.message.map(Self.firstLine))
            alert = .failed(session)
        case .waiting:
            // "Claude is waiting for your input" after a finished turn: no new alert.
            if session.status != .done { set(.idle) }
        }
        sessions[key] = session
        return alert
    }

    /// Drops sessions that went quiet (closed terminals don't always send an end event).
    mutating func prune(now: Date) {
        sessions = sessions.filter { _, s in
            let quiet = now.timeIntervalSince(s.lastEvent)
            switch s.status {
            case .working: return quiet < 90 * 60 // long builds/tests send no events
            case .needsInput: return quiet < 2 * 3600
            case .done, .failed, .idle: return quiet < 3 * 3600
            }
        }
    }

    mutating func dismiss(_ id: String) {
        sessions[id] = nil
    }

    private enum Effect { case ignore, end, ready, working, needsInput, done, failed, waiting }

    private static func classify(_ e: AgentEvent) -> Effect {
        switch (e.agent, e.name) {
        case (.claude, "SessionStart"): return .ready
        case (.claude, "UserPromptSubmit"), (.claude, "PostToolUse"), (.claude, "PreCompact"): return .working
        case (.claude, "Stop"): return .done
        case (.claude, "StopFailure"): return .failed
        case (.claude, "SessionEnd"): return .end
        case (.claude, "Notification"):
            switch e.notificationType {
            case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input": return .needsInput
            case "idle_prompt": return .waiting
            case nil:
                let text = (e.message ?? "").lowercased()
                if text.contains("permission") || text.contains("approve") { return .needsInput }
                if text.contains("waiting for your input") { return .waiting }
                return .ignore
            default: return .ignore
            }
        case (.codex, _):
            return e.name == "agent-turn-complete" || e.name == "turn-complete" ? .done : .ignore
        case (.cursor, "beforeSubmitPrompt"): return .working
        case (.cursor, "stop"):
            switch e.status {
            case "error": return .failed
            case "aborted": return .ready
            default: return .done
            }
        case (.cursor, "sessionEnd"): return .end
        default: return .ignore
        }
    }

    private static func firstLine(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
        return String(line.prefix(140))
    }
}

private extension AgentSession.Status {
    var rank: Int {
        switch self {
        case .needsInput: 0
        case .working: 1
        case .failed: 2
        case .done: 3
        case .idle: 4
        }
    }
}
