import AppKit

/// Borderless, non-activating panel that sits just above the menu bar (level 27) on every
/// Space, including over full-screen apps. It never becomes key, so clicking the island
/// never steals keyboard focus from the user's terminal or editor.
final class IslandPanel: NSPanel {
    static let islandLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true            // resets `level`, so set the level afterwards
        level = Self.islandLevel
        collectionBehavior = [
            .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle, .canJoinAllApplications,
        ]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false                 // SwiftUI draws the shadow of the morphing shape
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        worksWhenModal = true
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Allow frames above `visibleFrame` (i.e. over the menu bar).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
