import AppKit
import ClaudexCore
import SwiftUI

/// Owns one island panel on one screen: window frame, hover intent, transitions, peeks.
final class IslandWindowController {
    let panel = IslandPanel()
    let model: IslandModel
    let vm: IslandViewModel
    var menuProvider: (() -> NSMenu?)? {
        didSet { container.hosting.menuProvider = menuProvider }
    }
    /// Called when the island expands (engine refreshes stale data).
    var onExpand: (() -> Void)?
    var peekSound: (PeekEvent) -> Void = { _ in }

    private var container: IslandContainerView!
    private var peekQueue = PeekQueue()
    private var peekTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    private var hovering = false
    private var suppressHoverUntilExit = false
    private var transitionID = 0
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    private var isHiddenForFullScreen = false

    init(geometry: NotchGeometry, metrics: IslandMetrics, vm: IslandViewModel, actions: IslandActions) {
        model = IslandModel(geometry: geometry, metrics: metrics)
        self.vm = vm
        var routed = actions
        let userTogglePin = actions.togglePin
        routed.togglePin = { [weak self] in
            if let self { self.togglePin() } else { userTogglePin() }
        }
        routed.collapse = { [weak self] in self?.collapse() }
        let activate = actions.activateSession
        routed.activateSession = { [weak self] id in
            activate(id)
            self?.collapse(suppressHover: true)
        }
        container = IslandContainerView(rootView: IslandRootView(model: model, vm: vm, actions: routed))
        container.sensor.onHoverChange = { [weak self] inside in self?.hoverChanged(inside) }
        panel.contentView = container
    }

    // MARK: - Showing

    func show() {
        setCanvas(model.layout.canvas, hover: model.layout.hoverRect)
        panel.orderFrontRegardless()
    }

    func close() {
        removeOutsideMonitor()
        peekTask?.cancel()
        hoverTask?.cancel()
        panel.orderOut(nil)
        panel.close()
    }

    func setHiddenForFullScreen(_ hidden: Bool) {
        guard hidden != isHiddenForFullScreen else { return }
        isHiddenForFullScreen = hidden
        if hidden {
            collapse()
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func update(geometry: NotchGeometry, metrics: IslandMetrics) {
        guard geometry != model.geometry || metrics != model.metrics else { return }
        model.geometry = geometry
        model.metrics = metrics
        peekQueue.clear()
        removeOutsideMonitor()
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            model.mode = .collapsed
            model.pinned = false
            model.peek = nil
            model.layout = layout(for: .collapsed)
        }
        setCanvas(model.layout.canvas, hover: model.layout.hoverRect)
        if !isHiddenForFullScreen { panel.orderFrontRegardless() }
    }

    // MARK: - Transitions

    private func layout(for mode: IslandMode) -> IslandLayout {
        IslandLayoutEngine.layout(
            mode: mode, geometry: model.geometry, metrics: model.metrics,
            peekTextWidth: model.peek.map(PeekLineView.textWidth) ?? 0,
            content: vm.contentMetrics
        )
    }

    private func animation(to mode: IslandMode) -> Animation {
        if model.forceReduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            return .easeInOut(duration: 0.2)
        }
        switch mode {
        case .expanded: return .spring(response: 0.42, dampingFraction: 0.74)
        case .peek: return .spring(response: 0.36, dampingFraction: 0.72)
        case .collapsed: return .spring(response: 0.32, dampingFraction: 0.9)
        }
    }

    func present(_ mode: IslandMode, pinned: Bool = false) {
        let target = layout(for: mode)
        transitionID &+= 1
        let id = transitionID
        // 1. Grow the window first (extra area is transparent) so the animation is never clipped.
        setCanvas(model.layout.canvas.union(target.canvas), hover: target.hoverRect)
        // 2. Morph the island.
        withAnimation(animation(to: mode), completionCriteria: .logicallyComplete) {
            model.mode = mode
            model.pinned = pinned
            model.layout = target
        } completion: { [weak self] in
            // 3. Shrink the window once the animation settled (unless superseded).
            guard let self, self.transitionID == id else { return }
            self.setCanvas(target.canvas, hover: target.hoverRect)
            StdoutLog.line("STATE \(mode.rawValue) settled")
        }
        if mode == .expanded {
            peekQueue.clear()
            peekTask?.cancel()
            model.peek = nil
            onExpand?()
        }
        if pinned { installOutsideMonitor() } else { removeOutsideMonitor() }
    }

    func togglePin() {
        if model.mode == .expanded && model.pinned {
            collapse(suppressHover: true)
        } else {
            present(.expanded, pinned: true)
        }
    }

    func collapse(suppressHover: Bool = false) {
        if suppressHover { suppressHoverUntilExit = true }
        guard model.mode != .collapsed else { return }
        model.peek = nil
        peekQueue.clear()
        peekTask?.cancel()
        present(.collapsed)
    }

    /// Content (rows / usage) changed: keep the expanded or peek frame in sync.
    func contentChanged() {
        guard model.mode == .expanded else { return }
        let target = layout(for: .expanded)
        guard target != model.layout else { return }
        present(.expanded, pinned: model.pinned)
    }

    // MARK: - Canvas

    private func setCanvas(_ canvas: CGRect, hover: CGRect) {
        let aligned = panel.backingAlignedRect(canvas, options: .alignAllEdgesNearest)
        let offset = model.geometry.notch.midX - aligned.midX
        if abs(offset - model.contentOffsetX) > 0.01 {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { model.contentOffsetX = offset }
        }
        if aligned != panel.frame { panel.setFrame(aligned, display: true) }
        container.sensor.hoverRect = CGRect(
            x: hover.minX - aligned.minX, y: aligned.maxY - hover.maxY, width: hover.width, height: hover.height
        )
    }

    // MARK: - Hover

    private func hoverChanged(_ inside: Bool) {
        guard inside != hovering else { return }
        hovering = inside
        hoverTask?.cancel()
        if inside {
            guard !suppressHoverUntilExit else { return }
            switch model.mode {
            case .collapsed:
                hoverTask = delayed(.milliseconds(150)) { [weak self] in
                    guard let self, self.container.sensor.isPointerInside, self.model.mode == .collapsed else { return }
                    self.present(.expanded)
                }
            case .peek:
                peekQueue.hold(now: Date())
                peekTask?.cancel()
                hoverTask = delayed(.milliseconds(600)) { [weak self] in
                    guard let self, self.container.sensor.isPointerInside, self.model.mode == .peek else { return }
                    self.present(.expanded)
                }
            case .expanded:
                break
            }
        } else {
            suppressHoverUntilExit = false
            switch model.mode {
            case .expanded where !model.pinned:
                hoverTask = delayed(.milliseconds(350)) { [weak self] in
                    guard let self, !self.container.sensor.isPointerInside, self.model.mode == .expanded,
                          !self.model.pinned else { return }
                    self.present(.collapsed)
                }
            case .peek:
                peekQueue.release(now: Date())
                schedulePeekTimer()
            default:
                break
            }
        }
    }

    private func delayed(_ d: Duration, _ body: @escaping () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(for: d)
            guard !Task.isCancelled else { return }
            body()
        }
    }

    // MARK: - Peeks

    func enqueue(_ events: [PeekEvent]) {
        guard !isHiddenForFullScreen, model.mode != .expanded else { return }
        for e in events { handle(peekQueue.enqueue(e, now: Date())) }
    }

    private func handle(_ effect: PeekQueue.Effect) {
        switch effect {
        case .none:
            break
        case let .show(event):
            let isNew = model.peek?.id != event.id
            if model.mode == .peek {
                withAnimation(.snappy(duration: 0.25)) { model.peek = event }
                present(.peek)
            } else {
                model.peek = event
                present(.peek)
            }
            if isNew { peekSound(event) }
            schedulePeekTimer()
        case .hide:
            model.peek = nil
            if model.mode == .peek { present(.collapsed) }
        }
    }

    private func schedulePeekTimer() {
        peekTask?.cancel()
        guard let deadline = peekQueue.deadline else { return }
        let delay = max(0.05, deadline.timeIntervalSinceNow)
        peekTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.handle(self.peekQueue.expire(now: Date()))
        }
    }

    // MARK: - Outside clicks (pinned)

    private func installOutsideMonitor() {
        guard outsideMonitor == nil else { return }
        // Clicks in other apps…
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.container.sensor.isPointerInside else { return }
                self.collapse()
            }
        }
        // …and clicks in our own window's transparent/shadow margin around the island.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window === self.panel, !self.container.sensor.isPointerInside {
                    self.collapse()
                }
            }
            return event
        }
    }

    private func removeOutsideMonitor() {
        if let m = outsideMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        outsideMonitor = nil
        localMonitor = nil
    }

    // MARK: - Diagnostics

    func readyInfo() -> [String: Any] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return [
            "kind": model.geometry.kind.rawValue,
            "notch": StdoutLog.rect(model.geometry.notch),
            "notchMidX": Double(model.geometry.notch.midX),
            "canvas": StdoutLog.rect(panel.frame),
            "canvasCG": StdoutLog.rect(ScreenCoordinates.toCG(panel.frame, primaryHeight: primaryHeight)),
            "windowNumber": panel.windowNumber,
            "level": panel.level.rawValue,
            "displayID": Int(model.geometry.displayID),
            "mode": model.mode.rawValue,
        ]
    }
}
