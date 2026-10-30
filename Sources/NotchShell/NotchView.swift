import SwiftUI

struct NotchView: View {
    let model: NotchViewModel

    var body: some View {
        let size = model.currentSize
        let isOpen = model.state == .open
        let theme = NotchSettings.shared.theme
        let shape = NotchShape(topRadius: isOpen ? 14 : 6, bottomRadius: isOpen ? 30 : 12)
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                IslandBackground(shape: shape, theme: theme, isOpen: isOpen)
                Group {
                    if isOpen {
                        OpenIslandView(model: model)
                            .transition(.blurFade(scale: 0.9))
                    } else if let activity = model.activeActivity {
                        CompactActivityView(activity: activity, notchSize: model.geometry.notchSize)
                            .id(activity.id)
                            .transition(.blurFade(scale: 0.8, anchor: .center))
                    }
                }
                .clipShape(shape)
            }
            .frame(width: size.width, height: size.height)
            .animation(Motion.island, value: model.layoutKey)
            Spacer(minLength: 0)
        }
        .frame(width: NotchViewModel.panelSize.width, height: NotchViewModel.panelSize.height, alignment: .top)
        .environment(\.colorScheme, .dark)
        .environment(\.notchAccent, theme.accent)
        .tint(theme.accent)
    }
}

/// Black body with the theme's soft bottom tint, a fine edge highlight and glow.
private struct IslandBackground: View {
    let shape: NotchShape
    let theme: NotchTheme
    let isOpen: Bool

    var body: some View {
        shape
            .fill(.black)
            .overlay {
                if isOpen, theme.tintStrength > 0 {
                    shape.fill(
                        RadialGradient(colors: [theme.colors[min(1, theme.colors.count - 1)].opacity(theme.tintStrength), .clear],
                                       center: .bottom, startRadius: 0, endRadius: 320)
                    )
                    .transition(.opacity)
                }
            }
            .overlay {
                if isOpen {
                    if theme.hasAnimatedEdge, !Motion.reduced {
                        AnimatedEdge(shape: shape, colors: theme.colors)
                            .transition(.opacity)
                    } else {
                        // Fades in toward the bottom so the top still melts into the menu bar.
                        shape.stroke(
                            LinearGradient(colors: [.clear, .white.opacity(theme == .minimal ? 0.14 : 0.08),
                                                    theme.accent.opacity(theme == .minimal ? 0.1 : 0.35)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1
                        )
                        .transition(.opacity)
                    }
                }
            }
            .shadow(color: isOpen ? (theme.glow ?? .clear) : .clear, radius: 18)
            .shadow(color: .black.opacity(isOpen ? 0.45 : 0), radius: 14, y: 6)
    }
}

/// A gradient border that slowly travels around the island.
private struct AnimatedEdge: View {
    let shape: NotchShape
    let colors: [Color]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let angle = Angle.degrees(context.date.timeIntervalSinceReferenceDate * 40)
            let gradient = AngularGradient(colors: colors + [colors[0]], center: .center, angle: angle)
            ZStack {
                shape.stroke(gradient, lineWidth: 1.5)
                    .blur(radius: 3)
                    .opacity(0.8)
                shape.stroke(gradient, lineWidth: 1)
            }
            // Keep the top edge, which touches the menu bar, invisible.
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .white, location: 0.25)],
                                 startPoint: .top, endPoint: .bottom))
        }
    }
}

private struct CompactActivityView: View {
    let activity: CompactActivity
    let notchSize: CGSize

    var body: some View {
        HStack(spacing: 0) {
            activity.leading
                .frame(width: activity.sideWidth, height: notchSize.height)
            Spacer(minLength: notchSize.width)
            activity.trailing
                .frame(width: activity.sideWidth, height: notchSize.height)
        }
        .padding(.horizontal, 6)
        .frame(height: notchSize.height)
    }
}

private struct OpenIslandView: View {
    let model: NotchViewModel
    @Namespace private var tabs
    @Environment(\.notchAccent) private var accent

    private static let horizontalPadding: CGFloat = 26

    var body: some View {
        let notch = model.geometry.notchSize
        let sideWidth = (NotchViewModel.openSize.width - 2 * Self.horizontalPadding - notch.width) / 2
        let selected = model.selectedModule
        VStack(spacing: 8) {
            // The middle of this row sits behind the camera, so only the
            // outer edges hold content; the tabs live at the bottom.
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    if let selected {
                        Image(systemName: selected.systemImage)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(accent)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    Text(selected?.title ?? "")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .contentTransition(.opacity)
                        .lineLimit(1)
                }
                .animation(Motion.content, value: selected?.id)
                .frame(width: sideWidth, alignment: .leading)
                Spacer(minLength: notch.width)
                HStack(spacing: 8) {
                    ForEach(model.registry.enabled, id: \.id) { module in
                        module.makeHeaderAccessory()
                    }
                }
                .frame(width: sideWidth, alignment: .trailing)
            }
            .frame(height: notch.height)

            ZStack {
                if let selected {
                    selected.makeExpandedView()
                        .id(selected.id)
                        .transition(.blurFade(scale: 0.98, anchor: .center))
                } else {
                    Text("No modules enabled. Turn some on in Settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(Motion.content, value: selected?.id)

            HStack(spacing: 2) {
                ForEach(model.registry.enabled, id: \.id) { module in
                    TabButton(systemImage: module.systemImage, title: module.title,
                              isSelected: module.id == selected?.id, namespace: tabs) {
                        model.selectedModuleID = module.id
                    }
                }
            }
            .padding(3)
            .background(.white.opacity(0.07), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.06)))
            .animation(Motion.content, value: selected?.id)
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.bottom, 12)
        .foregroundStyle(.white)
    }
}

private struct TabButton: View {
    let systemImage: String
    let title: String
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @Environment(\.notchAccent) private var accent
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .symbolEffect(.bounce, value: isSelected)
                .frame(width: 36, height: 30)
                .foregroundStyle(isSelected ? accent : .white.opacity(hovering ? 0.9 : 0.55))
                .background {
                    if isSelected {
                        Capsule()
                            .fill(accent.opacity(0.2))
                            .overlay(Capsule().strokeBorder(accent.opacity(0.35), lineWidth: 0.5))
                            .shadow(color: accent.opacity(0.35), radius: 6)
                            .matchedGeometryEffect(id: "selectedTab", in: namespace)
                    } else if hovering {
                        Capsule().fill(.white.opacity(0.08))
                    }
                }
        }
        .buttonStyle(.island)
        .onHover { hovering = $0 }
        .help(title)
    }
}
