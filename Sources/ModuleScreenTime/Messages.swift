import Foundation

enum Mood: Equatable, Sendable {
    case happy, concerned, sassy, serious, sleepy

    static func forLevel(_ level: Int) -> Mood {
        switch level {
        case ...1: .concerned
        case 2: .sassy
        default: .serious
        }
    }
}

/// What the mascot says. Lines rotate so the same one never shows twice in a row.
struct Messages {
    static let lines: [Int: [String]] = [
        1: [
            "Hey, that's {minutes} min on {app}. Quick reset?",
            "{minutes} minutes of {app} already. Time flies, huh?",
            "Psst. {app} has had you for {minutes} min.",
            "Still on {app}? It's been {minutes} minutes.",
            "Small check-in: {minutes} min of {app}. Want to switch gears?",
            "{app} will still be there later. Your tasks are waiting.",
            "You've been scrolling {app} for {minutes} min. Stretch, then one task?",
            "Loving {app}? Me too. But {minutes} minutes is a lot.",
        ],
        2: [
            "{minutes} minutes of {app}… the tasks below aren't going to do themselves.",
            "Bro. {minutes} minutes. On {app}. Come on.",
            "I said 5 more minutes, not 5 more reels.",
            "{app} again? Your to-do list is getting lonely.",
            "This is your pilot speaking: we're drifting off course. {minutes} min on {app}.",
            "You're losing focus, friend. {minutes} minutes of {app}.",
            "Plot twist: the next video won't be the last one either.",
            "{minutes} min on {app}. Future you is begging for a win right now.",
        ],
        3: [
            "Okay, real talk. {minutes} minutes. Close {app} and pick one task. Just one.",
            "{minutes} minutes. I'm not mad, just disappointed. Pick a task.",
            "Mayday, mayday. {minutes} minutes on {app}. Back to work, captain.",
            "That's {minutes} minutes of {app} you won't get back. Let's go.",
            "Close {app}. Breathe. Start the first task below. You've got this.",
            "Enough scrolling. {minutes} minutes. One task, then you've earned it.",
        ],
    ]

    static let breakOver = [
        "Break's over! Ready for one focused round?",
        "Hope that was a good break. Let's knock out a task.",
        "Recharged? Pick something small and start.",
    ]

    static let cheers = ["Let's go! 🚀", "That's the spirit!", "Proud of you. One task at a time.", "Back on course, captain! ✈️"]

    private var lastIndex: [Int: Int] = [:]

    /// Picks a line for `level` (0 = break over), avoiding the previous one.
    mutating func line(level: Int, app: String, minutes: Int) -> String {
        let pool = level == 0 ? Self.breakOver : (Self.lines[min(max(level, 1), 3)] ?? [])
        guard !pool.isEmpty else { return "" }
        var index = Int.random(in: 0..<pool.count)
        if pool.count > 1, index == lastIndex[level] { index = (index + 1) % pool.count }
        lastIndex[level] = index
        return pool[index]
            .replacingOccurrences(of: "{app}", with: app)
            .replacingOccurrences(of: "{minutes}", with: "\(minutes)")
    }
}
