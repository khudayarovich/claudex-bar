import AppKit
import ClaudexCore

extension NSScreen {
    var displayID: UInt32 {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

extension ScreenDescriptor {
    init(_ screen: NSScreen, simulateNoNotch: Bool = false) {
        self.init(
            displayID: screen.displayID,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: simulateNoNotch ? 0 : screen.safeAreaInsets.top,
            auxiliaryTopLeft: simulateNoNotch ? nil : screen.auxiliaryTopLeftArea,
            auxiliaryTopRight: simulateNoNotch ? nil : screen.auxiliaryTopRightArea,
            backingScale: screen.backingScaleFactor,
            isPrimary: screen == NSScreen.screens.first
        )
    }
}

enum StdoutLog {
    /// Machine-readable lines (`READY …`, `STATE …`) used by verification scripts.
    static func line(_ s: String) {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }

    static func json(_ tag: String, _ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        line("\(tag) \(text)")
    }

    static func rect(_ r: CGRect) -> [Double] {
        [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)]
    }
}
