import AppKit
import ClaudexCore
import CoreGraphics

/// Chooses screens, owns one island per chosen screen, and reacts to display, Space and
/// full-screen changes.
final class ScreenCoordinator {
    private(set) var controllers: [UInt32: IslandWindowController] = [:]
    private let prefs: Preferences
    private let vm: IslandViewModel
    private let actions: IslandActions
    private let options: LaunchOptions
    var menuProvider: (() -> NSMenu?)?
    var onExpand: (() -> Void)?
    var peekSound: (PeekEvent) -> Void = { _ in }
    private var observers: [NSObjectProtocol] = []
    private var rebuildTask: Task<Void, Never>?
    private var fullScreenTask: Task<Void, Never>?

    init(prefs: Preferences, vm: IslandViewModel, actions: IslandActions, options: LaunchOptions) {
        self.prefs = prefs
        self.vm = vm
        self.actions = actions
        self.options = options
    }

    func start() {
        rebuild()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                        queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRebuild() }
        })
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRebuild() }
            })
        }
        observers.append(ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil,
                                        queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.controllers.values.forEach { $0.collapse() }
                self?.scheduleFullScreenCheck()
            }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                        queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleFullScreenCheck() }
        })
    }

    func stop() {
        observers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        observers.removeAll()
        controllers.values.forEach { $0.close() }
        controllers.removeAll()
    }

    func enqueue(_ events: [PeekEvent]) {
        controllers.values.forEach { $0.enqueue(events) }
    }

    func contentChanged() {
        controllers.values.forEach { $0.contentChanged() }
    }

    func applyPreferences() {
        for c in controllers.values {
            c.model.showUsageRing = prefs.showUsageRing
        }
        rebuild()
        scheduleFullScreenCheck()
    }

    var primary: IslandWindowController? {
        controllers.values.min { $0.model.geometry.displayID < $1.model.geometry.displayID }
    }

    // MARK: - Screens

    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.rebuild()
        }
    }

    private func chosenScreens() -> [NSScreen] {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return [] }
        switch prefs.displayChoice {
        case .notched:
            if options.simulateNoNotch { return [screens[0]] }
            return [screens.first { $0.safeAreaInsets.top > 0 } ?? screens[0]]
        case .main:
            return [screens[0]]
        case .all:
            return NSScreen.screensHaveSeparateSpaces ? screens : [screens[0]]
        }
    }

    func rebuild() {
        let screens = chosenScreens()
        guard !screens.isEmpty else { return }
        var keep = Set<UInt32>()
        for screen in screens {
            let geometry = NotchGeometry.compute(ScreenDescriptor(screen, simulateNoNotch: options.simulateNoNotch))
            let metrics = prefs.earSize.metrics
            keep.insert(geometry.displayID)
            if let existing = controllers[geometry.displayID] {
                existing.update(geometry: geometry, metrics: metrics)
                existing.model.showUsageRing = prefs.showUsageRing
            } else {
                let c = IslandWindowController(geometry: geometry, metrics: metrics, vm: vm, actions: actions)
                c.model.showUsageRing = prefs.showUsageRing
                c.model.forceReduceMotion = options.forceReduceMotion
                c.menuProvider = menuProvider
                c.onExpand = { [weak self] in self?.onExpand?() }
                c.peekSound = { [weak self] e in self?.peekSound(e) }
                c.show()
                controllers[geometry.displayID] = c
            }
        }
        for (id, c) in controllers where !keep.contains(id) {
            c.close()
            controllers[id] = nil
        }
    }

    // MARK: - Full screen

    private func scheduleFullScreenCheck() {
        fullScreenTask?.cancel()
        guard prefs.hideInFullScreen else {
            controllers.values.forEach { $0.setHiddenForFullScreen(false) }
            return
        }
        fullScreenTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            for c in self.controllers.values {
                c.setHiddenForFullScreen(FullScreenDetector.isFullScreen(on: c.model.geometry))
            }
        }
    }
}

enum FullScreenDetector {
    /// True when the menu bar isn't shown on that display and the frontmost app has a
    /// window covering it. Uses window bounds/layers only (no Screen Recording needed).
    static func isFullScreen(on g: NotchGeometry) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let screenCG = ScreenCoordinates.toCG(g.screenFrame, primaryHeight: primaryHeight)
        func bounds(_ w: [String: Any]) -> CGRect {
            guard let b = w[kCGWindowBounds as String] as? NSDictionary else { return .zero }
            return CGRect(dictionaryRepresentation: b as CFDictionary) ?? .zero
        }
        let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        let menuBarShown = list.contains {
            ($0[kCGWindowLayer as String] as? Int) == menuLevel && bounds($0).intersects(screenCG)
                && abs(bounds($0).minY - screenCG.minY) < 1
        }
        let covered = list.contains {
            ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowOwnerPID as String] as? pid_t) == front
                && bounds($0).width >= screenCG.width - 1 && bounds($0).height >= screenCG.height - g.bandHeight - 1
        }
        return !menuBarShown && covered
    }
}
