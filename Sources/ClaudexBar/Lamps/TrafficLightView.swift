import AppKit
import ClaudexCore
import QuartzCore
import SwiftUI

/// Traffic light drawn with Core Animation. Continuous pulses run in the render server, so
/// the app itself stays idle while lamps breathe or blink.
final class TrafficLightView: NSView {
    struct Style: Equatable {
        var lamp: CGFloat
        var gap: CGFloat
        var padX: CGFloat
        var padY: CGFloat
        var housing: Bool
        var single: Bool

        static let ear = Style(lamp: 7, gap: 3, padX: 4, padY: 3, housing: true, single: false)
        static let earCompact = Style(lamp: 6, gap: 2.5, padX: 3.5, padY: 3, housing: true, single: false)
        static let row = Style(lamp: 8, gap: 0, padX: 3, padY: 3, housing: false, single: true)

        var size: CGSize {
            single
                ? CGSize(width: lamp + 2 * padX, height: lamp + 2 * padY)
                : CGSize(width: 3 * lamp + 2 * gap + 2 * padX, height: lamp + 2 * padY)
        }
    }

    private let style: Style
    private let housing = CALayer()
    private let lamps: [LampLayer]
    private var applied: LampTriple?
    private var appliedReduceMotion = false

    init(style: Style) {
        self.style = style
        lamps = style.single
            ? [LampLayer(color: Theme.green)]
            : [LampLayer(color: Theme.red), LampLayer(color: Theme.yellow), LampLayer(color: Theme.green)]
        super.init(frame: CGRect(origin: .zero, size: style.size))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        guard let root = layer else { return }
        root.masksToBounds = false
        if style.housing {
            housing.backgroundColor = NSColor(white: 0.10, alpha: 1).cgColor
            housing.borderColor = NSColor(white: 1, alpha: 0.09).cgColor
            housing.borderWidth = 0.5
            housing.actions = LampLayer.noActions
            root.addSublayer(housing)
        }
        lamps.forEach { root.addSublayer($0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { style.size }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = style.size
        let origin = CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        housing.frame = CGRect(origin: origin, size: size)
        housing.cornerRadius = size.height / 2
        for (i, lamp) in lamps.enumerated() {
            let x = origin.x + style.padX + CGFloat(i) * (style.lamp + style.gap)
            lamp.frame = CGRect(x: x, y: origin.y + style.padY, width: style.lamp, height: style.lamp)
            lamp.layoutLamp()
        }
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        lamps.forEach { $0.setScale(scale) }
        housing.contentsScale = scale
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // AppKit may drop layer animations when a view leaves a window; re-apply.
        if window != nil, let triple = applied {
            applied = nil
            apply(triple, reduceMotion: appliedReduceMotion)
        }
    }

    func apply(_ triple: LampTriple, reduceMotion: Bool) {
        if applied == triple && appliedReduceMotion == reduceMotion { return }
        applied = triple
        appliedReduceMotion = reduceMotion
        if style.single {
            let (color, mode): (NSColor, LampMode)
            if triple.red != .off {
                (color, mode) = (Theme.red, triple.red)
            } else if triple.yellow != .off {
                (color, mode) = (Theme.yellow, triple.yellow)
            } else {
                (color, mode) = (Theme.green, triple.green)
            }
            lamps[0].setColor(color)
            lamps[0].setMode(mode, reduceMotion: reduceMotion)
        } else {
            lamps[0].setMode(triple.red, reduceMotion: reduceMotion)
            lamps[1].setMode(triple.yellow, reduceMotion: reduceMotion)
            lamps[2].setMode(triple.green, reduceMotion: reduceMotion)
        }
    }

    /// Draws the current (model-value) state into a context, for snapshot tests.
    func renderStatic(in ctx: CGContext) {
        layer?.render(in: ctx)
    }
}

/// One lamp: a dim base, a soft glow (shadow-only layer) and a lit radial-gradient disc.
nonisolated final class LampLayer: CALayer {
    static var noActions: [String: CAAction] {
        [
            "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "shadowPath": NSNull(),
            "cornerRadius": NSNull(), "contents": NSNull(), "backgroundColor": NSNull(), "colors": NSNull(),
        ]
    }

    private let base = CALayer()
    private let glow = CALayer()
    private let lit = CAGradientLayer()
    private var color: NSColor
    private(set) var mode: LampMode = .off

    init(color: NSColor) {
        self.color = color
        super.init()
        actions = Self.noActions
        for l in [glow, base, lit] as [CALayer] {
            l.actions = Self.noActions
            addSublayer(l)
        }
        glow.shadowOffset = .zero
        glow.shadowOpacity = 1
        glow.shadowRadius = 3.5
        glow.opacity = 0
        lit.type = .radial
        lit.startPoint = CGPoint(x: 0.36, y: 0.30)
        lit.endPoint = CGPoint(x: 1.0, y: 1.0)
        lit.masksToBounds = true
        lit.opacity = 0
        applyColor()
    }

    override init(layer: Any) {
        color = (layer as? LampLayer)?.color ?? .white
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setScale(_ s: CGFloat) {
        contentsScale = s
        for l in [glow, base, lit] as [CALayer] { l.contentsScale = s }
    }

    func layoutLamp() {
        let r = bounds
        for l in [glow, base, lit] as [CALayer] {
            l.frame = r
            l.cornerRadius = r.width / 2
        }
        glow.shadowPath = CGPath(ellipseIn: r, transform: nil)
    }

    func setColor(_ c: NSColor) {
        guard c != color else { return }
        color = c
        applyColor()
    }

    private func applyColor() {
        base.backgroundColor = color.withAlphaComponent(0.17).cgColor
        glow.shadowColor = color.cgColor
        let highlight = color.blended(withFraction: 0.45, of: .white) ?? color
        lit.colors = [highlight.cgColor, color.cgColor]
    }

    private static func resting(_ m: LampMode) -> (lit: Float, glow: Float) {
        switch m {
        case .off: return (0, 0)
        case .dim: return (0.42, 0)
        case .steady: return (1, 0.55)
        case .breathing: return (0.9, 0.5)
        case .blinking: return (1, 0.8)
        }
    }

    func setMode(_ newMode: LampMode, reduceMotion: Bool) {
        let old = mode
        mode = newMode
        let litNow = lit.presentation()?.opacity ?? lit.opacity
        let glowNow = glow.presentation()?.opacity ?? glow.opacity
        lit.removeAnimation(forKey: "loop")
        glow.removeAnimation(forKey: "loop")
        glow.removeAnimation(forKey: "flash")

        let rest = Self.resting(newMode)
        let fade: CFTimeInterval = 0.22
        crossfade(lit, from: litNow, to: rest.lit, duration: fade)
        crossfade(glow, from: glowNow, to: rest.glow, duration: fade)
        guard !reduceMotion else { return }

        let start = CACurrentMediaTime() + fade
        switch newMode {
        case .breathing:
            lit.add(Self.loop(from: 0.72, to: 1.0, period: 2.4, start: start), forKey: "loop")
            glow.add(Self.loop(from: 0.15, to: 0.85, period: 2.4, start: start), forKey: "loop")
        case .blinking:
            lit.add(Self.blink(start: start, low: 0.22), forKey: "loop")
            glow.add(Self.blink(start: start, low: 0.05), forKey: "loop")
            if old != .blinking { glow.add(Self.flash(), forKey: "flash") }
        default:
            break
        }
    }

    private func crossfade(_ layer: CALayer, from: Float, to: Float, duration: CFTimeInterval) {
        layer.opacity = to
        guard abs(from - to) > 0.001 else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(a, forKey: "fade")
    }

    /// Autoreversing opacity loop, phase-locked to media time so all lamps pulse together.
    private static func loop(from: Float, to: Float, period: CFTimeInterval, start: CFTimeInterval) -> CAAnimation {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = to
        a.duration = period / 2
        a.autoreverses = true
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return synced(a, period: period, start: start)
    }

    private static func blink(start: CFTimeInterval, low: Float) -> CAAnimation {
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [1, 1, low, low, 1]
        a.keyTimes = [0, 0.42, 0.52, 0.86, 1]
        a.duration = 1.0
        return synced(a, period: 1.0, start: start)
    }

    private static func flash() -> CAAnimation {
        let a = CAKeyframeAnimation(keyPath: "shadowRadius")
        a.values = [3.5, 8, 3.5]
        a.keyTimes = [0, 0.4, 1]
        a.duration = 0.32
        a.repeatCount = 3
        return a
    }

    private static func synced(_ a: CAAnimation, period: CFTimeInterval, start: CFTimeInterval) -> CAAnimation {
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        // Starts after the crossfade (no fill, so the fade shows until then). The time offset
        // makes the phase a function of absolute media time: every lamp pulses in sync.
        a.beginTime = start
        a.timeOffset = start.truncatingRemainder(dividingBy: period)
        a.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 24)
        return a
    }
}

/// SwiftUI wrapper; in snapshot mode renders a static SwiftUI equivalent instead.
struct TrafficLight: View {
    var lamps: LampTriple
    var style: TrafficLightView.Style = .ear
    @Environment(\.lampRenderer) private var renderer

    var body: some View {
        switch renderer {
        case .coreAnimation:
            CALampView(lamps: lamps, style: style)
                .frame(width: style.size.width, height: style.size.height)
        case .staticSwiftUI:
            StaticTrafficLight(lamps: lamps, style: style)
        }
    }
}

private struct CALampView: NSViewRepresentable {
    var lamps: LampTriple
    var style: TrafficLightView.Style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.forceReduceMotion) private var forceReduceMotion

    func makeNSView(context: Context) -> TrafficLightView { TrafficLightView(style: style) }

    func updateNSView(_ view: TrafficLightView, context: Context) {
        view.apply(lamps, reduceMotion: reduceMotion || forceReduceMotion)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TrafficLightView, context: Context) -> CGSize? {
        style.size
    }
}

/// Pure-SwiftUI traffic light (used for offscreen snapshots, which can't draw NSViews).
struct StaticTrafficLight: View {
    var lamps: LampTriple
    var style: TrafficLightView.Style

    private func opacity(_ m: LampMode) -> Double {
        switch m {
        case .off: return 0
        case .dim: return 0.42
        case .steady, .breathing, .blinking: return 1
        }
    }

    private func lamp(_ color: NSColor, _ mode: LampMode) -> some View {
        ZStack {
            Circle().fill(Color(nsColor: color).opacity(0.17))
            Circle()
                .fill(RadialGradient(colors: [Color(nsColor: color.blended(withFraction: 0.45, of: .white) ?? color),
                                              Color(nsColor: color)],
                                     center: UnitPoint(x: 0.36, y: 0.3), startRadius: 0, endRadius: style.lamp * 0.8))
                .opacity(opacity(mode))
                .shadow(color: Color(nsColor: color).opacity(mode == .off || mode == .dim ? 0 : 0.8), radius: 3.5)
        }
        .frame(width: style.lamp, height: style.lamp)
    }

    var body: some View {
        Group {
            if style.single {
                let (c, m): (NSColor, LampMode) = lamps.red != .off ? (Theme.red, lamps.red)
                    : lamps.yellow != .off ? (Theme.yellow, lamps.yellow) : (Theme.green, lamps.green)
                lamp(c, m)
            } else {
                HStack(spacing: style.gap) {
                    lamp(Theme.red, lamps.red)
                    lamp(Theme.yellow, lamps.yellow)
                    lamp(Theme.green, lamps.green)
                }
                .padding(.horizontal, style.padX)
                .padding(.vertical, style.padY)
                .background(Capsule().fill(Color(white: 0.10)).overlay(Capsule().stroke(Color.white.opacity(0.09), lineWidth: 0.5)))
            }
        }
        .frame(width: style.size.width, height: style.size.height)
    }
}
