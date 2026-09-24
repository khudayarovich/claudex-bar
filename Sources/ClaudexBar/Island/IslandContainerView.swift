import AppKit
import SwiftUI

/// Hosts the SwiftUI island. `acceptsFirstMouse` makes buttons work on the first click even
/// though the panel is never key; `menu(for:)` provides the right-click menu.
final class IslandHostingView: NSHostingView<IslandRootView> {
    var menuProvider: (() -> NSMenu?)?

    required init(rootView: IslandRootView) {
        super.init(rootView: rootView)
        sizingOptions = []
        safeAreaRegions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}

/// Transparent overlay that owns the single hover tracking area. It never takes clicks
/// (`hitTest` returns nil), so events fall through to the hosting view underneath.
final class HoverSensorView: NSView {
    override var isFlipped: Bool { true }

    /// Hover region in this view's (flipped) coordinates.
    var hoverRect: CGRect = .zero {
        didSet { if hoverRect != oldValue { updateTrackingAreas() } }
    }
    var onHoverChange: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        area = nil
        guard !hoverRect.isEmpty else { return }
        let a = NSTrackingArea(rect: hoverRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(a)
        area = a
        // A freshly added area does not report a pointer that is already inside it.
        onHoverChange?(isPointerInside)
    }

    var isPointerInside: Bool {
        guard let window else { return false }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return hoverRect.contains(convert(inWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}

/// Root content view of the panel: hosting view below, hover sensor on top.
final class IslandContainerView: NSView {
    let hosting: IslandHostingView
    let sensor = HoverSensorView()

    init(rootView: IslandRootView) {
        hosting = IslandHostingView(rootView: rootView)
        super.init(frame: .zero)
        wantsLayer = true
        hosting.autoresizingMask = [.width, .height]
        sensor.autoresizingMask = [.width, .height]
        addSubview(hosting)
        addSubview(sensor)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        hosting.frame = bounds
        sensor.frame = bounds
    }
}
