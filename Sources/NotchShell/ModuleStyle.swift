import AppKit
import SwiftUI

/// A distinct colour per module, used for its tab and as the accent inside it
/// when "Colourful tabs" is on.
public enum ModulePalette {
    public static func color(for id: String) -> Color {
        switch id {
        case "media": Color(red: 1.0, green: 0.38, blue: 0.56)
        case "ai": Color(red: 0.78, green: 0.5, blue: 1.0)
        case "shelf": Color(red: 1.0, green: 0.66, blue: 0.32)
        case "clipboard": Color(red: 0.36, green: 0.62, blue: 1.0)
        case "capture": Color(red: 1.0, green: 0.36, blue: 0.3)
        case "meeting": Color(red: 0.3, green: 0.86, blue: 0.46)
        case "screentime": Color(red: 0.56, green: 0.49, blue: 1.0)
        case "timers": Color(red: 1.0, green: 0.8, blue: 0.24)
        case "notes": Color(red: 0.82, green: 0.95, blue: 0.36)
        case "calendar": Color(red: 1.0, green: 0.45, blue: 0.45)
        case "weather": Color(red: 0.4, green: 0.8, blue: 1.0)
        case "stats": Color(red: 0.25, green: 0.9, blue: 0.78)
        case "system": Color(red: 0.55, green: 0.7, blue: 1.0)
        case "mirror": Color(red: 0.9, green: 0.92, blue: 1.0)
        default: Color(red: 0.75, green: 0.75, blue: 0.85)
        }
    }

    /// The accent to use for a module, honouring the "Colourful tabs" setting.
    @MainActor
    public static func accent(for id: String?) -> Color {
        let settings = NotchSettings.shared
        guard settings.colorfulTabs, let id else { return settings.theme.accent }
        return color(for: id)
    }
}

/// A rounded, softly tinted tile for laying out widgets inside the island.
public struct IslandCard<Content: View>: View {
    private let tint: Color?
    private let padding: CGFloat
    private let content: Content
    @Environment(\.notchAccent) private var accent

    public init(tint: Color? = nil, padding: CGFloat = 10, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        let color = tint ?? accent
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                shape.fill(LinearGradient(colors: [color.opacity(0.2), color.opacity(0.06)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .background(shape.fill(.white.opacity(0.03)))
            .overlay(
                shape.strokeBorder(LinearGradient(colors: [color.opacity(0.35), .white.opacity(0.05)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing),
                                   lineWidth: 0.75)
            )
    }
}

/// A small icon in a filled, rounded square, like a Settings row icon.
public struct IconBadge: View {
    private let systemImage: String
    private let color: Color
    private let size: CGFloat

    public init(_ systemImage: String, color: Color, size: CGFloat = 22) {
        self.systemImage = systemImage
        self.color = color
        self.size = size
    }

    public var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.52, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .fill(LinearGradient(colors: [color, color.opacity(0.7)], startPoint: .top, endPoint: .bottom))
            )
            .shadow(color: color.opacity(0.45), radius: 4, y: 1)
    }
}

/// Eyes that follow the pointer and blink now and then; drawn beside the
/// closed notch so the notch looks like a little face.
struct NotchEye: View {
    var size: CGFloat = 13

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Blink every ~4s, with an occasional double blink.
            let cycle = t.truncatingRemainder(dividingBy: 4.3)
            let blinking = cycle < 0.12 || (Int(t / 4.3) % 3 == 0 && cycle > 0.22 && cycle < 0.32)
            GeometryReader { geo in
                let frame = geo.frame(in: .global)
                let offset = pupilOffset(eyeCenter: CGPoint(x: frame.midX, y: frame.midY))
                ZStack {
                    Ellipse()
                        .fill(LinearGradient(colors: [.white, Color(white: 0.82)], startPoint: .top, endPoint: .bottom))
                    Circle()
                        .fill(.black)
                        .frame(width: size * 0.5, height: size * 0.5)
                        .overlay(
                            Circle().fill(.white).frame(width: size * 0.14, height: size * 0.14)
                                .offset(x: -size * 0.08, y: -size * 0.08)
                        )
                        .offset(x: offset.width, y: offset.height)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(x: 1, y: blinking ? 0.1 : 1)
                .animation(.easeInOut(duration: 0.07), value: blinking)
            }
            .frame(width: size, height: size)
        }
    }

    /// Moves the pupil toward the pointer, up to the edge of the eye.
    private func pupilOffset(eyeCenter: CGPoint) -> CGSize {
        guard let panel = NSApp?.windows.first(where: { $0 is NotchPanel }) else { return .zero }
        let mouse = NSEvent.mouseLocation
        // Global SwiftUI coordinates are top-left based within the panel.
        let eye = CGPoint(x: panel.frame.minX + eyeCenter.x, y: panel.frame.maxY - eyeCenter.y)
        let dx = mouse.x - eye.x
        let dy = eye.y - mouse.y
        let distance = max(sqrt(dx * dx + dy * dy), 0.001)
        let reach = size * 0.22 * min(distance / 60, 1)
        return CGSize(width: dx / distance * reach, height: dy / distance * reach)
    }
}
