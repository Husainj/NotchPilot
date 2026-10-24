import Foundation

/// Token counts for one request (or a sum of requests).
struct TokenUsage: Equatable, Sendable {
    var input = 0
    var output = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    var cacheRead = 0

    var total: Int { input + output + cacheWrite5m + cacheWrite1h + cacheRead }

    static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(input: a.input + b.input, output: a.output + b.output,
                   cacheWrite5m: a.cacheWrite5m + b.cacheWrite5m, cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h,
                   cacheRead: a.cacheRead + b.cacheRead)
    }

    static func += (a: inout TokenUsage, b: TokenUsage) { a = a + b }
}

/// API list prices in USD per million tokens. Subscription users don't pay
/// these; the app shows them as "API-equivalent" cost, which is still the best
/// local measure of how hard you're pushing your plan.
struct ModelPricing: Equatable, Sendable {
    let input: Double
    let output: Double

    // Cache multipliers are the same for every Claude model.
    var cacheWrite5m: Double { input * 1.25 }
    var cacheWrite1h: Double { input * 2 }
    var cacheRead: Double { input * 0.1 }

    func cost(_ u: TokenUsage) -> Double {
        (Double(u.input) * input + Double(u.output) * output + Double(u.cacheWrite5m) * cacheWrite5m
            + Double(u.cacheWrite1h) * cacheWrite1h + Double(u.cacheRead) * cacheRead) / 1_000_000
    }

    /// Matched by model-id fragments so new point releases get a sensible price.
    /// Unknown models are priced like the current Opus.
    static func claude(_ model: String) -> ModelPricing {
        let m = model.lowercased()
        if m.contains("haiku") {
            if m.contains("3-5") { return ModelPricing(input: 0.8, output: 4) }
            if m.contains("claude-3-haiku") { return ModelPricing(input: 0.25, output: 1.25) }
            return ModelPricing(input: 1, output: 5)
        }
        if m.contains("sonnet") {
            if m.contains("sonnet-4") || m.contains("3-7-sonnet") || m.contains("3-5-sonnet") {
                return ModelPricing(input: 3, output: 15)
            }
            return ModelPricing(input: 2, output: 10)
        }
        if m.contains("opus") {
            if m.contains("claude-3-opus") || m.contains("opus-4-0") || m.contains("opus-4-1") || m.contains("opus-4-2025") {
                return ModelPricing(input: 15, output: 75)
            }
            if m.contains("opus-4") || m.hasSuffix("opus-5") || m.contains("opus-5-2") {
                return ModelPricing(input: 5, output: 25)
            }
        }
        return ModelPricing(input: 4, output: 20)
    }
}

/// One billed Claude Code request read from a transcript.
struct UsageEntry: Equatable, Sendable {
    let date: Date
    let model: String
    let usage: TokenUsage

    var cost: Double { ModelPricing.claude(model).cost(usage) }
}

/// Claude's usage limits reset on rolling 5-hour windows that start with the
/// first message after the previous window ends (rounded down to the hour).
struct UsageBlock: Equatable, Sendable {
    static let length: TimeInterval = 5 * 3600

    let start: Date
    var lastActivity: Date
    var usage = TokenUsage()
    var cost: Double = 0

    var end: Date { start.addingTimeInterval(Self.length) }

    func isActive(at now: Date) -> Bool { now < end }

    /// Dollars per hour since the window started.
    func burnRate(at now: Date) -> Double {
        let hours = max(min(now, end).timeIntervalSince(start), 600) / 3600
        return cost / hours
    }

    static func blocks(from entries: [UsageEntry]) -> [UsageBlock] {
        var blocks: [UsageBlock] = []
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            if var current = blocks.last,
               entry.date < current.end, entry.date.timeIntervalSince(current.lastActivity) < length {
                current.lastActivity = entry.date
                current.usage += entry.usage
                current.cost += entry.cost
                blocks[blocks.count - 1] = current
            } else {
                let hour = floor(entry.date.timeIntervalSinceReferenceDate / 3600) * 3600
                blocks.append(UsageBlock(start: Date(timeIntervalSinceReferenceDate: hour), lastActivity: entry.date,
                                         usage: entry.usage, cost: entry.cost))
            }
        }
        return blocks
    }
}

struct DailyUsage: Equatable, Sendable, Identifiable {
    let day: Date
    var claudeCost: Double = 0
    var claudeTokens = 0
    var codexTokens = 0

    var id: Date { day }
}

/// Codex reports its real plan limits in every session log.
struct CodexLimit: Equatable, Sendable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date?

    var label: String {
        if windowMinutes >= 24 * 60 * 6 { return "Week" }
        if windowMinutes >= 24 * 60 { return "\(windowMinutes / 1440)d" }
        return "\(Int((Double(windowMinutes) / 60).rounded()))h"
    }
}

struct CodexLimits: Equatable, Sendable {
    var primary: CodexLimit?
    var secondary: CodexLimit?
    let observedAt: Date
}

/// Everything the AI tab shows about usage, computed off the main thread.
struct UsageSnapshot: Equatable, Sendable {
    var hasClaude = false
    var hasCodex = false
    var currentBlock: UsageBlock?
    /// Largest earlier window, as a rough stand-in for the plan's limit.
    var peakBlockCost: Double = 0
    var today = TokenUsage()
    var todayCost: Double = 0
    var todayByModel: [(model: String, cost: Double)] = []
    /// Last 7 days, oldest first.
    var days: [DailyUsage] = []
    var codexTodayTokens = 0
    var codexLimits: CodexLimits?

    var weekCost: Double { days.reduce(0) { $0 + $1.claudeCost } }

    static func == (a: UsageSnapshot, b: UsageSnapshot) -> Bool {
        a.hasClaude == b.hasClaude && a.hasCodex == b.hasCodex && a.currentBlock == b.currentBlock
            && a.peakBlockCost == b.peakBlockCost && a.today == b.today && a.days == b.days
            && a.codexTodayTokens == b.codexTodayTokens && a.codexLimits == b.codexLimits
    }

    static func make(claude: [UsageEntry], codex: [(date: Date, tokens: Int)], codexLimits: CodexLimits?,
                     hasClaude: Bool, hasCodex: Bool, now: Date, calendar: Calendar = .current) -> UsageSnapshot {
        var snapshot = UsageSnapshot(hasClaude: hasClaude, hasCodex: hasCodex, codexLimits: codexLimits)

        let blocks = UsageBlock.blocks(from: claude)
        if let last = blocks.last, last.isActive(at: now) {
            snapshot.currentBlock = last
            snapshot.peakBlockCost = blocks.dropLast().map(\.cost).max() ?? 0
        } else {
            snapshot.peakBlockCost = blocks.map(\.cost).max() ?? 0
        }

        let todayStart = calendar.startOfDay(for: now)
        snapshot.days = (0..<7).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: todayStart).map { DailyUsage(day: $0) }
        }
        let index = Dictionary(uniqueKeysWithValues: snapshot.days.enumerated().map { ($1.day, $0) })
        var byModel: [String: Double] = [:]
        for entry in claude {
            let day = calendar.startOfDay(for: entry.date)
            guard let i = index[day] else { continue }
            let cost = entry.cost
            snapshot.days[i].claudeCost += cost
            snapshot.days[i].claudeTokens += entry.usage.total
            if day == todayStart {
                snapshot.today += entry.usage
                snapshot.todayCost += cost
                byModel[entry.model, default: 0] += cost
            }
        }
        for item in codex {
            let day = calendar.startOfDay(for: item.date)
            guard let i = index[day] else { continue }
            snapshot.days[i].codexTokens += item.tokens
            if day == todayStart { snapshot.codexTodayTokens += item.tokens }
        }
        snapshot.todayByModel = byModel.map { ($0.key, $0.value) }.sorted { $0.cost > $1.cost }
        return snapshot
    }
}

enum UsageFormat {
    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000_000...: String(format: "%.1fB", Double(n) / 1e9)
        case 1_000_000...: String(format: "%.1fM", Double(n) / 1e6)
        case 1000...: String(format: "%.0fK", Double(n) / 1e3)
        default: "\(n)"
        }
    }

    static func dollars(_ value: Double) -> String {
        value >= 100 ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(Int(seconds / 60), 0)
        if minutes >= 24 * 60 { return "\(minutes / 1440)d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }

    /// "claude-opus-5-5" → "Opus 5.5"
    static func modelName(_ model: String) -> String {
        var parts = model.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        // Drop date suffixes like 20250514.
        parts.removeAll { $0.count == 8 && Int($0) != nil }
        guard let family = parts.first else { return model }
        let version = parts.dropFirst().joined(separator: ".")
        return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " " + version)
    }
}
