import CoreGraphics

/// Pure geometry for placing the island over a screen's notch.
/// Kept free of AppKit so it can be unit tested.
public struct NotchGeometry: Equatable, Sendable {
    /// Size of the physical notch (or the fake pill on screens without one).
    public let notchSize: CGSize
    /// Whether the screen has a real camera housing.
    public let hasNotch: Bool

    public static let fallbackSize = CGSize(width: 200, height: 32)

    /// - Parameters:
    ///   - screenWidth: full width of the screen in points.
    ///   - safeAreaTop: `NSScreen.safeAreaInsets.top` (0 when there is no notch).
    ///   - leftAuxWidth: width of `auxiliaryTopLeftArea`, if any.
    ///   - rightAuxWidth: width of `auxiliaryTopRightArea`, if any.
    public init(screenWidth: CGFloat, safeAreaTop: CGFloat, leftAuxWidth: CGFloat?, rightAuxWidth: CGFloat?) {
        if safeAreaTop > 0, let left = leftAuxWidth, let right = rightAuxWidth {
            let width = screenWidth - left - right
            if width > 0 {
                notchSize = CGSize(width: width, height: safeAreaTop)
                hasNotch = true
                return
            }
        }
        notchSize = Self.fallbackSize
        hasNotch = false
    }

    /// Frame (bottom-left origin, AppKit coordinates) for a panel of `panelSize`,
    /// horizontally centered and pinned to the top of `screenFrame`.
    public func panelFrame(panelSize: CGSize, screenFrame: CGRect) -> CGRect {
        CGRect(
            x: screenFrame.midX - panelSize.width / 2,
            y: screenFrame.maxY - panelSize.height,
            width: panelSize.width,
            height: panelSize.height
        )
    }
}
