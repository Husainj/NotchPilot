import Foundation
@testable import ModuleScreenTime
import Testing

private let t0 = Date(timeIntervalSince1970: 1_000_000)
private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
private let insta = "web:instagram.com"
private let xcode = "app:com.apple.dt.Xcode"

/// Feeds samples every 30 s from `from` to `to` (minutes) and collects nudges.
private func run(_ tracker: inout UsageTracker, key: String?, distracting: Bool,
                 from: Double, to: Double, suppressed: Bool = false) -> [UsageTracker.Nudge] {
    var nudges: [UsageTracker.Nudge] = []
    var m = from
    while m <= to {
        if let n = tracker.update(key: key, isDistracting: distracting, suppressed: suppressed, now: at(m)) {
            nudges.append(n)
        }
        m += 0.5
    }
    return nudges
}

private func levels(_ nudges: [UsageTracker.Nudge]) -> [Int] {
    nudges.compactMap { if case let .distracted(level, _, _) = $0 { level } else { nil } }
}

@Test func firstNudgeAtThresholdThenEscalatesAndCaps() {
    var tracker = UsageTracker()
    #expect(run(&tracker, key: insta, distracting: true, from: 0, to: 29.5).isEmpty)
    let first = run(&tracker, key: insta, distracting: true, from: 30, to: 30)
    #expect(first == [.distracted(level: 1, streak: 30 * 60, key: insta)])
    // Every 10 minutes after, up to level 3, then it stays at 3.
    let later = run(&tracker, key: insta, distracting: true, from: 30.5, to: 70)
    #expect(levels(later) == [2, 3, 3, 3])
}

@Test func shortTripsKeepTheStreakLongGapsReset() {
    var tracker = UsageTracker()
    _ = run(&tracker, key: insta, distracting: true, from: 0, to: 20)
    // 1.5 minutes in Xcode: under the 2-minute reset gap.
    _ = run(&tracker, key: xcode, distracting: false, from: 20.5, to: 21.5)
    #expect(tracker.streakStart == at(0))
    let nudges = run(&tracker, key: "web:youtube.com", distracting: true, from: 22, to: 30)
    #expect(levels(nudges) == [1]) // Instagram → YouTube continues the same streak.

    // 3 minutes focused resets it.
    _ = run(&tracker, key: xcode, distracting: false, from: 30.5, to: 33.5)
    #expect(tracker.streakStart == nil)
    #expect(run(&tracker, key: insta, distracting: true, from: 34, to: 60).isEmpty)
}

@Test func beingAwayResetsLikeFocusedTime() {
    var tracker = UsageTracker()
    _ = run(&tracker, key: insta, distracting: true, from: 0, to: 10)
    _ = run(&tracker, key: nil, distracting: false, from: 10.5, to: 13)
    #expect(tracker.streakStart == nil)
}

@Test func snoozeNudgesAgainSoonAndFirmer() {
    var tracker = UsageTracker()
    _ = run(&tracker, key: insta, distracting: true, from: 0, to: 30)
    tracker.snooze(now: at(30))
    #expect(run(&tracker, key: insta, distracting: true, from: 30.5, to: 34.5).isEmpty)
    #expect(levels(run(&tracker, key: insta, distracting: true, from: 35, to: 35)) == [2])
}

@Test func breakIsQuietThenSaysBreakOver() {
    var tracker = UsageTracker()
    _ = run(&tracker, key: insta, distracting: true, from: 0, to: 30)
    tracker.takeBreak(now: at(30))
    #expect(tracker.isOnBreak)
    #expect(run(&tracker, key: insta, distracting: true, from: 30.5, to: 44.5).isEmpty)
    #expect(run(&tracker, key: insta, distracting: true, from: 45, to: 45) == [.breakOver])
    #expect(!tracker.isOnBreak)
    // A fresh streak starts after the break.
    #expect(run(&tracker, key: insta, distracting: true, from: 45.5, to: 74.5).isEmpty)
}

@Test func loweringTheLimitMidStreakAppliesRightAway() {
    var tracker = UsageTracker()
    _ = run(&tracker, key: insta, distracting: true, from: 0, to: 12)
    // The user changes 30 → 10 minutes while already 12 minutes in.
    tracker.config.threshold = 10 * 60
    #expect(levels(run(&tracker, key: insta, distracting: true, from: 12.5, to: 12.5)) == [1])
}

@Test func backToWorkResets() {
    var tracker = UsageTracker()
    _ = run(&tracker, key: insta, distracting: true, from: 0, to: 30)
    tracker.backToWork()
    #expect(tracker.streakStart == nil && tracker.level == 0)
}

@Test func suppressedNudgesWaitUntilAllowed() {
    var tracker = UsageTracker()
    // On a call at the 30-minute mark: no nudge.
    #expect(run(&tracker, key: insta, distracting: true, from: 0, to: 40, suppressed: true).isEmpty)
    // As soon as the call ends, the overdue nudge fires.
    #expect(levels(run(&tracker, key: insta, distracting: true, from: 40.5, to: 40.5)) == [1])
}

@Test func normalizesDomains() {
    #expect(UsageKey.normalizedDomain(fromURL: "https://www.instagram.com/reels/abc") == "instagram.com")
    #expect(UsageKey.normalizedDomain(fromURL: "https://m.youtube.com/watch?v=1") == "youtube.com")
    #expect(UsageKey.normalizedDomain(fromURL: "https://mobile.twitter.com/home") == "twitter.com")
    #expect(UsageKey.normalizedDomain(fromURL: "https://old.reddit.com/r/swift") == "old.reddit.com")
    #expect(UsageKey.normalizedDomain(fromURL: "http://localhost:3000/") == nil)
    #expect(UsageKey.normalizedDomain(fromURL: "http://192.168.1.10/admin") == nil)
    #expect(UsageKey.normalizedDomain(fromURL: "file:///Users/me/index.html") == nil)
    #expect(UsageKey.normalizedDomain(fromURL: "about:blank") == nil)
}

@Test func matchesSubdomainsAndApps() {
    let c = Categories.standard
    #expect(c.isDistracting("web:old.reddit.com"))
    #expect(c.isDistracting("web:instagram.com"))
    #expect(!c.isDistracting("web:github.com"))
    #expect(!c.isDistracting("web:notinstagram.com"))
    #expect(c.isDistracting("app:com.hnc.Discord"))
    #expect(!c.isDistracting("app:com.apple.dt.Xcode"))
    #expect(c.matchingEntry(for: "web:old.reddit.com") == "reddit.com")
    #expect(Categories.isVideo("web:youtube.com") && !Categories.isVideo("web:instagram.com"))
}

@MainActor @Test func storeRollsOverDaysAndPrunesOldFiles() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("screentime-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let day1 = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00 UTC
    let old = calendar.date(byAdding: .day, value: -40, to: day1)!
    try Data("{}".utf8).write(to: dir.appendingPathComponent(UsageStore.dayKey(old, calendar: calendar) + ".json"))

    let store = UsageStore(directory: dir, calendar: calendar, now: day1)
    store.add(120, to: insta, now: day1)
    store.add(30, to: insta, now: day1.addingTimeInterval(60))
    store.add(600, to: xcode, now: day1.addingTimeInterval(120))
    #expect(store.today == [insta: 150, xcode: 600])

    let day2 = day1.addingTimeInterval(24 * 3600)
    store.add(60, to: xcode, now: day2)
    #expect(store.today == [xcode: 60])
    #expect(store.totals(daysAgo: 1, now: day2) == [insta: 150, xcode: 600])
    store.save()

    // Reopening reads the saved day back; the 40-day-old file was pruned on rollover.
    let reopened = UsageStore(directory: dir, calendar: calendar, now: day2)
    #expect(reopened.today == [xcode: 60])
    let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    #expect(files == ["2027-01-15.json", "2027-01-16.json"])
}
