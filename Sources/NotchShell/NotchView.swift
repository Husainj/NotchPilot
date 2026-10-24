import SwiftUI

struct NotchView: View {
    let model: NotchViewModel

    private static let spring = Animation.spring(response: 0.38, dampingFraction: 0.8)

    var body: some View {
        let size = model.currentSize
        let isOpen = model.state == .open
        let theme = NotchSettings.shared.theme
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(topRadius: isOpen ? 14 : 6, bottomRadius: isOpen ? 28 : 12)
                    .fill(.black)
                    .shadow(color: isOpen ? (theme.glow ?? .clear) : .clear, radius: 16)
                Group {
                    if isOpen {
                        OpenIslandView(model: model)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    } else if let activity = model.activeActivity {
                        CompactActivityView(activity: activity, notchSize: model.geometry.notchSize)
                            .transition(.opacity)
                    }
                }
                .clipShape(NotchShape(topRadius: isOpen ? 14 : 6, bottomRadius: isOpen ? 28 : 12))
            }
            .frame(width: size.width, height: size.height)
            .animation(Self.spring, value: model.layoutKey)
            Spacer(minLength: 0)
        }
        .frame(width: NotchViewModel.panelSize.width, height: NotchViewModel.panelSize.height, alignment: .top)
        .environment(\.colorScheme, .dark)
        .environment(\.notchAccent, theme.accent)
        .tint(theme.accent)
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

    private static let horizontalPadding: CGFloat = 24

    var body: some View {
        let notch = model.geometry.notchSize
        let sideWidth = (NotchViewModel.openSize.width - 2 * Self.horizontalPadding - notch.width) / 2
        let selected = model.selectedModule
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(model.registry.enabled, id: \.id) { module in
                            TabButton(systemImage: module.systemImage, title: module.title,
                                      isSelected: module.id == selected?.id) {
                                model.selectedModuleID = module.id
                            }
                        }
                    }
                }
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

            Group {
                if let selected {
                    selected.makeExpandedView()
                } else {
                    Text("No modules enabled. Turn some on in Settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.bottom, 14)
        .foregroundStyle(.white)
    }
}

private struct TabButton: View {
    let systemImage: String
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.notchAccent) private var accent

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 22)
                .background(isSelected ? accent.opacity(0.22) : .clear, in: Capsule())
                .foregroundStyle(isSelected ? accent : .white.opacity(0.55))
        }
        .buttonStyle(.plain)
        .help(title)
    }
}
