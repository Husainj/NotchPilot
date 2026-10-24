import SwiftUI

/// Accent styling for the island. The island body stays black so it blends
/// with the physical notch; themes change accents, fills and glow.
public enum NotchTheme: String, CaseIterable, Sendable {
    case minimal, vibrant, neon

    public var title: String {
        switch self {
        case .minimal: "Minimal"
        case .vibrant: "Vibrant"
        case .neon: "Neon"
        }
    }

    public var accent: Color {
        switch self {
        case .minimal: .white
        case .vibrant: Color(red: 0.62, green: 0.52, blue: 1.0)
        case .neon: Color(red: 0.2, green: 0.95, blue: 0.85)
        }
    }

    /// Outer glow around the open island.
    var glow: Color? {
        switch self {
        case .minimal: nil
        case .vibrant: accent.opacity(0.35)
        case .neon: accent.opacity(0.55)
        }
    }
}

private struct NotchAccentKey: EnvironmentKey {
    static let defaultValue: Color = .white
}

public extension EnvironmentValues {
    /// Theme accent for fills, progress bars and selected states inside the island.
    var notchAccent: Color {
        get { self[NotchAccentKey.self] }
        set { self[NotchAccentKey.self] = newValue }
    }
}

/// What the closed notch shows when no module has a live activity.
public enum IdleDisplay: String, CaseIterable, Sendable {
    case nothing, clock, date, customText

    public var title: String {
        switch self {
        case .nothing: "Nothing"
        case .clock: "Time"
        case .date: "Date"
        case .customText: "Custom text"
        }
    }
}

public enum OpenMode: String, CaseIterable, Sendable {
    case hover, click

    public var title: String {
        switch self {
        case .hover: "Hover"
        case .click: "Click"
        }
    }
}
