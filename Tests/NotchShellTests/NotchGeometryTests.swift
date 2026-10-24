import CoreGraphics
import Testing
@testable import NotchShell

@Test func notchSizeComesFromAuxiliaryAreas() {
    // 14" MacBook Pro: 1512pt wide, ~185pt notch, 32pt menu bar.
    let g = NotchGeometry(screenWidth: 1512, safeAreaTop: 32, leftAuxWidth: 663, rightAuxWidth: 664)
    #expect(g.hasNotch)
    #expect(g.notchSize == CGSize(width: 185, height: 32))
}

@Test func screensWithoutNotchUseFallbackPill() {
    let g = NotchGeometry(screenWidth: 2560, safeAreaTop: 0, leftAuxWidth: nil, rightAuxWidth: nil)
    #expect(!g.hasNotch)
    #expect(g.notchSize == NotchGeometry.fallbackSize)
}

@Test func panelIsCenteredAndPinnedToTop() {
    let g = NotchGeometry(screenWidth: 1512, safeAreaTop: 32, leftAuxWidth: 663, rightAuxWidth: 664)
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let frame = g.panelFrame(panelSize: CGSize(width: 640, height: 190), screenFrame: screen)
    #expect(frame == CGRect(x: 436, y: 792, width: 640, height: 190))
}
