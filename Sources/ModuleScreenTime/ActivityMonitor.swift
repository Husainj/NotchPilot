import AppKit
import CoreGraphics

/// Samples what the user is doing every few seconds: the frontmost app,
/// or the site in a browser's active tab. Reports nil while away, asleep or locked.
@MainActor
final class ActivityMonitor {
    struct Sample {
        /// `app:<bundle id>` or `web:<domain>`; nil when the user is away.
        let key: String?
        /// Seconds since the previous sample.
        let elapsed: TimeInterval
        /// The frontmost app, for "Back to work".
        let app: NSRunningApplication?
    }

    static let interval: TimeInterval = 5
    /// No input for this long means the user stepped away…
    static let idleLimit: TimeInterval = 3 * 60
    /// …except on video sites, where watching needs no input.
    static let videoIdleLimit: TimeInterval = 30 * 60

    var trackSites = true
    var onSample: ((Sample) -> Void)?

    private let reader = BrowserURLReader()
    private var timer: Timer?
    private var lastTick = Date()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var isAsleep = false
    private var isLocked = false
    /// The last key seen, so a sample taken while the island is focused isn't
    /// attributed to NotchPilot itself.
    private var lastKey: String?
    private var sampling = false

    func start() {
        guard timer == nil else { return }
        lastTick = Date()
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification]) { $0.isAsleep = true }
        observe(workspace, [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification]) { $0.isAsleep = false }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, [Notification.Name("com.apple.screenIsLocked")]) { $0.isLocked = true }
        observe(distributed, [Notification.Name("com.apple.screenIsUnlocked")]) { $0.isLocked = false }
        // Sample right away on app switches so short visits are attributed correctly.
        observe(workspace, [NSWorkspace.didActivateApplicationNotification]) { $0.tick() }

        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    private func observe(_ center: NotificationCenter, _ names: [Notification.Name],
                         _ action: @escaping @MainActor (ActivityMonitor) -> Void) {
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { action(self) } }
            }
            observers.append((center, token))
        }
    }

    private static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private func tick() {
        guard !sampling else { return }
        let now = Date()
        // Cap the gap so time asleep (timer paused) isn't counted.
        let elapsed = min(now.timeIntervalSince(lastTick), Self.interval * 2)
        lastTick = now

        guard !isAsleep, !isLocked, let app = NSWorkspace.shared.frontmostApplication else {
            emit(key: nil, elapsed: elapsed, app: nil)
            return
        }
        let bundleID = app.bundleIdentifier ?? ""
        // Our own island and background agents (permission prompts, etc.)
        // aren't something the user chose to spend time in.
        if bundleID == Bundle.main.bundleIdentifier || app.activationPolicy != .regular {
            emit(key: lastKey, elapsed: elapsed, app: nil)
            return
        }
        guard trackSites, BrowserURLReader.isBrowser(bundleID) else {
            emit(key: UsageKey.app(bundleID), elapsed: elapsed, app: app)
            return
        }
        sampling = true
        Task {
            let url = await reader.activeURL(bundleID: bundleID)
            sampling = false
            let key = url.flatMap(UsageKey.normalizedDomain(fromURL:)).map(UsageKey.web) ?? UsageKey.app(bundleID)
            emit(key: key, elapsed: elapsed, app: app)
        }
    }

    private func emit(key: String?, elapsed: TimeInterval, app: NSRunningApplication?) {
        var key = key
        if let k = key {
            let limit = Categories.isVideo(k) ? Self.videoIdleLimit : Self.idleLimit
            if Self.idleSeconds > limit { key = nil }
        }
        lastKey = key
        onSample?(Sample(key: key, elapsed: elapsed, app: app))
    }
}
