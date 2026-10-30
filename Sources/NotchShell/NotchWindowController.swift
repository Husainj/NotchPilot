import AppKit
import SwiftUI

/// Borderless panel that floats over the menu bar and never steals focus.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        ignoresMouseEvents = true
    }

    // Key status lets text fields (e.g. clipboard search) receive typing while open.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the panel, keeps it positioned over the notch, and drives the
/// closed → peek → open state machine from the mouse, drags and hotkeys.
@MainActor
public final class NotchWindowController {
    public let model: NotchViewModel
    private let settings = NotchSettings.shared
    private var panel: NotchPanel?
    private var screen: NSScreen?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var dwellTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    /// Set when opened by hotkey/drag/module request: stays open until the
    /// mouse has visited and left, the user clicks elsewhere, or presses the hotkey again.
    private var hasHoveredSinceOpen = true
    private var dragChangeCountAtMouseDown = 0
    private var isHiddenForFullScreen = false

    private static let closeDelay: Duration = .milliseconds(300)

    public init(registry: ModuleRegistry) {
        model = NotchViewModel(
            geometry: NotchGeometry(screenWidth: 0, safeAreaTop: 0, leftAuxWidth: nil, rightAuxWidth: nil),
            registry: registry
        )
        model.openHandler = { [weak self] takeFocus in self?.openProgrammatically(takeFocus: takeFocus) ?? false }
        model.closeHandler = { [weak self] in self?.setState(.closed) }
    }

    public func show() {
        layout()
        installMouseMonitors()
        registry.startEnabled(context: model)
        settings.onDisplayChange = { [weak self] in self?.layout() }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleFullScreenCheck() }
            })
        }
    }

    /// Removes the island entirely (used when the license becomes invalid).
    public func tearDown() {
        registry.stopAll()
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        panel?.orderOut(nil)
        panel = nil
    }

    public func toggle() {
        if model.state == .open { setState(.closed) } else { openProgrammatically() }
    }

    private var registry: ModuleRegistry { model.registry }

    // MARK: - Layout

    private func preferredScreen() -> NSScreen? {
        switch settings.display {
        case .builtIn:
            return NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
        case .main:
            return NSScreen.screens.first ?? NSScreen.main
        }
    }

    private func layout() {
        guard let screen = preferredScreen() else { return }
        self.screen = screen
        model.geometry = NotchGeometry(
            screenWidth: screen.frame.width,
            safeAreaTop: screen.safeAreaInsets.top,
            leftAuxWidth: screen.auxiliaryTopLeftArea?.width,
            rightAuxWidth: screen.auxiliaryTopRightArea?.width
        )
        let frame = model.geometry.panelFrame(panelSize: NotchViewModel.panelSize, screenFrame: screen.frame)
        if let panel {
            panel.setFrame(frame, display: true)
        } else {
            let panel = NotchPanel(contentRect: frame)
            panel.contentView = NSHostingView(rootView: NotchView(model: model))
            panel.orderFrontRegardless()
            self.panel = panel
        }
    }

    // MARK: - Full-screen hiding

    private func scheduleFullScreenCheck() {
        // Space-change animations finish slightly after the notification.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.updateFullScreenVisibility()
        }
    }

    private func updateFullScreenVisibility() {
        guard let panel, let screen else { return }
        let hide = settings.hideInFullScreen && Self.hasFullScreenWindow(on: screen)
        guard hide != isHiddenForFullScreen else { return }
        isHiddenForFullScreen = hide
        if hide {
            setState(.closed)
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    /// True when a normal-level window exactly covers the screen (a full-screen app).
    private static func hasFullScreenWindow(on screen: NSScreen) -> Bool {
        guard let primary = NSScreen.screens.first,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        // CG window bounds use a top-left origin relative to the primary display.
        let f = screen.frame
        let target = CGRect(x: f.minX, y: primary.frame.maxY - f.maxY, width: f.width, height: f.height)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return info.contains { window in
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { return false }
            return bounds == target
        }
    }

    // MARK: - Mouse

    private func installMouseMonitors() {
        let moved: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.mouseMoved(to: NSEvent.mouseLocation, dragging: event.type == .leftMouseDragged) }
        }
        let down: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown(at: NSEvent.mouseLocation) }
        }
        let movedMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: movedMask, handler: moved) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: movedMask, handler: { moved($0); return $0 }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: down) { monitors.append(m) }
        // Esc closes the island while it has keyboard focus.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event }
            let handled = MainActor.assumeIsolated {
                guard let self, self.model.state == .open else { return false }
                self.setState(.closed)
                return true
            }
            return handled ? nil : event
        }) { monitors.append(m) }
    }

    /// Screen-space rect of the island at its current size, plus a small margin.
    private func hotRect() -> CGRect {
        guard let screen else { return .zero }
        let margin: CGFloat = model.state == .open ? 8 : 4
        return model.geometry.panelFrame(panelSize: model.currentSize, screenFrame: screen.frame)
            .insetBy(dx: -margin, dy: -margin)
    }

    /// Global mouse-downs only arrive for clicks outside our panel.
    private func mouseDown(at point: CGPoint) {
        dragChangeCountAtMouseDown = NSPasteboard(name: .drag).changeCount
        let inside = hotRect().contains(point)
        if model.state == .open, !inside {
            setState(.closed)
        } else if model.state != .open, inside {
            // Clicking the notch opens it (the only way in click-to-open mode).
            dwellTask?.cancel()
            hasHoveredSinceOpen = true
            setState(.open)
        }
    }

    private func mouseMoved(to point: CGPoint, dragging: Bool) {
        guard !isHiddenForFullScreen else { return }
        let inside = hotRect().contains(point)
        model.isPointerInside = inside
        if inside {
            hasHoveredSinceOpen = true
            closeTask?.cancel(); closeTask = nil
            if dragging, isNewFileDrag() {
                // Dragging files onto the notch opens the shelf right away.
                dwellTask?.cancel()
                if registry.isEnabled("shelf") { model.selectedModuleID = "shelf" }
                setState(.open)
                return
            }
            if model.state == .closed {
                setState(.peek)
                guard settings.openMode == .hover else { return }
                let delay = Duration.milliseconds(Int(settings.hoverOpenDelay * 1000))
                dwellTask = Task { [weak self] in
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                    self?.setState(.open)
                }
            }
        } else if model.state != .closed, closeTask == nil, hasHoveredSinceOpen {
            dwellTask?.cancel(); dwellTask = nil
            closeTask = Task { [weak self] in
                try? await Task.sleep(for: Self.closeDelay)
                guard !Task.isCancelled else { return }
                self?.closeTask = nil
                self?.setState(.closed)
            }
        }
    }

    private func isNewFileDrag() -> Bool {
        let pasteboard = NSPasteboard(name: .drag)
        return pasteboard.changeCount != dragChangeCountAtMouseDown
            && pasteboard.types?.contains(.fileURL) == true
    }

    @discardableResult
    private func openProgrammatically(takeFocus: Bool = true) -> Bool {
        guard panel != nil, !isHiddenForFullScreen else { return false }
        dwellTask?.cancel(); closeTask?.cancel(); closeTask = nil
        hasHoveredSinceOpen = hotRect().contains(NSEvent.mouseLocation)
        setState(.open)
        if takeFocus { panel?.makeKey() }
        return true
    }

    private func setState(_ state: NotchState) {
        guard model.state != state else { return }
        model.state = state
        if state == .open, settings.haptics {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        // Only capture clicks while open; otherwise let them reach the menu bar.
        panel?.ignoresMouseEvents = state != .open
        // Give keyboard focus back to the user's app (ordering out drops key status).
        if state == .closed, let panel, panel.isKeyWindow {
            panel.orderOut(nil)
            if !isHiddenForFullScreen { panel.orderFrontRegardless() }
        }
    }
}
