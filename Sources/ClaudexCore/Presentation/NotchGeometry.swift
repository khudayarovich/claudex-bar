import CoreGraphics
import Foundation

/// A plain, Sendable description of an `NSScreen`, captured on the main actor so the
/// geometry math can stay pure and unit-testable.
public struct ScreenDescriptor: Sendable, Equatable {
    public var displayID: UInt32
    /// AppKit global coordinates (origin at the bottom-left of the primary display).
    public var frame: CGRect
    public var visibleFrame: CGRect
    public var safeAreaTop: CGFloat
    public var auxiliaryTopLeft: CGRect?
    public var auxiliaryTopRight: CGRect?
    public var backingScale: CGFloat
    public var isPrimary: Bool

    public init(
        displayID: UInt32, frame: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat,
        auxiliaryTopLeft: CGRect?, auxiliaryTopRight: CGRect?, backingScale: CGFloat, isPrimary: Bool
    ) {
        self.displayID = displayID
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeft = auxiliaryTopLeft
        self.auxiliaryTopRight = auxiliaryTopRight
        self.backingScale = backingScale
        self.isPrimary = isPrimary
    }
}

/// Where the (hardware or virtual) notch sits on a screen.
public struct NotchGeometry: Sendable, Equatable {
    public enum Kind: String, Sendable { case hardware, virtual }

    public var kind: Kind
    /// Notch rect in AppKit global coordinates; `notch.maxY == screenFrame.maxY`.
    public var notch: CGRect
    /// Height of the collapsed island band (the notch height on notched displays).
    public var bandHeight: CGFloat
    public var screenFrame: CGRect
    public var menuBarAutoHidden: Bool
    /// Upper bound for one ear so the island never runs off the menu bar.
    public var maxEarWidth: CGFloat
    public var backingScale: CGFloat
    public var displayID: UInt32

    public init(
        kind: Kind, notch: CGRect, bandHeight: CGFloat, screenFrame: CGRect,
        menuBarAutoHidden: Bool, maxEarWidth: CGFloat, backingScale: CGFloat, displayID: UInt32
    ) {
        self.kind = kind
        self.notch = notch
        self.bandHeight = bandHeight
        self.screenFrame = screenFrame
        self.menuBarAutoHidden = menuBarAutoHidden
        self.maxEarWidth = maxEarWidth
        self.backingScale = backingScale
        self.displayID = displayID
    }

    /// Computes the notch from `auxiliaryTopLeftArea`/`auxiliaryTopRightArea`. The notch
    /// center is derived from those areas, never from the screen's midX (on a 14" MacBook
    /// Pro it is 755.5, not 756). Falls back to a virtual pill at top-center.
    public static func compute(_ s: ScreenDescriptor, virtualWidth: CGFloat = 150) -> NotchGeometry {
        let f = s.frame
        let reserved = f.maxY - s.visibleFrame.maxY
        if s.safeAreaTop > 0, let l = s.auxiliaryTopLeft, let r = s.auxiliaryTopRight,
           !l.isEmpty, !r.isEmpty, (80...400).contains(r.minX - l.maxX) {
            let h = s.safeAreaTop
            return NotchGeometry(
                kind: .hardware,
                notch: CGRect(x: l.maxX, y: f.maxY - h, width: r.minX - l.maxX, height: h),
                bandHeight: h,
                screenFrame: f,
                menuBarAutoHidden: reserved < 1,
                maxEarWidth: max(40, min(l.width, r.width) - 40),
                backingScale: s.backingScale,
                displayID: s.displayID
            )
        }
        let h: CGFloat = reserved >= 20 ? min(reserved, 40) : 24
        return NotchGeometry(
            kind: .virtual,
            notch: CGRect(x: (f.midX - virtualWidth / 2).rounded(), y: f.maxY - h, width: virtualWidth, height: h),
            bandHeight: h,
            screenFrame: f,
            menuBarAutoHidden: reserved < 1,
            maxEarWidth: max(40, (f.width - virtualWidth) / 2 - 40),
            backingScale: s.backingScale,
            displayID: s.displayID
        )
    }
}

public enum ScreenCoordinates {
    /// Converts an AppKit global rect (bottom-left origin) into CoreGraphics global
    /// coordinates (top-left origin of the primary display), as used by CGWindowList.
    public static func toCG(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}
