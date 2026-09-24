import CoreGraphics
import Testing
@testable import ClaudexCore

@Suite("NotchGeometry")
struct NotchGeometryTests {
    /// Values measured on a 14" MacBook Pro (Mac16,8) at the default "looks like 1512x982".
    static let mbp14 = ScreenDescriptor(
        displayID: 1,
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 78, width: 1512, height: 871),
        safeAreaTop: 32,
        auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 663, height: 32),
        auxiliaryTopRight: CGRect(x: 848, y: 950, width: 664, height: 32),
        backingScale: 2,
        isPrimary: true
    )

    @Test func hardwareNotchOnMacBookPro14() {
        let g = NotchGeometry.compute(Self.mbp14)
        #expect(g.kind == .hardware)
        #expect(g.notch == CGRect(x: 663, y: 950, width: 185, height: 32))
        #expect(g.notch.midX == 755.5)
        #expect(g.bandHeight == 32)
        #expect(!g.menuBarAutoHidden)
    }

    @Test func virtualPillOnExternalDisplay() {
        let s = ScreenDescriptor(
            displayID: 2,
            frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415),
            safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil,
            backingScale: 2, isPrimary: false
        )
        let g = NotchGeometry.compute(s)
        #expect(g.kind == .virtual)
        #expect(g.bandHeight == 25)
        #expect(g.notch.midX == s.frame.midX)
        #expect(g.notch.maxY == s.frame.maxY)
    }

    @Test func autoHiddenMenuBarFallsBackToDefaultHeight() {
        let s = ScreenDescriptor(
            displayID: 3,
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil,
            backingScale: 1, isPrimary: true
        )
        let g = NotchGeometry.compute(s)
        #expect(g.menuBarAutoHidden)
        #expect(g.bandHeight == 24)
    }

    @Test func collapsedCanvasMatchesMeasuredBounds() {
        let g = NotchGeometry.compute(Self.mbp14)
        let l = IslandLayoutEngine.layout(mode: .collapsed, geometry: g, metrics: .regular)
        let cg = ScreenCoordinates.toCG(l.canvas, primaryHeight: 982)
        #expect(cg == CGRect(x: 585, y: 0, width: 341, height: 32))
        let compact = IslandLayoutEngine.layout(mode: .collapsed, geometry: g, metrics: .compact)
        #expect(ScreenCoordinates.toCG(compact.canvas, primaryHeight: 982) == CGRect(x: 597, y: 0, width: 317, height: 32))
    }

    @Test func expandedIsCenteredOnTheNotchAndTopAnchored() {
        let g = NotchGeometry.compute(Self.mbp14)
        let content = ExpandedContentMetrics(usageRows: 2, sessionRows: 3, hasMoreRow: false)
        let l = IslandLayoutEngine.layout(mode: .expanded, geometry: g, metrics: .regular, content: content)
        #expect(l.canvas.midX == g.notch.midX)
        #expect(l.canvas.maxY == g.screenFrame.maxY)
        #expect(l.bodySize.width == 560)
        #expect(l.hoverRect.maxY == g.screenFrame.maxY)
    }
}
