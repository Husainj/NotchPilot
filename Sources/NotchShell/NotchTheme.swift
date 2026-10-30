import SwiftUI

/// Accent styling for the island. The island body stays black so it blends
/// with the physical notch; themes change accents, a soft tint at the bottom,
/// the edge highlight and the glow.
public enum NotchTheme: String, CaseIterable, Identifiable, Sendable {
    case minimal, vibrant, neon, sunset, ocean, forest, rose, gold, aurora

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .minimal: "Minimal"
        case .vibrant: "Vibrant"
        case .neon: "Neon"
        case .sunset: "Sunset"
        case .ocean: "Ocean"
        case .forest: "Forest"
        case .rose: "Rose"
        case .gold: "Gold"
        case .aurora: "Aurora"
        }
    }

    public var accent: Color { colors[0] }

    /// The theme's palette, first colour is the accent.
    public var colors: [Color] {
        switch self {
        case .minimal: [.white, Color(white: 0.6)]
        case .vibrant: [Color(red: 0.62, green: 0.52, blue: 1.0), Color(red: 0.95, green: 0.45, blue: 0.85)]
        case .neon: [Color(red: 0.2, green: 0.95, blue: 0.85), Color(red: 0.3, green: 0.6, blue: 1.0)]
        case .sunset: [Color(red: 1.0, green: 0.6, blue: 0.3), Color(red: 1.0, green: 0.35, blue: 0.55)]
        case .ocean: [Color(red: 0.38, green: 0.72, blue: 1.0), Color(red: 0.3, green: 0.92, blue: 0.95)]
        case .forest: [Color(red: 0.42, green: 0.9, blue: 0.56), Color(red: 0.78, green: 0.95, blue: 0.4)]
        case .rose: [Color(red: 1.0, green: 0.52, blue: 0.68), Color(red: 1.0, green: 0.74, blue: 0.82)]
        case .gold: [Color(red: 1.0, green: 0.8, blue: 0.36), Color(red: 1.0, green: 0.58, blue: 0.24)]
        case .aurora: [Color(red: 0.45, green: 0.95, blue: 0.75), Color(red: 0.35, green: 0.7, blue: 1.0),
                       Color(red: 0.7, green: 0.45, blue: 1.0), Color(red: 1.0, green: 0.45, blue: 0.75)]
        }
    }

    /// Outer glow around the open island.
    var glow: Color? {
        switch self {
        case .minimal: nil
        case .neon: accent.opacity(0.55)
        case .aurora: colors[2].opacity(0.45)
        default: accent.opacity(0.35)
        }
    }

    /// How strongly the bottom of the open island is tinted with the palette.
    var tintStrength: Double {
        switch self {
        case .minimal: 0
        case .neon, .aurora: 0.16
        default: 0.12
        }
    }

    /// A slowly rotating gradient edge around the open island.
    var hasAnimatedEdge: Bool { self == .aurora || self == .neon }
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

/// Theme swatches for the Settings window.
public struct ThemePicker: View {
    @Binding var theme: NotchTheme

    public init(theme: Binding<NotchTheme>) {
        _theme = theme
    }

    public var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 12) {
            ForEach(NotchTheme.allCases) { item in
                Button { theme = item } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(.black)
                            Circle()
                                .fill(AngularGradient(colors: item.colors + [item.colors[0]], center: .center))
                                .padding(item == .minimal ? 12 : 6)
                                .blur(radius: item == .minimal ? 0 : 1)
                            if theme == item {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.black)
                            }
                        }
                        .frame(width: 40, height: 40)
                        .overlay(Circle().strokeBorder(theme == item ? item.accent : .white.opacity(0.15),
                                                       lineWidth: theme == item ? 2 : 1))
                        .shadow(color: theme == item ? (item.glow ?? .clear) : .clear, radius: 6)
                        Text(item.title)
                            .font(.caption)
                            .foregroundStyle(theme == item ? .primary : .secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
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
