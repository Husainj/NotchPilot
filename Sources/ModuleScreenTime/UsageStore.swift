import Foundation
import NotchShell

/// Seconds of use per app/site, one JSON file per local day
/// (`ScreenTime/2026-10-24.json`). Only keys and totals are stored.
@MainActor
final class UsageStore {
    typealias Totals = [String: TimeInterval]

    static let keepDays = 35

    private let directory: URL
    private let calendar: Calendar
    private(set) var todayKey: String
    private(set) var today: Totals
    private var pastCache: [String: Totals] = [:]
    private var dirty = false

    init(directory: URL = AppPaths.directory("ScreenTime"), calendar: Calendar = .current, now: Date = Date()) {
        self.directory = directory
        self.calendar = calendar
        todayKey = Self.dayKey(now, calendar: calendar)
        today = JSONFile<Totals>(url: directory.appendingPathComponent(todayKey + ".json")).load() ?? [:]
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func file(_ day: String) -> JSONFile<Totals> {
        JSONFile(url: directory.appendingPathComponent(day + ".json"))
    }

    func add(_ seconds: TimeInterval, to key: String, now: Date) {
        guard seconds > 0 else { return }
        rollOver(now: now)
        today[key, default: 0] += seconds
        dirty = true
    }

    /// Starts a new day file at local midnight.
    func rollOver(now: Date) {
        let key = Self.dayKey(now, calendar: calendar)
        guard key != todayKey else { return }
        save()
        pastCache[todayKey] = today
        todayKey = key
        today = file(key).load() ?? [:]
        prune(now: now)
    }

    func save() {
        guard dirty else { return }
        file(todayKey).save(today)
        dirty = false
    }

    func totals(daysAgo: Int, now: Date) -> Totals {
        guard daysAgo > 0 else { return today }
        guard let date = calendar.date(byAdding: .day, value: -daysAgo, to: now) else { return [:] }
        let key = Self.dayKey(date, calendar: calendar)
        if let cached = pastCache[key] { return cached }
        let totals = file(key).load() ?? [:]
        pastCache[key] = totals
        return totals
    }

    /// Deletes day files older than `keepDays`.
    func prune(now: Date) {
        guard let cutoffDate = calendar.date(byAdding: .day, value: -Self.keepDays, to: now) else { return }
        let cutoff = Self.dayKey(cutoffDate, calendar: calendar)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in files where name.hasSuffix(".json") && name.count == 15 {
            if String(name.prefix(10)) < cutoff {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        pastCache = pastCache.filter { $0.key >= cutoff }
    }
}
