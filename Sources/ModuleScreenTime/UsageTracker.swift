import Foundation

/// Decides when to nudge: after `threshold` of continuous distracting use,
/// then every `repeatInterval`, escalating up to level 3. Short trips to
/// other apps don't break the streak; `resetGap` of focused (or away) time does.
struct UsageTracker: Equatable, Sendable {
    struct Config: Equatable, Sendable {
        var threshold: TimeInterval = 30 * 60
        var repeatInterval: TimeInterval = 10 * 60
        var resetGap: TimeInterval = 2 * 60
        var snooze: TimeInterval = 5 * 60
        var breakLength: TimeInterval = 15 * 60
    }

    enum Nudge: Equatable, Sendable {
        /// `level` 1…3, `streak` seconds of the current distracting run.
        case distracted(level: Int, streak: TimeInterval, key: String)
        case breakOver
    }

    static let maxLevel = 3

    var config = Config()
    private(set) var streakStart: Date?
    private(set) var lastDistracted: Date?
    /// Set after the first nudge (repeats, snooze). Before that, the first
    /// nudge is due `threshold` after the streak started, so changing the
    /// setting mid-streak takes effect right away.
    private(set) var nextNudgeAt: Date?
    private(set) var level = 0
    private(set) var breakUntil: Date?

    var isOnBreak: Bool { breakUntil != nil }

    func streak(at now: Date) -> TimeInterval {
        streakStart.map { max(now.timeIntervalSince($0), 0) } ?? 0
    }

    /// Call on every sample. `key` is nil while the user is away or the screen is locked.
    /// `suppressed` holds back nudges (e.g. during a call) without losing them.
    mutating func update(key: String?, isDistracting: Bool, suppressed: Bool, now: Date) -> Nudge? {
        if let end = breakUntil {
            guard now >= end else { return nil }
            breakUntil = nil
            reset()
            return suppressed ? nil : .breakOver
        }

        guard let key, isDistracting else {
            if let last = lastDistracted, now.timeIntervalSince(last) >= config.resetGap { reset() }
            return nil
        }

        if streakStart == nil {
            streakStart = now
            nextNudgeAt = nil
            level = 0
        }
        lastDistracted = now

        guard !suppressed, let due = nextNudgeDue, now >= due else { return nil }
        level = min(level + 1, Self.maxLevel)
        nextNudgeAt = now.addingTimeInterval(config.repeatInterval)
        return .distracted(level: level, streak: streak(at: now), key: key)
    }

    /// When the next nudge is due, if a streak is running.
    var nextNudgeDue: Date? {
        nextNudgeAt ?? streakStart?.addingTimeInterval(config.threshold)
    }

    /// "5 more minutes": nudge again soon, a level firmer.
    mutating func snooze(now: Date) {
        guard streakStart != nil else { return }
        nextNudgeAt = now.addingTimeInterval(config.snooze)
    }

    /// Quiet for the break, then one "break's over" nudge.
    mutating func takeBreak(now: Date) {
        reset()
        breakUntil = now.addingTimeInterval(config.breakLength)
    }

    mutating func endBreak() {
        breakUntil = nil
    }

    mutating func backToWork() {
        reset()
    }

    private mutating func reset() {
        streakStart = nil
        lastDistracted = nil
        nextNudgeAt = nil
        level = 0
    }
}
