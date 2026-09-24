import AppKit
import ClaudexCore
import ServiceManagement
import SwiftUI

enum LaunchAtLogin {
    static var isInstalledLocation: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("ClaudexBar: launch at login change failed: \(error.localizedDescription)")
        }
    }
}

final class SettingsWindowController {
    private var window: NSWindow?
    private let prefs: Preferences

    init(prefs: Preferences) { self.prefs = prefs }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(prefs: prefs))
            host.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: host)
            w.title = "ClaudexBar Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.tabbingMode = .disallowed
            w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @Bindable var prefs: Preferences
    @State private var loginEnabled = LaunchAtLogin.status == .enabled

    var body: some View {
        TabView {
            Form {
                Section("Startup") {
                    Toggle("Launch at login", isOn: $loginEnabled)
                        .disabled(!LaunchAtLogin.isInstalledLocation)
                        .onChange(of: loginEnabled) { _, on in
                            LaunchAtLogin.set(on)
                            loginEnabled = LaunchAtLogin.status == .enabled
                        }
                    if !LaunchAtLogin.isInstalledLocation {
                        Text("Install ClaudexBar in Applications (make install) to enable this.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if LaunchAtLogin.status == .requiresApproval {
                        Button("Approve in System Settings…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                Section("Traffic lights") {
                    Stepper("Finished turns stay bright for \(prefs.freshMinutes) min",
                            value: $prefs.freshMinutes, in: 5...240, step: 5)
                    Text("🟢 working · 🟡 finished, waiting for you · 🔴 needs approval or blocked")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section("Where") {
                    Picker("Show the island on", selection: $prefs.displayChoice) {
                        ForEach(Preferences.DisplayChoice.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Hide over full-screen apps", isOn: $prefs.hideInFullScreen)
                }
                Section("Look") {
                    Picker("Ear width", selection: $prefs.earSize) {
                        Text("Regular").tag(Preferences.EarSize.regular)
                        Text("Compact").tag(Preferences.EarSize.compact)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Show usage ring around each logo", isOn: $prefs.showUsageRing)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Display", systemImage: "rectangle.topthird.inset.filled") }

            Form {
                Section("Pop out the island when") {
                    Toggle("A session needs approval or an answer", isOn: $prefs.peekAttention)
                    Toggle("A turn longer than 20 s finishes", isOn: $prefs.peekFinished)
                    Toggle("Usage crosses 80 % or 100 %", isOn: $prefs.peekUsage)
                    Toggle("Play a sound when a session needs you", isOn: $prefs.sound)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Alerts", systemImage: "bell") }

            Form {
                Section("Usage limits") {
                    Toggle("Claude: ask Anthropic's usage API with Claude Code's login", isOn: $prefs.claudeUsageAPI)
                    Text("Otherwise uses the numbers the Claude app already saved. Tokens are only read, never refreshed or stored.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Codex: ask ChatGPT's usage API with Codex's login", isOn: $prefs.codexUsageAPI)
                    Text("Otherwise uses the limits Codex writes to its session logs.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Sources (read-only)") {
                    LabeledContent("Claude sessions", value: "~/.claude/sessions, ~/.claude/projects")
                    LabeledContent("Codex sessions", value: "~/.codex/sessions, state_*.sqlite")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Data", systemImage: "chart.bar") }

            VStack(spacing: 10) {
                HStack(spacing: 14) {
                    ProviderGlyph(provider: .claude, size: 28)
                    ProviderGlyph(provider: .codex, size: 28)
                }
                Text("ClaudexBar").font(.title2.weight(.semibold))
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                    .foregroundStyle(.secondary)
                Text("Live status and usage limits for Claude Code and Codex, around your notch.")
                    .font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 500, height: 380)
    }
}
