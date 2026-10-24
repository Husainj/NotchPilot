import Foundation
import Testing
@testable import ModuleAI

private func date(_ s: String) -> Date { UsageScanner.parseDate(s)! }

// MARK: - Usage

@Test func parsesClaudeTranscriptLine() throws {
    let line = #"{"type":"assistant","timestamp":"2026-10-09T05:49:58.504Z","requestId":"req_1","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_creation_input_tokens":20580,"cache_read_input_tokens":13895,"output_tokens":232,"cache_creation":{"ephemeral_1h_input_tokens":20000,"ephemeral_5m_input_tokens":580}}}}"#
    let (key, entry) = try #require(UsageScanner.parseClaude(Substring(line)))
    #expect(key == "msg_1:req_1")
    #expect(entry.model == "claude-opus-5-5")
    #expect(entry.usage == TokenUsage(input: 2, output: 232, cacheWrite5m: 580, cacheWrite1h: 20000, cacheRead: 13895))
    // 2*4 + 232*20 + 580*5 + 20000*8 + 13895*0.4, per million
    #expect(abs(entry.cost - 0.1731) < 0.0001)
    #expect(UsageScanner.parseClaude(#"{"type":"user","message":{"content":"usage"}}"#) == nil)
}

@Test func pricingByModelFamily() {
    #expect(ModelPricing.claude("claude-opus-5-5") == ModelPricing(input: 4, output: 20))
    #expect(ModelPricing.claude("claude-sonnet-5") == ModelPricing(input: 2, output: 10))
    #expect(ModelPricing.claude("claude-sonnet-4-5-20250929") == ModelPricing(input: 3, output: 15))
    #expect(ModelPricing.claude("claude-opus-4-1-20250805") == ModelPricing(input: 15, output: 75))
    #expect(ModelPricing.claude("claude-haiku-4-5") == ModelPricing(input: 1, output: 5))
    #expect(UsageFormat.modelName("claude-opus-5-5") == "Opus 5.5")
    #expect(UsageFormat.modelName("claude-sonnet-4-5-20250929") == "Sonnet 4.5")
}

@Test func fiveHourBlocks() {
    let usage = TokenUsage(input: 1_000_000)
    let entries = [
        UsageEntry(date: date("2026-10-09T09:20:00Z"), model: "claude-sonnet-5", usage: usage),
        UsageEntry(date: date("2026-10-09T13:59:00Z"), model: "claude-sonnet-5", usage: usage), // same window (09:00–14:00)
        UsageEntry(date: date("2026-10-09T14:05:00Z"), model: "claude-sonnet-5", usage: usage), // new window from 14:00
    ]
    let blocks = UsageBlock.blocks(from: entries)
    #expect(blocks.count == 2)
    #expect(blocks[0].start == date("2026-10-09T09:00:00Z"))
    #expect(blocks[0].cost == 4)
    #expect(blocks[1].start == date("2026-10-09T14:00:00Z"))
    #expect(blocks[1].end == date("2026-10-09T19:00:00Z"))

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let snapshot = UsageSnapshot.make(claude: entries, codex: [(date("2026-10-08T10:00:00Z"), 500)], codexLimits: nil,
                                      hasClaude: true, hasCodex: true, now: date("2026-10-09T15:00:00Z"), calendar: calendar)
    #expect(snapshot.currentBlock?.start == date("2026-10-09T14:00:00Z"))
    #expect(snapshot.peakBlockCost == 4)
    #expect(snapshot.todayCost == 6)
    #expect(snapshot.days.count == 7)
    #expect(snapshot.days[5].codexTokens == 500)
    #expect(snapshot.codexTodayTokens == 0)
}

@Test func scansClaudeAndCodexLogsIncrementally() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("notch-ai-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let project = home.appendingPathComponent(".claude/projects/-tmp-demo")
    let codexDay = home.appendingPathComponent(".codex/sessions/2026/10/09")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: codexDay, withIntermediateDirectories: true)

    let now = Date()
    let ts = now.addingTimeInterval(-60).formatted(.iso8601)
    func claudeLine(_ id: String) -> String {
        #"{"type":"assistant","timestamp":"\#(ts)","requestId":"r","message":{"id":"\#(id)","model":"claude-sonnet-5","usage":{"input_tokens":1000000,"output_tokens":0}}}"#
    }
    let transcript = project.appendingPathComponent("s.jsonl")
    // The duplicate line (same message id) must count once.
    try (claudeLine("a") + "\n" + claudeLine("a") + "\n").write(to: transcript, atomically: true, encoding: .utf8)

    let resets = Int(now.timeIntervalSince1970) + 3600
    let codex = """
    {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":300}},"rate_limits":{"primary":{"used_percent":42.5,"window_minutes":300,"resets_at":\(resets)},"secondary":{"used_percent":10,"window_minutes":10080,"resets_in_seconds":7200}}}}
    {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":300}}}}
    {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":1000}}}}

    """
    try codex.write(to: codexDay.appendingPathComponent("rollout-1.jsonl"), atomically: true, encoding: .utf8)

    let scanner = UsageScanner(home: home)
    var snapshot = await scanner.scan(now: now)
    #expect(snapshot.hasClaude && snapshot.hasCodex)
    #expect(snapshot.today.input == 1_000_000)
    #expect(snapshot.todayCost == 2)
    #expect(snapshot.codexTodayTokens == 1000)
    #expect(snapshot.codexLimits?.primary?.usedPercent == 42.5)
    #expect(snapshot.codexLimits?.primary?.resetsAt == Date(timeIntervalSince1970: Double(resets)))
    #expect(snapshot.codexLimits?.secondary?.label == "Week")

    // Appending a new message (and a half-written line) only adds the complete line.
    let handle = try FileHandle(forWritingTo: transcript)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((claudeLine("b") + "\n" + #"{"type":"assist"#).utf8))
    try handle.close()
    snapshot = await scanner.scan(now: now)
    #expect(snapshot.todayCost == 4)
}

// MARK: - Sessions

private func event(_ agent: AgentKind, _ name: String, at seconds: TimeInterval, session: String = "s1",
                   type: String? = nil, message: String? = nil, status: String? = nil) -> AgentEvent {
    AgentEvent(agent: agent, name: name, date: Date(timeIntervalSince1970: seconds), sessionID: session,
               cwd: "/Users/me/Projects/notch", appBundleID: "com.apple.Terminal",
               notificationType: type, message: message, status: status)
}

@Test func claudeSessionLifecycle() throws {
    var board = SessionBoard()
    #expect(board.apply(event(.claude, "SessionStart", at: 0)) == nil)
    #expect(board.sorted.first?.status == .idle)
    #expect(board.apply(event(.claude, "UserPromptSubmit", at: 10)) == nil)
    #expect(board.sorted.first?.status == .working)
    #expect(board.sorted.first?.project == "notch")

    guard case .needsInput = board.apply(event(.claude, "Notification", at: 20, type: "permission_prompt",
                                               message: "Claude needs your permission to use Bash")) else {
        Issue.record("expected needsInput alert"); return
    }
    // Approving resumes work; the working timer keeps the original start only per status.
    #expect(board.apply(event(.claude, "PostToolUse", at: 30)) == nil)
    #expect(board.sorted.first?.status == .working)

    guard case .finished(let s, let worked) = board.apply(event(.claude, "Stop", at: 90, message: "All done.\nDetails…")) else {
        Issue.record("expected finished alert"); return
    }
    #expect(s.message == "All done.")
    #expect(worked == 60)
    // The idle reminder after a finished turn doesn't alert or change state.
    #expect(board.apply(event(.claude, "Notification", at: 150, type: "idle_prompt")) == nil)
    #expect(board.sorted.first?.status == .done)
    board.apply(event(.claude, "SessionEnd", at: 200))
    #expect(board.sorted.isEmpty)
}

@Test func cursorAndCodexEvents() {
    var board = SessionBoard()
    board.apply(event(.cursor, "beforeSubmitPrompt", at: 0, session: "c1"))
    if case .failed = board.apply(event(.cursor, "stop", at: 5, session: "c1", status: "error")) {} else {
        Issue.record("expected failure")
    }
    if case .finished = board.apply(event(.codex, "agent-turn-complete", at: 6, session: "x")) {} else {
        Issue.record("expected Codex completion")
    }
    #expect(board.sorted.count == 2)
    board.prune(now: Date(timeIntervalSince1970: 4 * 3600))
    #expect(board.sorted.isEmpty)
}

@Test func parsesHookEventFiles() throws {
    let claude = Data("""
    {"agent":"claude","event":"Notification","time":1760000000,"app":"com.googlecode.iterm2"}
    {"session_id":"abc","cwd":"/tmp/demo","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Needs permission"}
    """.utf8)
    let e = try #require(AgentEvent.parse(claude, fallbackDate: Date()))
    #expect(e.agent == .claude && e.name == "Notification" && e.sessionID == "abc")
    #expect(e.appBundleID == "com.googlecode.iterm2" && e.notificationType == "permission_prompt")

    let codex = Data("""
    {"agent":"codex","event":"agent-turn-complete","time":1760000000,"app":""}
    {"type":"agent-turn-complete","thread-id":"t1","cwd":"/tmp/x","last-assistant-message":"Fixed it"}
    """.utf8)
    let c = try #require(AgentEvent.parse(codex, fallbackDate: Date()))
    #expect(c.sessionID == "t1" && c.message == "Fixed it" && c.appBundleID == nil)

    let cursor = Data((#"{"agent":"cursor","event":"stop","time":1,"app":"x"}"# + "\n"
        + #"{"conversation_id":"k","workspace_roots":["/w/app"],"status":"completed"}"#).utf8)
    let k = try #require(AgentEvent.parse(cursor, fallbackDate: Date()))
    #expect(k.sessionID == "k" && k.cwd == "/w/app" && k.status == "completed")
    #expect(AgentEvent.parse(Data("garbage".utf8), fallbackDate: Date()) == nil)
}

// MARK: - Installer

@Test func claudeHooksMergeAndRemoveCleanly() throws {
    let existing: [String: Any] = [
        "theme": "dark",
        "hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]],
    ]
    let added = HookInstaller.addingClaudeHooks(to: existing, command: "/h/.notch/notch-agent-hook")
    let hooks = try #require(added["hooks"] as? [String: Any])
    #expect((hooks["Stop"] as? [Any])?.count == 2)
    #expect(hooks.keys.count == HookInstaller.claudeEvents.count)
    // Connecting twice doesn't duplicate.
    let again = HookInstaller.addingClaudeHooks(to: added, command: "/h/.notch/notch-agent-hook")
    #expect(((again["hooks"] as? [String: Any])?["Stop"] as? [Any])?.count == 2)

    let removed = HookInstaller.removingClaudeHooks(from: again)
    #expect(removed["theme"] as? String == "dark")
    let left = try #require(removed["hooks"] as? [String: Any])
    #expect(Array(left.keys) == ["Stop"])
    let data = try JSONSerialization.data(withJSONObject: removed)
    #expect(String(decoding: data, as: UTF8.self).contains("say done"))
}

@Test func codexNotifyEditing() {
    let config = "model = \"gpt-5\"\n\n[profiles.fast]\nnotify = [\"x\"]\n"
    #expect(HookInstaller.topLevelNotifyLine(in: config) == nil) // notify inside a table doesn't count
    let added = HookInstaller.addingCodexNotify(to: config, command: "/h/.notch/notch-agent-hook")
    #expect(HookInstaller.topLevelNotifyLine(in: added) == 0)
    #expect(HookInstaller.removingCodexNotify(from: added) == config)
    #expect(HookInstaller.topLevelNotifyLine(in: "notify = [\"terminal-notifier\"]\n") == 0)
}

@Test func hookScriptWritesEventFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notch-hook-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let events = root.appendingPathComponent("Events dir")
    let installer = HookInstaller(home: root, eventsDirectory: events)
    try installer.installScript()

    func run(_ args: [String], stdin: String) throws -> String {
        let process = Process()
        process.executableURL = installer.scriptURL
        process.arguments = args
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    #expect(try run(["claude", "Stop"], stdin: #"{"session_id":"s","cwd":"/tmp/p"}"#) == "")
    #expect(try run(["cursor", "beforeSubmitPrompt"], stdin: "{}") == #"{"continue":true}"#)
    _ = try run(["codex", "agent-turn-complete", #"{"type":"agent-turn-complete","thread-id":"t"}"#], stdin: "")

    let files = try FileManager.default.contentsOfDirectory(at: events, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }
    #expect(files.count == 3)
    // Finished files must be visible (not dotfiles) so nothing filters them out.
    #expect(files.allSatisfy { !$0.lastPathComponent.hasPrefix(".") })
    let parsed = try files.map { try #require(AgentEvent.parse(Data(contentsOf: $0), fallbackDate: Date())) }
    #expect(Set(parsed.map(\.sessionID)) == ["s", "t", "cursor"])
}
