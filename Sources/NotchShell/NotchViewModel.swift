import SwiftUI

public enum NotchState: Equatable, Sendable {
    case closed, peek, open
}

@MainActor
@Observable
public final class NotchViewModel: NotchContext {
    public internal(set) var state: NotchState = .closed
    public internal(set) var geometry: NotchGeometry
    public let registry: ModuleRegistry
    public var selectedModuleID: String?
    public private(set) var transient: CompactActivity?

    /// Largest size the island grows to; the panel is always this big and
    /// the shape animates inside it.
    public static let openSize = CGSize(width: 680, height: 272)
    /// Extra room around the open island so the theme glow isn't clipped.
    static let glowMargin = CGSize(width: 24, height: 24)
    static var panelSize: CGSize {
        CGSize(width: openSize.width + 2 * glowMargin.width, height: openSize.height + glowMargin.height)
    }

    /// Updated on every mouse move, so not observed.
    @ObservationIgnored public internal(set) var isPointerInside = false
    @ObservationIgnored var openHandler: ((Bool) -> Bool)?
    @ObservationIgnored var closeHandler: (() -> Void)?
    @ObservationIgnored private var transientTask: Task<Void, Never>?

    init(geometry: NotchGeometry, registry: ModuleRegistry) {
        self.geometry = geometry
        self.registry = registry
    }

    // MARK: NotchContext

    @discardableResult
    public func open(moduleID: String, takeFocus: Bool) -> Bool {
        selectedModuleID = moduleID
        return openHandler?(takeFocus) ?? false
    }

    public func close() {
        closeHandler?()
    }

    public func select(moduleID: String) {
        selectedModuleID = moduleID
    }

    public func showTransient(_ activity: CompactActivity, for duration: Duration) {
        transient = activity
        transientTask?.cancel()
        transientTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.transient = nil
        }
    }

    // MARK: Derived state

    /// Highest-priority live activity to show while closed.
    var activeActivity: CompactActivity? {
        if let transient { return transient }
        let settings = NotchSettings.shared
        if settings.showLiveActivities,
           let live = registry.enabled.compactMap(\.compactActivity).max(by: { $0.priority < $1.priority }) {
            return live
        }
        return idleActivity(settings)
    }

    /// Always-on clock/date/text shown when nothing is live.
    private func idleActivity(_ settings: NotchSettings) -> CompactActivity? {
        switch settings.idleDisplay {
        case .nothing:
            return nil
        case .clock:
            return CompactActivity(id: "idle-clock", priority: -1, sideWidth: 46) {
                EmptyView()
            } trailing: {
                IdleText { $0.formatted(date: .omitted, time: .shortened) }
            }
        case .date:
            return CompactActivity(id: "idle-date", priority: -1, sideWidth: 56) {
                EmptyView()
            } trailing: {
                IdleText { $0.formatted(.dateTime.weekday(.abbreviated).day()) }
            }
        case .customText:
            let text = settings.idleCustomText.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            let width = min(max(CGFloat(text.count) * 7 + 8, 40), 160)
            return CompactActivity(id: "idle-text-\(text)", priority: -1, sideWidth: width) {
                EmptyView()
            } trailing: {
                Text(text)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(settings.theme.accent)
                    .lineLimit(1)
            }
        }
    }

    var selectedModule: (any NotchModule)? {
        let enabled = registry.enabled
        return enabled.first { $0.id == selectedModuleID } ?? enabled.first
    }

    var currentSize: CGSize {
        let n = geometry.notchSize
        switch state {
        case .open:
            return Self.openSize
        case .closed, .peek:
            let side = activeActivity?.sideWidth ?? 0
            let grow: CGFloat = state == .peek ? 12 : 0
            return CGSize(width: n.width + 2 * side + 2 * grow, height: n.height + (state == .peek ? 6 : 0))
        }
    }

    /// Changes whenever the island's shape should animate.
    var layoutKey: String {
        "\(state)-\(activeActivity?.id ?? "none")"
    }
}

/// Minute-accurate text for the idle clock/date.
private struct IdleText: View {
    let format: (Date) -> String

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(format(context.date))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
        }
    }
}
