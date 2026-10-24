import AppKit
import NotchShell
import SwiftUI

/// Coding-agent control center: live Claude Code / Codex / Cursor sessions
/// (via hooks) plus usage, cost and limit windows read from local logs.
@MainActor
@Observable
public final class AIModule: NotchModule {
    public let id = "ai"
    public let title = "AI"
    public let systemImage = "sparkles"

    private(set) var snapshot = UsageSnapshot()
    private(set) var board = SessionBoard()
    private(set) var hookStatus: [AgentKind: HookInstaller.Status] = [:]
    private(set) var hookError: String?
    private(set) var isScanning = false

    var alertOnFinish: Bool { didSet { save(alertOnFinish, "ai.alertFinish") } }
    var alertOnNeedsInput: Bool { didSet { save(alertOnNeedsInput, "ai.alertInput") } }
    var playSounds: Bool { didSet { save(playSounds, "ai.sounds") } }
    var quietWhenFrontmost: Bool { didSet { save(quietWhenFrontmost, "ai.quietFrontmost") } }
    var alertOnWindowReset: Bool {
        didSet {
            save(alertOnWindowReset, "ai.alertReset")
            scheduleWindowReset()
        }
    }
    var keepAwakeWhileWorking: Bool {
        didSet {
            save(keepAwakeWhileWorking, "ai.keepAwake")
            updateKeepAwake()
        }
    }
    var keepAwakeMaxHours: Int {
        didSet { UserDefaults.standard.set(keepAwakeMaxHours, forKey: "ai.keepAwakeHours") }
    }

    @ObservationIgnored let installer: HookInstaller
    @ObservationIgnored private let scanner = UsageScanner()
    @ObservationIgnored private let watcher: AgentEventWatcher
    @ObservationIgnored private weak var context: NotchContext?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var resetTask: Task<Void, Never>?
    @ObservationIgnored private var pruneTimer: Timer?
    @ObservationIgnored private var visibleViews = 0
    /// When the current keep-awake stretch began; stays set after the cap
    /// expires so we don't re-hold until every agent has stopped working.
    @ObservationIgnored private var awakeSince: Date?

    public init() {
        let events = AppPaths.directory("AgentEvents")
        installer = HookInstaller(eventsDirectory: events)
        watcher = AgentEventWatcher(directory: events)
        let d = UserDefaults.standard
        d.register(defaults: ["ai.alertFinish": true, "ai.alertInput": true, "ai.sounds": true,
                              "ai.quietFrontmost": true, "ai.alertReset": false,
                              "ai.keepAwake": true, "ai.keepAwakeHours": 3])
        alertOnFinish = d.bool(forKey: "ai.alertFinish")
        alertOnNeedsInput = d.bool(forKey: "ai.alertInput")
        playSounds = d.bool(forKey: "ai.sounds")
        quietWhenFrontmost = d.bool(forKey: "ai.quietFrontmost")
        alertOnWindowReset = d.bool(forKey: "ai.alertReset")
        keepAwakeWhileWorking = d.bool(forKey: "ai.keepAwake")
        keepAwakeMaxHours = d.integer(forKey: "ai.keepAwakeHours")
    }

    private func save(_ value: Bool, _ key: String) { UserDefaults.standard.set(value, forKey: key) }

    public func start(context: NotchContext) {
        self.context = context
        installer.refreshScriptIfConnected()
        refreshHookStatus()
        watcher.onEvents = { [weak self] events in self?.handle(events) }
        watcher.start()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.board.prune(now: Date())
                self?.updateKeepAwake()
            }
        }
        startScanning()
    }

    public func stop() {
        watcher.stop()
        scanTask?.cancel()
        resetTask?.cancel()
        pruneTimer?.invalidate()
        KeepAwake.shared.release(Self.awakeID)
        awakeSince = nil
        context = nil
    }

    // MARK: - Usage

    /// Rescans often while the tab is open, rarely otherwise (only the
    /// window-reset alert needs fresh data in the background).
    private func startScanning() {
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scanNow()
                let interval: Double = (self?.visibleViews ?? 0) > 0 ? 10 : 300
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func scanNow() async {
        isScanning = true
        let result = await scanner.scan()
        isScanning = false
        let blockChanged = result.currentBlock?.start != snapshot.currentBlock?.start
        if result != snapshot { snapshot = result }
        if blockChanged { scheduleWindowReset() }
    }

    func viewAppeared() {
        visibleViews += 1
        refreshHookStatus()
        if visibleViews == 1 { startScanning() }
    }

    func viewDisappeared() {
        visibleViews = max(visibleViews - 1, 0)
    }

    private func scheduleWindowReset() {
        resetTask?.cancel()
        guard alertOnWindowReset, let block = snapshot.currentBlock, block.end > Date() else { return }
        let end = block.end
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(end.timeIntervalSinceNow))
            guard !Task.isCancelled, let self else { return }
            self.announce(symbol: "arrow.clockwise.circle.fill", color: .green, title: "Claude", detail: "Limit window reset")
            if self.playSounds && !CallStatus.shared.shouldSilenceSounds { NSSound(named: "Hero")?.play() }
        }
    }

    // MARK: - Hooks

    func refreshHookStatus() {
        for agent in AgentKind.allCases { hookStatus[agent] = installer.status(agent) }
    }

    func setConnected(_ agent: AgentKind, _ connect: Bool) {
        hookError = nil
        do {
            if connect { try installer.connect(agent) } else { try installer.disconnect(agent) }
        } catch let error as HookInstaller.InstallError {
            switch error {
            case .unreadableConfig(let message), .conflict(let message): hookError = message
            }
        } catch {
            hookError = error.localizedDescription
        }
        refreshHookStatus()
    }

    var anyConnected: Bool { hookStatus.values.contains(.connected) }

    // MARK: - Sessions

    private func handle(_ events: [AgentEvent]) {
        for event in events {
            guard let alert = board.apply(event) else { continue }
            // Only alert for events that just happened.
            guard Date().timeIntervalSince(event.date) < 60 else { continue }
            present(alert)
        }
        updateKeepAwake()
    }

    // MARK: - Keep awake

    private static let awakeID = "ai-agents"

    /// Holds the Mac awake while any agent is working, up to the time cap.
    /// Waiting-for-approval doesn't count: if you're away, let the Mac sleep.
    private func updateKeepAwake() {
        let working = board.sorted.filter { $0.status == .working }
        guard keepAwakeWhileWorking, !working.isEmpty else {
            KeepAwake.shared.release(Self.awakeID)
            awakeSince = nil
            return
        }
        let label = working.count == 1 ? "\(working[0].agent.shortName) is working" : "\(working.count) agents working"
        if let since = awakeSince {
            // Refresh the label, but never revive a hold that expired or hit the battery floor.
            guard KeepAwake.shared.hold(for: Self.awakeID) != nil else { return }
            KeepAwake.shared.hold(Self.awakeID, label: label,
                                  until: since.addingTimeInterval(Double(keepAwakeMaxHours) * 3600))
        } else {
            let now = Date()
            awakeSince = now
            KeepAwake.shared.hold(Self.awakeID, label: label, until: now.addingTimeInterval(Double(keepAwakeMaxHours) * 3600))
        }
    }

    var isKeepingAwake: Bool { KeepAwake.shared.hold(for: Self.awakeID) != nil }

    func dismiss(_ session: AgentSession) {
        board.dismiss(session.id)
        updateKeepAwake()
    }

    func focus(_ session: AgentSession) {
        guard let bundleID = session.appBundleID,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return }
        app.activate()
    }

    private func present(_ alert: SessionBoard.Alert) {
        let session: AgentSession
        switch alert {
        case .needsInput(let s), .failed(let s): session = s
        case .finished(let s, _): session = s
        }
        if quietWhenFrontmost, let app = session.appBundleID,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier == app { return }

        switch alert {
        case .needsInput(let s):
            guard alertOnNeedsInput else { return }
            announce(symbol: "hand.raised.fill", color: .orange, title: s.agent.shortName, detail: "Needs you · \(s.project)")
            if playSounds && !CallStatus.shared.shouldSilenceSounds { NSSound(named: "Funk")?.play() }
        case .finished(let s, _):
            guard alertOnFinish else { return }
            announce(symbol: "checkmark.circle.fill", color: .green, title: s.agent.shortName, detail: "Done · \(s.project)")
            if playSounds && !CallStatus.shared.shouldSilenceSounds { NSSound(named: "Glass")?.play() }
        case .failed(let s):
            guard alertOnFinish else { return }
            announce(symbol: "exclamationmark.triangle.fill", color: .red, title: s.agent.shortName, detail: "Failed · \(s.project)")
            if playSounds && !CallStatus.shared.shouldSilenceSounds { NSSound(named: "Basso")?.play() }
        }
    }

    private func announce(symbol: String, color: Color, title: String, detail: String) {
        context?.showTransient(CompactActivity(id: "ai-\(UUID().uuidString)", priority: 96, sideWidth: 130) {
            HStack(spacing: 5) {
                Image(systemName: symbol).foregroundStyle(color)
                Text(title).lineLimit(1)
            }
            .font(.system(size: 11, weight: .semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 6)
        } trailing: {
            Text(detail)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 6)
        }, for: .seconds(5))
    }

    // MARK: - NotchModule

    public var compactActivity: CompactActivity? {
        let sessions = board.sorted
        if let waiting = sessions.first(where: { $0.status == .needsInput }) {
            return CompactActivity(id: "ai-input-\(waiting.id)", priority: 70, sideWidth: 84) {
                HStack(spacing: 4) {
                    Image(systemName: "hand.raised.fill")
                    Text(waiting.agent.shortName).lineLimit(1)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 6)
            } trailing: {
                Text(waiting.project)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 6)
            }
        }
        let working = sessions.filter { $0.status == .working }
        if let first = working.min(by: { $0.since < $1.since }) {
            return CompactActivity(id: "ai-working", priority: 25, sideWidth: 50) {
                WorkingIndicator(symbol: first.agent.symbol)
            } trailing: {
                if working.count > 1 {
                    Text("\(working.count) agents")
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(ElapsedFormat.clock(context.date.timeIntervalSince(first.since)))
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    }
                }
            }
        }
        return nil
    }

    public func makeExpandedView() -> AnyView {
        AnyView(AIView(module: self))
    }

    public func makeSettingsView() -> AnyView? {
        AnyView(AISettingsView(module: self))
    }
}

enum ElapsedFormat {
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(Int(seconds), 0)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        return UsageFormat.duration(seconds) + " ago"
    }
}

private struct WorkingIndicator: View {
    let symbol: String
    @Environment(\.notchAccent) private var accent

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(accent)
            .symbolEffect(.pulse, options: .repeating)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 6)
    }
}
