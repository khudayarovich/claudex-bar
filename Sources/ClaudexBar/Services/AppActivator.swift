import AppKit
import ClaudexCore

/// Brings the app that owns a session to the front: the desktop app by bundle id, or the
/// terminal/editor found by walking the agent's process ancestry.
enum AppActivator {
    static func activate(_ session: AgentSession?) {
        guard let session else { return }
        if let bundleID = session.appBundleID,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            bringForward(app)
            return
        }
        if let pid = session.pid, pid > 0 {
            for p in ProcessAncestry.chain(pid, inspector: LibprocInspector()) {
                if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular {
                    bringForward(app)
                    return
                }
            }
        }
        if let bundleID = session.appBundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Activation from a non-activating panel is a cooperative request on macOS 14+; fall
    /// back to a Launch Services "open", which always brings the app forward.
    private static func bringForward(_ app: NSRunningApplication) {
        app.activate(options: [.activateAllWindows])
        let url = app.bundleURL
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier, let url else { return }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
    }
}
