import AppKit
import SwiftUI

/// The button style for everything inside the island: the whole label (plus
/// a few points around it) is clickable, it brightens on hover and springs
/// when pressed.
public struct IslandButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        IslandButtonBody(configuration: configuration)
    }
}

public extension ButtonStyle where Self == IslandButtonStyle {
    static var island: IslandButtonStyle { IslandButtonStyle() }
}

private struct IslandButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            // Plain buttons only react on the glyph's pixels; make the whole
            // frame, and a little margin, clickable.
            .contentShape(Rectangle().inset(by: -4))
            .brightness(hovering && isEnabled ? 0.12 : 0)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Blur, fade and a slight scale: the island's standard transition.
struct BlurFade: ViewModifier {
    let active: Bool
    var scale: CGFloat = 0.94
    var anchor: UnitPoint = .top

    func body(content: Content) -> some View {
        content
            .blur(radius: active ? 8 : 0)
            .opacity(active ? 0 : 1)
            .scaleEffect(active ? scale : 1, anchor: anchor)
    }
}

extension AnyTransition {
    static func blurFade(scale: CGFloat = 0.94, anchor: UnitPoint = .top) -> AnyTransition {
        .modifier(active: BlurFade(active: true, scale: scale, anchor: anchor),
                  identity: BlurFade(active: false, scale: scale, anchor: anchor))
    }
}

enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Opening and resizing: a little bounce, like the Dynamic Island.
    static var island: Animation {
        reduced ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.74)
    }

    static var content: Animation {
        reduced ? .easeInOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.86)
    }
}
