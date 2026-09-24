import AppKit
import ClaudexCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: LaunchOptions
    private let prefs = Preferences()
    private let vm = IslandViewModel()
    private var feed: StatusFeed?
    private var engine: ClaudexEngine?
    private var demo: DemoDriver?
    private var coordinator: ScreenCoordinator?
    private var settings: SettingsWindowController?
    private var tasks: [Task<Void, Never>] = []
    private var observers: [NSObjectProtocol] = []

    init(options: LaunchOptions) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let dir = options.snapshotDir {
            SnapshotRenderer.run(to: dir)
            NSApp.terminate(nil)
            return
        }
        guard ensureSingleInstance() else {
            NSApp.terminate(nil)
            return
        }
        NSApp.disableRelaunchOnLogin()
        installMainMenu()

        vm.policy = LampPolicy(freshWindow: TimeInterval(prefs.freshMinutes * 60))
        let actions = IslandActions(
            activateSession: { [weak self] id in AppActivator.activate(self?.vm.session(id: id)) },
            openSettings: { [weak self] in self?.openSettings() },
            refresh: { [weak self] in self?.refreshNow() },
            quit: { NSApp.terminate(nil) }
        )
        let coordinator = ScreenCoordinator(prefs: prefs, vm: vm, actions: actions, options: options)
        coordinator.menuProvider = { [weak self] in self?.makeContextMenu() }
        coordinator.onExpand = { [weak self] in
            guard let feed = self?.feed else { return }
            Task { await feed.panelDidExpand() }
        }
        coordinator.peekSound = { [weak self] event in
            guard let self, self.prefs.sound, event.kind == .attention else { return }
            NSSound(named: "Glass")?.play()
        }
        self.coordinator = coordinator
        vm.onPeek = { [weak self] events in
            guard let self else { return }
            self.coordinator?.enqueue(events.filter(self.prefs.allows))
        }

        if options.demo {
            let d = DemoDriver(speed: options.demoSpeed, freeze: options.demoFreeze)
            demo = d
            feed = d
        } else {
            var config = EngineConfiguration()
            config.claudeUsageAPI = prefs.claudeUsageAPI
            config.codexUsageAPI = prefs.codexUsageAPI
            let e = ClaudexEngine(configuration: config)
            engine = e
            feed = e
        }

        coordinator.start()
        startFeed()
        observePreferences()
        observeWake()
        if options.debugCommands { DebugCommandCenter.install(self) }
        if let present = options.present { apply(present: present) }

        // Time-dependent display (fresh → parked yellow, countdowns).
        tasks.append(Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30), tolerance: .seconds(5))
                self?.vm.tick()
            }
        })
        if let primary = coordinator.primary { StdoutLog.json("READY", primary.readyInfo()) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        tasks.forEach { $0.cancel() }
        coordinator?.stop()
        if let feed { Task { await feed.stop() } }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    // MARK: - Feed

    private func startFeed() {
        guard let feed else { return }
        tasks.append(Task { @MainActor [weak self] in
            for await snapshot in feed.sessionSnapshots {
                self?.vm.apply(sessions: snapshot)
                self?.coordinator?.contentChanged()
            }
        })
        tasks.append(Task { @MainActor [weak self] in
            for await usage in feed.usageSnapshots {
                self?.vm.apply(usage: usage)
                self?.coordinator?.contentChanged()
            }
        })
        Task { await feed.start() }
    }

    func refreshNow() {
        guard let feed else { return }
        Task { await feed.refreshNow() }
    }

    private func observePreferences() {
        let changes = prefs.changes
        tasks.append(Task { @MainActor [weak self] in
            for await _ in changes {
                guard let self else { return }
                self.vm.policy = LampPolicy(freshWindow: TimeInterval(self.prefs.freshMinutes * 60))
                self.vm.tick()
                self.coordinator?.applyPreferences()
                if let engine = self.engine {
                    let (c, x) = (self.prefs.claudeUsageAPI, self.prefs.codexUsageAPI)
                    Task { await engine.setUsageAPIs(claude: c, codex: x) }
                }
            }
        })
    }

    private func observeWake() {
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let feed = self?.feed else { return }
                Task { await feed.systemDidWake() }
            }
        })
    }

    // MARK: - UI

    func openSettings() {
        if settings == nil { settings = SettingsWindowController(prefs: prefs) }
        settings?.show()
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let pinned = coordinator?.primary?.model.pinned ?? false
        menu.addItem(item(pinned ? "Unpin Island" : "Pin Island Open", #selector(togglePinned), ""))
        menu.addItem(item("Refresh Now", #selector(refreshAction), "r"))
        menu.addItem(item("Settings…", #selector(settingsAction), ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit ClaudexBar", #selector(quitAction), "q"))
        return menu
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func togglePinned() { coordinator?.controllers.values.forEach { $0.togglePin() } }
    @objc private func refreshAction() { refreshNow() }
    @objc private func settingsAction() { openSettings() }
    @objc private func quitAction() { NSApp.terminate(nil) }

    /// A hidden main menu so ⌘C / ⌘V / ⌘A / ⌘W work in the Settings window.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(settingsAction), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Quit ClaudexBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    private func ensureSingleInstance() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return true }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !others.isEmpty else { return true }
        if options.replace {
            others.forEach { $0.terminate() }
            return true
        }
        return false
    }

    // MARK: - Debug

    func apply(present: String) {
        let parts = present.split(separator: " ").map(String.init)
        switch parts.first {
        case "expanded": coordinator?.controllers.values.forEach { $0.present(.expanded, pinned: true) }
        case "collapsed": coordinator?.controllers.values.forEach { $0.collapse() }
        case "peek":
            let e = PeekEvent(key: "debug", kind: .attention, provider: .claude, lamp: .red,
                              title: "Claude · claudex-bar", detail: "needs approval — Bash", sessionID: nil, createdAt: Date())
            coordinator?.enqueue([e])
        case "scenario":
            if let name = parts.dropFirst().first, let demo { Task { await demo.freeze(name) } }
        case "geometry":
            if let p = coordinator?.primary { StdoutLog.json("GEOMETRY", p.readyInfo()) }
        case "dump":
            dumpState()
        default:
            break
        }
    }
}

extension AppDelegate {
    /// Prints what the island currently shows (statuses and numbers only, no secrets).
    func dumpState() {
        func lamps(_ t: LampTriple) -> String { "R:\(t.red) Y:\(t.yellow) G:\(t.green)" }
        for s in [vm.claude, vm.codex] {
            let usage = s.usage.map { "\($0.label)=\($0.percentText)\($0.resetText.map { " " + $0 } ?? "")" }.joined(separator: ", ")
            StdoutLog.line("DUMP \(s.provider.displayName) [\(lamps(s.lamps))] ring=\(s.ring.map { String(format: "%.2f", $0) } ?? "-") plan=\(s.plan ?? "-") usage=[\(usage)] note=\(s.usageNote ?? "-")")
        }
        for r in vm.rows {
            StdoutLog.line("DUMP row \(r.provider.displayName) [\(lamps(r.lamps))] \(r.title) — \(r.activity) (\(r.badge))")
        }
        if let p = coordinator?.primary { StdoutLog.json("DUMP geometry", p.readyInfo()) }
    }
}

/// `--debug-commands`: accepts commands posted as distributed notifications, e.g.
/// `present expanded`, `present collapsed`, `present peek`, `present scenario mixed`, `present geometry`.
enum DebugCommandCenter {
    static let name = Notification.Name("dev.claudexbar.debug")

    static func install(_ delegate: AppDelegate) {
        DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { [weak delegate] note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated {
                StdoutLog.line("COMMAND \(command)")
                let body = command.hasPrefix("present ") ? String(command.dropFirst("present ".count)) : command
                delegate?.apply(present: body)
            }
        }
    }
}
