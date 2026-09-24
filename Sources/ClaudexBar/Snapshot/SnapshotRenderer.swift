import AppKit
import ClaudexCore
import SwiftUI

/// Renders every island state to PNG files offscreen (no Screen Recording permission
/// needed). Lamps use the static SwiftUI renderer; the real Core Animation lamps are
/// rendered separately through `CALayer.render(in:)`.
enum SnapshotRenderer {
    struct Case {
        var name: String
        var scenario: String
        var mode: IslandMode
        var metrics: IslandMetrics = .regular
        var virtualNotch = false
        var peek: PeekEvent?
    }

    static func run(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let now = Date()
        let peekApproval = PeekEvent(key: "a", kind: .attention, provider: .claude, lamp: .red, title: "Claude · api-server",
                                     detail: "needs approval — Bash", sessionID: nil, createdAt: now)
        let peekDone = PeekEvent(key: "d", kind: .finished, provider: .codex, lamp: .yellow, title: "Done · report-agent",
                                 detail: "Codex", sessionID: nil, createdAt: now)
        let peekUsage = PeekEvent(key: "u", kind: .usage, provider: .claude, lamp: .yellow, title: "Claude 5h at 80%",
                                  detail: "usage is high · resets in 1h 12m", sessionID: nil, createdAt: now)
        let cases: [Case] = [
            Case(name: "collapsed-idle", scenario: "idle", mode: .collapsed),
            Case(name: "collapsed-single-green", scenario: "single-green", mode: .collapsed),
            Case(name: "collapsed-mixed", scenario: "mixed", mode: .collapsed),
            Case(name: "collapsed-all-lit", scenario: "all-lit", mode: .collapsed),
            Case(name: "collapsed-parked", scenario: "parked", mode: .collapsed),
            Case(name: "collapsed-compact", scenario: "mixed", mode: .collapsed, metrics: .compact),
            Case(name: "collapsed-virtual-notch", scenario: "mixed", mode: .collapsed, virtualNotch: true),
            Case(name: "peek-approval", scenario: "attention", mode: .peek, peek: peekApproval),
            Case(name: "peek-done", scenario: "mixed", mode: .peek, peek: peekDone),
            Case(name: "peek-usage", scenario: "mixed", mode: .peek, peek: peekUsage),
            Case(name: "expanded-mixed", scenario: "mixed", mode: .expanded),
            Case(name: "expanded-all-lit", scenario: "all-lit", mode: .expanded),
            Case(name: "expanded-many", scenario: "many", mode: .expanded),
            Case(name: "expanded-limits", scenario: "limits", mode: .expanded),
            Case(name: "expanded-idle", scenario: "idle", mode: .expanded),
        ]
        for c in cases { render(c, now: now, to: dir) }
        renderLamps(to: dir)
        StdoutLog.line("SNAPSHOTS \(cases.count + 1) written to \(dir)")
    }

    static func geometry(virtual: Bool) -> NotchGeometry {
        if !virtual, let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return NotchGeometry.compute(ScreenDescriptor(screen))
        }
        let fallback = ScreenDescriptor(
            displayID: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 949), safeAreaTop: virtual ? 0 : 32,
            auxiliaryTopLeft: virtual ? nil : CGRect(x: 0, y: 950, width: 663, height: 32),
            auxiliaryTopRight: virtual ? nil : CGRect(x: 848, y: 950, width: 664, height: 32),
            backingScale: 2, isPrimary: true)
        return NotchGeometry.compute(fallback)
    }

    private static func render(_ c: Case, now: Date, to dir: String) {
        let vm = IslandViewModel()
        vm.apply(sessions: SessionSnapshot(generatedAt: now, sessions: DemoScenarios.sessions(c.scenario, now: now)), now: now)
        vm.apply(usage: DemoScenarios.usage(for: c.scenario, now: now), now: now)
        let g = geometry(virtual: c.virtualNotch)
        let model = IslandModel(geometry: g, metrics: c.metrics)
        model.mode = c.mode
        model.peek = c.peek
        model.layout = IslandLayoutEngine.layout(mode: c.mode, geometry: g, metrics: c.metrics,
                                                 peekTextWidth: c.peek.map(PeekLineView.textWidth) ?? 0,
                                                 content: vm.contentMetrics)
        // Show the island over a menu-bar-like strip so the black shape is visible.
        let canvas = model.layout.canvas.insetBy(dx: -40, dy: 0)
        let size = CGSize(width: canvas.width, height: model.layout.canvas.height + 24)
        let view = ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.56), Color(red: 0.62, green: 0.52, blue: 0.62)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Rectangle().fill(Color.white.opacity(0.28)).frame(height: g.bandHeight + 1)
            IslandRootView(model: model, vm: vm, actions: IslandActions())
                .frame(width: model.layout.canvas.width, height: model.layout.canvas.height)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .environment(\.lampRenderer, .staticSwiftUI)
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return }
        write(cg, to: Paths.join(dir, "\(c.name).png"))
    }

    /// The real Core Animation lamps for every mode, drawn from model values.
    private static func renderLamps(to dir: String) {
        let modes: [(String, LampTriple)] = [
            ("off", .allOff),
            ("green", LampTriple(green: .breathing)),
            ("yellow-fresh", LampTriple(yellow: .steady)),
            ("yellow-parked", LampTriple(yellow: .dim)),
            ("red", LampTriple(red: .blinking)),
            ("all", LampTriple(red: .blinking, yellow: .steady, green: .breathing)),
        ]
        let style = TrafficLightView.Style.ear
        let cell = CGSize(width: style.size.width + 16, height: style.size.height + 16)
        let scale: CGFloat = 4
        let width = Int(cell.width * CGFloat(modes.count) * scale)
        let height = Int(cell.height * scale)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        for (i, (_, triple)) in modes.enumerated() {
            let view = TrafficLightView(style: style)
            view.frame = CGRect(origin: .zero, size: style.size)
            view.layoutSubtreeIfNeeded()
            view.layout()
            view.apply(triple, reduceMotion: true)
            ctx.saveGState()
            // Layers are flipped relative to the bitmap context.
            ctx.translateBy(x: CGFloat(i) * cell.width + 8, y: cell.height - 8)
            ctx.scaleBy(x: 1, y: -1)
            view.renderStatic(in: ctx)
            ctx.restoreGState()
        }
        if let image = ctx.makeImage() { write(image, to: Paths.join(dir, "lamps-core-animation.png")) }
    }

    private static func write(_ image: CGImage, to path: String) {
        let rep = NSBitmapImageRep(cgImage: image)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
