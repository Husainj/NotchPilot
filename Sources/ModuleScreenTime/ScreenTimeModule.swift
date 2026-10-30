import AppKit
import NotchShell
import SwiftUI

/// Screen Time: tracks time per app and site, and after a long run on a
/// distracting one the mascot drops down from the notch with your tasks.
@MainActor
@Observable
public final class ScreenTimeModule: NotchModule {
    public let id = "screentime"
    public let title = "Screen Time"
    public let systemImage = "hourglass"

    struct ActiveNudge: Equatable {
        /// 1…3, or 0 for "break's over".
        let level: Int
        let appName: String
        let minutes: Int
        let message: String
        var mood: Mood { level == 0 ? .happy : Mood.forLevel(level) }
    }

    struct DaySplit: Identifiable {
        let date: Date
        let focused: TimeInterval
        let distracting: TimeInterval
        var id: Date { date }
    }

    // MARK: Settings

    var nudgesEnabled: Bool { didSet { save(nudgesEnabled, "screentime.nudges") } }
    var thresholdMinutes: Int { didSet { save(thresholdMinutes, "screentime.threshold"); applyConfig() } }
    var repeatMinutes: Int { didSet { save(repeatMinutes, "screentime.repeat"); applyConfig() } }
    var dailyLimitMinutes: Int { didSet { save(dailyLimitMinutes, "screentime.dailyLimit") } }
    var trackSites: Bool {
        didSet {
            save(trackSites, "screentime.trackSites")
            monitor.trackSites = trackSites
        }
    }
    var showLiveActivity: Bool { didSet { save(showLiveActivity, "screentime.live") } }
    var quietDuringCalls: Bool { didSet { save(quietDuringCalls, "screentime.quietCalls") } }
    var categories: Categories {
        didSet {
            UserDefaults.standard.set(categories.sites, forKey: "screentime.sites")
            UserDefaults.standard.set(categories.apps, forKey: "screentime.apps")
        }
    }

    // MARK: State

    private(set) var tracker = UsageTracker()
    private(set) var currentKey: String?
    private(set) var nudge: ActiveNudge?
    private(set) var cheer: String?
    /// Bumped on every sample so views showing totals refresh.
    private(set) var tick = 0

    @ObservationIgnored private let tasksProvider: @MainActor () -> [FocusTask]
    @ObservationIgnored private let completeTaskAction: @MainActor (String) -> Void
    @ObservationIgnored private let nextMeetingProvider: @MainActor () -> JoinableMeeting?
    @ObservationIgnored private let reminderAccess: @MainActor () -> Bool
    @ObservationIgnored private let monitor = ActivityMonitor()
    @ObservationIgnored private var store: UsageStore?
    @ObservationIgnored private weak var context: NotchContext?
    @ObservationIgnored private var lastSampleKey: String?
    @ObservationIgnored private var lastWorkApp: NSRunningApplication?
    @ObservationIgnored private var pendingOpen = false
    @ObservationIgnored private var messages = Messages()
    @ObservationIgnored private var namesCache: [String: String] = [:]
    @ObservationIgnored private var cheerTask: Task<Void, Never>?
    @ObservationIgnored private var terminateObserver: NSObjectProtocol?

    /// - Parameters:
    ///   - tasks: open reminders to show in the nudge (from the Calendar module).
    ///   - completeTask: marks a reminder done.
    ///   - nextMeeting: the next calendar event, if any.
    ///   - hasReminderAccess: whether Reminders access was granted.
    public init(tasks: @escaping @MainActor () -> [FocusTask] = { [] },
                completeTask: @escaping @MainActor (String) -> Void = { _ in },
                nextMeeting: @escaping @MainActor () -> JoinableMeeting? = { nil },
                hasReminderAccess: @escaping @MainActor () -> Bool = { false }) {
        tasksProvider = tasks
        completeTaskAction = completeTask
        nextMeetingProvider = nextMeeting
        reminderAccess = hasReminderAccess
        let d = UserDefaults.standard
        d.register(defaults: [
            "screentime.nudges": true, "screentime.threshold": 30, "screentime.repeat": 10,
            "screentime.dailyLimit": 60, "screentime.trackSites": true, "screentime.live": true,
            "screentime.quietCalls": true,
        ])
        nudgesEnabled = d.bool(forKey: "screentime.nudges")
        thresholdMinutes = d.integer(forKey: "screentime.threshold")
        repeatMinutes = d.integer(forKey: "screentime.repeat")
        dailyLimitMinutes = d.integer(forKey: "screentime.dailyLimit")
        trackSites = d.bool(forKey: "screentime.trackSites")
        showLiveActivity = d.bool(forKey: "screentime.live")
        quietDuringCalls = d.bool(forKey: "screentime.quietCalls")
        categories = Categories(sites: d.stringArray(forKey: "screentime.sites") ?? Categories.defaultSites,
                                apps: d.stringArray(forKey: "screentime.apps") ?? Categories.defaultApps)
        applyConfig()
    }

    private func save(_ value: Any, _ key: String) { UserDefaults.standard.set(value, forKey: key) }

    private func applyConfig() {
        tracker.config.threshold = TimeInterval(max(thresholdMinutes, 1) * 60)
        tracker.config.repeatInterval = TimeInterval(max(repeatMinutes, 1) * 60)
    }

    // MARK: Lifecycle

    public func start(context: NotchContext) {
        self.context = context
        if store == nil { store = UsageStore() }
        store?.prune(now: Date())
        monitor.trackSites = trackSites
        monitor.onSample = { [weak self] in self?.handle($0) }
        monitor.start()
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.store?.save() }
        }
    }

    public func stop() {
        monitor.stop()
        store?.save()
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
        terminateObserver = nil
        context = nil
    }

    // MARK: Sampling

    private func handle(_ sample: ActivityMonitor.Sample) {
        let now = Date()
        // Time since the last sample belongs to what was showing then.
        if let previous = lastSampleKey {
            store?.add(sample.elapsed, to: previous, now: now)
        } else {
            store?.rollOver(now: now)
        }
        lastSampleKey = sample.key
        currentKey = sample.key

        let distracting = sample.key.map(categories.isDistracting) ?? false
        if let app = sample.app, !distracting,
           let bundleID = app.bundleIdentifier, !BrowserURLReader.isBrowser(bundleID) {
            lastWorkApp = app
        }

        let suppressed = !nudgesEnabled || (quietDuringCalls && CallStatus.shared.isInCall)
            || CaptureStatus.shared.isRecording
        let wasStreaking = tracker.streakStart != nil
        if let result = tracker.update(key: sample.key, isDistracting: distracting, suppressed: suppressed, now: now) {
            present(result)
        } else if wasStreaking, tracker.streakStart == nil, let n = nudge, n.level > 0 {
            // They moved on by themselves.
            nudge = nil
        }

        // Retry an open that failed (e.g. a full-screen video hid the island).
        if pendingOpen, nudge != nil {
            pendingOpen = context?.open(moduleID: id, takeFocus: false) != true
        }

        tick &+= 1
        if tick % 12 == 0 { store?.save() } // about once a minute
    }

    private func present(_ result: UsageTracker.Nudge) {
        switch result {
        case let .distracted(level, streak, key):
            let name = displayName(for: key)
            let minutes = Int(streak / 60)
            nudge = ActiveNudge(level: level, appName: name, minutes: minutes,
                                message: messages.line(level: level, app: name, minutes: minutes))
        case .breakOver:
            nudge = ActiveNudge(level: 0, appName: "", minutes: 0, message: messages.line(level: 0, app: "", minutes: 0))
        }
        cheer = nil
        pendingOpen = context?.open(moduleID: id, takeFocus: false) != true
    }

    // MARK: Actions

    func backToWork() {
        tracker.backToWork()
        nudge = nil
        pendingOpen = false
        cheer = Messages.cheers.randomElement()
        if let app = lastWorkApp, !app.isTerminated { app.activate() }
        cheerTask?.cancel()
        cheerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            self?.cheer = nil
            self?.context?.close()
        }
    }

    func snooze() {
        tracker.snooze(now: Date())
        dismiss()
    }

    func takeBreak() {
        tracker.takeBreak(now: Date())
        dismiss()
    }

    func endBreak() {
        tracker.endBreak()
    }

    func dismiss() {
        nudge = nil
        pendingOpen = false
        context?.close()
    }

    func completeTask(_ id: String) { completeTaskAction(id) }

    var tasks: [FocusTask] { tasksProvider() }
    var nextMeeting: JoinableMeeting? { nextMeetingProvider() }
    var hasReminderAccess: Bool { reminderAccess() }

    func openCalendar() { context?.open(moduleID: "calendar") }
    func openTimers() { context?.open(moduleID: "timers") }

    func setDistracting(_ key: String, _ distracting: Bool) {
        var c = categories
        if distracting {
            if let domain = UsageKey.domain(key) { c.sites.append(domain) }
            if let bundleID = UsageKey.bundleID(key) { c.apps.append(bundleID) }
        } else {
            while let entry = c.matchingEntry(for: key) {
                c.sites.removeAll { $0 == entry }
                c.apps.removeAll { $0 == entry }
            }
        }
        categories = c
    }

    func isDistracting(_ key: String) -> Bool { categories.isDistracting(key) }

    // MARK: Stats

    private var now: Date { _ = tick; return Date() }

    var todayTotals: UsageStore.Totals { _ = tick; return store?.today ?? [:] }

    func split(_ totals: UsageStore.Totals) -> (focused: TimeInterval, distracting: TimeInterval) {
        var focused: TimeInterval = 0, distracting: TimeInterval = 0
        for (key, seconds) in totals {
            if categories.isDistracting(key) { distracting += seconds } else { focused += seconds }
        }
        return (focused, distracting)
    }

    var week: [DaySplit] {
        let now = self.now
        return (0..<7).reversed().map { daysAgo in
            let totals = store?.totals(daysAgo: daysAgo, now: now) ?? [:]
            let s = split(totals)
            let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Calendar.current.startOfDay(for: now)) ?? now
            return DaySplit(date: date, focused: s.focused, distracting: s.distracting)
        }
    }

    /// Days in a row (including today, if it's still under) within the daily distraction limit.
    var streakDays: Int {
        guard let store else { return 0 }
        let now = self.now
        let limit = TimeInterval(dailyLimitMinutes * 60)
        var days = 0
        for daysAgo in 0..<UsageStore.keepDays {
            let totals = store.totals(daysAgo: daysAgo, now: now)
            if daysAgo > 0, totals.isEmpty { break }
            if split(totals).distracting > limit {
                if daysAgo == 0 { continue }
                break
            }
            days += 1
        }
        return days
    }

    func displayName(for key: String) -> String {
        if let cached = namesCache[key] { return cached }
        var name = key
        if let domain = UsageKey.domain(key) {
            name = Self.siteNames[domain] ?? domain
        } else if let bundleID = UsageKey.bundleID(key) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            } else {
                name = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
            }
        }
        namesCache[key] = name
        return name
    }

    static let siteNames = [
        "instagram.com": "Instagram", "youtube.com": "YouTube", "x.com": "X", "twitter.com": "Twitter",
        "reddit.com": "Reddit", "facebook.com": "Facebook", "tiktok.com": "TikTok", "netflix.com": "Netflix",
        "twitch.tv": "Twitch", "snapchat.com": "Snapchat", "pinterest.com": "Pinterest",
        "primevideo.com": "Prime Video", "hotstar.com": "Hotstar", "linkedin.com": "LinkedIn",
    ]

    func icon(for key: String) -> NSImage? {
        guard let bundleID = UsageKey.bundleID(key),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    // MARK: NotchModule

    public var compactActivity: CompactActivity? {
        _ = tick
        guard showLiveActivity, let key = currentKey, categories.isDistracting(key) else { return nil }
        let streak = tracker.streak(at: Date())
        guard streak >= tracker.config.threshold / 2 else { return nil }
        let over = streak >= tracker.config.threshold
        let name = displayName(for: key)
        return CompactActivity(id: "screentime", priority: 12, sideWidth: 92) {
            Mascot(mood: over ? Mood.forLevel(max(tracker.level, 1)) : .concerned, size: 24, animated: false)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 6)
        } trailing: {
            Text("\(name) \(Int(streak / 60))m")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(over ? .red : .orange)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 6)
        }
    }

    public func makeExpandedView() -> AnyView {
        AnyView(ScreenTimeView(module: self))
    }

    public func makeSettingsView() -> AnyView? {
        AnyView(ScreenTimeSettingsView(module: self))
    }
}
