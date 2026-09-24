import Foundation

/// Command-line flags. Most exist for verification and demos.
struct LaunchOptions {
    var demo = false
    var demoFreeze: String?
    var demoSpeed: Double = 1
    var present: String?
    var snapshotDir: String?
    var simulateNoNotch = false
    var forceReduceMotion = false
    var debugCommands = false
    var replace = false
    var logGeometry = false

    init(arguments: [String]) {
        var it = arguments.dropFirst().makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--demo": demo = true
            case "--demo-freeze": demo = true; demoFreeze = it.next()
            case "--demo-speed": demoSpeed = it.next().flatMap(Double.init) ?? 1
            case "--present": present = it.next()
            case "--snapshot": snapshotDir = it.next()
            case "--simulate-no-notch": simulateNoNotch = true
            case "--force-reduce-motion": forceReduceMotion = true
            case "--debug-commands": debugCommands = true
            case "--replace": replace = true
            case "--log-geometry": logGeometry = true
            default: break   // ignore unknown flags (e.g. -NSDocumentRevisionsDebugMode)
            }
        }
    }
}
