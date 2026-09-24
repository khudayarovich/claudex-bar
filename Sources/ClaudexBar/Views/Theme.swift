import AppKit
import ClaudexCore
import SwiftUI

enum Theme {
    static let red = NSColor(srgbRed: 1.0, green: 0x45 / 255, blue: 0x3A / 255, alpha: 1)
    static let yellow = NSColor(srgbRed: 1.0, green: 0xD6 / 255, blue: 0x0A / 255, alpha: 1)
    static let green = NSColor(srgbRed: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255, alpha: 1)
    static let orange = NSColor(srgbRed: 1.0, green: 0x9F / 255, blue: 0x0A / 255, alpha: 1)
    static let claudeAccent = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
    static let codexAccent = Color(white: 0.92)

    static let primaryText = Color.white.opacity(0.94)
    static let secondaryText = Color.white.opacity(0.58)
    static let tertiaryText = Color.white.opacity(0.38)
    static let track = Color.white.opacity(0.12)
    static let rowHover = Color.white.opacity(0.07)
    static let separator = Color.white.opacity(0.08)

    static func lamp(_ c: LampColor) -> NSColor {
        switch c {
        case .red: return red
        case .yellow: return yellow
        case .green: return green
        }
    }

    static func usage(_ level: UsageLevel) -> Color {
        switch level {
        case .normal: return Color(nsColor: green)
        case .elevated: return Color(nsColor: yellow)
        case .high: return Color(nsColor: orange)
        case .critical: return Color(nsColor: red)
        }
    }

    static func accent(_ p: Provider) -> Color { p == .claude ? claudeAccent : codexAccent }
}

/// Environment switches used by snapshot rendering and accessibility testing.
private struct LampRendererKey: EnvironmentKey {
    static let defaultValue = LampRenderer.coreAnimation
}

private struct ForceReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

enum LampRenderer { case coreAnimation, staticSwiftUI }

extension EnvironmentValues {
    var lampRenderer: LampRenderer {
        get { self[LampRendererKey.self] }
        set { self[LampRendererKey.self] = newValue }
    }

    var forceReduceMotion: Bool {
        get { self[ForceReduceMotionKey.self] }
        set { self[ForceReduceMotionKey.self] = newValue }
    }
}
