import AppKit
import SwiftUI

/// Dims every screen and lets the user drag a rectangle to record.
/// Returns the screen and the rect in that display's top-left-origin points.
@MainActor
final class AreaSelector {
    private var windows: [NSWindow] = []
    private var continuation: CheckedContinuation<MainActorBox<(NSScreen, CGRect)?>, Never>?
    private var keyMonitor: Any?

    func select() async -> (NSScreen, CGRect)? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            NSApp.activate()
            for screen in NSScreen.screens {
                let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.level = .screenSaver
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = false
                window.isReleasedWhenClosed = false
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                window.contentView = NSHostingView(rootView: AreaSelectionView(scale: screen.backingScaleFactor) { [weak self] rect in
                    self?.finish(rect.map { (screen, $0) })
                })
                window.setFrame(screen.frame, display: true)
                window.makeKeyAndOrderFront(nil)
                windows.append(window)
            }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return event } // Esc
                self?.finish(nil)
                return nil
            }
        }.value
    }

    private func finish(_ result: (NSScreen, CGRect)?) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        continuation?.resume(returning: MainActorBox(value: result))
        continuation = nil
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    // Cover the menu bar too.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private struct AreaSelectionView: View {
    let scale: CGFloat
    let done: (CGRect?) -> Void
    @State private var start: CGPoint?
    @State private var current: CGPoint?

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let rect = selectionRect(in: bounds)
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.black.opacity(0.35))
                    .overlay(alignment: .topLeading) {
                        if let rect {
                            Rectangle()
                                .frame(width: rect.width, height: rect.height)
                                .offset(x: rect.minX, y: rect.minY)
                                .blendMode(.destinationOut)
                        }
                    }
                    .compositingGroup()

                if let rect {
                    Rectangle()
                        .strokeBorder(.white, lineWidth: 1.5)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                    Text("\(Int(rect.width * scale)) × \(Int(rect.height * scale))")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.7), in: Capsule())
                        .foregroundStyle(.white)
                        .offset(x: rect.minX, y: max(rect.minY - 24, 4))
                } else {
                    Text("Drag to choose the area to record  ·  Esc to cancel")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.7), in: Capsule())
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if start == nil { start = value.startLocation }
                        current = value.location
                    }
                    .onEnded { value in
                        let picked = AreaGeometry.selection(from: value.startLocation, to: value.location,
                                                            in: bounds, scale: scale)
                        start = nil
                        current = nil
                        if let picked { done(picked) }
                    }
            )
            .onHover { inside in
                if inside { NSCursor.crosshair.set() }
            }
        }
        .ignoresSafeArea()
    }

    private func selectionRect(in bounds: CGRect) -> CGRect? {
        guard let start, let current else { return nil }
        let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                          width: abs(current.x - start.x), height: abs(current.y - start.y))
        return rect.intersection(bounds)
    }
}

/// Carries main-actor-only values (AppKit and ScreenCaptureKit objects)
/// through a continuation that's resumed on the main actor.
struct MainActorBox<Value>: @unchecked Sendable {
    let value: Value
}
