import AppKit

@main
enum ClaudexBarMain {
    static func main() {
        let options = LaunchOptions(arguments: CommandLine.arguments)
        let app = NSApplication.shared
        let delegate = AppDelegate(options: options)
        app.delegate = delegate   // NSApplication.delegate is weak; keep `delegate` alive below.
        app.setActivationPolicy(options.snapshotDir == nil ? .accessory : .prohibited)
        withExtendedLifetime(delegate) { app.run() }
    }
}
