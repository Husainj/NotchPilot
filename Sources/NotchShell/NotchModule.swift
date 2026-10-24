import SwiftUI

/// A feature that lives inside the island (media, shelf, clipboard, …).
///
/// Modules are `@Observable` classes; any observable state read by
/// `compactActivity` or the views they return is tracked automatically.
@MainActor
public protocol NotchModule: AnyObject {
    var id: String { get }
    var title: String { get }
    /// SF Symbol used for the tab button.
    var systemImage: String { get }

    /// Content shown when the island is open and this module's tab is selected.
    func makeExpandedView() -> AnyView
    /// Optional settings pane shown in the Settings window.
    func makeSettingsView() -> AnyView?
    /// Optional small view in the right side of the open island's header row.
    func makeHeaderAccessory() -> AnyView?
    /// Live activity drawn beside the closed notch, or nil for none.
    var compactActivity: CompactActivity? { get }

    func start(context: NotchContext)
    func stop()
}

public extension NotchModule {
    func makeSettingsView() -> AnyView? { nil }
    func makeHeaderAccessory() -> AnyView? { nil }
    var compactActivity: CompactActivity? { nil }
}

/// What modules can ask of the island.
@MainActor
public protocol NotchContext: AnyObject {
    /// Expand the island and select the module's tab.
    func open(moduleID: String)
    /// Show a short-lived activity (e.g. a volume HUD) that preempts module activities.
    func showTransient(_ activity: CompactActivity, for duration: Duration)
}

/// Content drawn on both sides of the physical notch while the island is closed.
public struct CompactActivity {
    public let id: String
    public let priority: Int
    /// Width added on each side of the notch.
    public let sideWidth: CGFloat
    public let leading: AnyView
    public let trailing: AnyView

    public init(id: String, priority: Int = 0, sideWidth: CGFloat = 36,
                @ViewBuilder leading: () -> some View, @ViewBuilder trailing: () -> some View) {
        self.id = id
        self.priority = priority
        self.sideWidth = sideWidth
        self.leading = AnyView(leading())
        self.trailing = AnyView(trailing())
    }
}
