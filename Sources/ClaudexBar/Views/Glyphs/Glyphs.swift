import ClaudexCore
import SwiftUI

/// A ten-ray starburst (an abstract nod to Claude's mark).
nonisolated struct StarburstShape: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        var p = Path()
        let rays = 10
        for i in 0..<rays {
            let angle = (Double(i) / Double(rays)) * 2 * .pi - .pi / 2
            let length = r * (i % 2 == 0 ? 1.0 : 0.8)
            let baseHalf = r * 0.12
            let tipHalf = r * 0.045
            let inner = r * 0.16
            let dir = CGPoint(x: cos(angle), y: sin(angle))
            let perp = CGPoint(x: -dir.y, y: dir.x)
            func pt(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
                CGPoint(x: c.x + dir.x * along + perp.x * across, y: c.y + dir.y * along + perp.y * across)
            }
            p.move(to: pt(inner, -baseHalf))
            p.addLine(to: pt(length, -tipHalf))
            p.addQuadCurve(to: pt(length, tipHalf), control: pt(length + tipHalf * 1.6, 0))
            p.addLine(to: pt(inner, baseHalf))
            p.closeSubpath()
        }
        p.addEllipse(in: CGRect(x: c.x - r * 0.24, y: c.y - r * 0.24, width: r * 0.48, height: r * 0.48))
        return p
    }
}

/// Rounded, pointy-top hexagon outline.
nonisolated struct HexagonShape: Shape {
    var cornerRadius: CGFloat = 1.6

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        let pts: [CGPoint] = (0..<6).map { i in
            let a = Double(i) * .pi / 3 - .pi / 2
            return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
        }
        var p = Path()
        let startMid = CGPoint(x: (pts[0].x + pts[1].x) / 2, y: (pts[0].y + pts[1].y) / 2)
        p.move(to: startMid)
        for i in 1...6 {
            let corner = pts[i % 6]
            let next = pts[(i + 1) % 6]
            p.addArc(tangent1End: corner, tangent2End: next, radius: cornerRadius)
        }
        p.closeSubpath()
        return p
    }
}

/// `>_` prompt drawn as strokes.
nonisolated struct PromptShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + w * 0.30, y: rect.minY + h * 0.36))
        p.addLine(to: CGPoint(x: rect.minX + w * 0.46, y: rect.minY + h * 0.50))
        p.addLine(to: CGPoint(x: rect.minX + w * 0.30, y: rect.minY + h * 0.64))
        p.move(to: CGPoint(x: rect.minX + w * 0.52, y: rect.minY + h * 0.66))
        p.addLine(to: CGPoint(x: rect.minX + w * 0.70, y: rect.minY + h * 0.66))
        return p
    }
}

struct ProviderGlyph: View {
    let provider: Provider
    var size: CGFloat = 12

    var body: some View {
        switch provider {
        case .claude:
            StarburstShape()
                .fill(Theme.claudeAccent)
                .frame(width: size, height: size)
        case .codex:
            ZStack {
                HexagonShape(cornerRadius: size * 0.14)
                    .stroke(Theme.codexAccent, lineWidth: max(1, size * 0.11))
                PromptShape()
                    .stroke(Theme.codexAccent, style: StrokeStyle(lineWidth: max(1, size * 0.11), lineCap: .round, lineJoin: .round))
            }
            .frame(width: size, height: size)
        }
    }
}

/// Glyph surrounded by a thin ring showing the most constrained usage window.
struct GlyphWithRing: View {
    let provider: Provider
    let fraction: Double?
    let level: UsageLevel
    var diameter: CGFloat = 19
    var showRing = true

    var body: some View {
        ZStack {
            if showRing {
                Circle()
                    .stroke(Theme.track, lineWidth: 1.75)
                if let fraction {
                    Circle()
                        .trim(from: 0, to: max(0.02, fraction))
                        .stroke(Theme.usage(level), style: StrokeStyle(lineWidth: 1.75, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.6), value: fraction)
                }
            }
            ProviderGlyph(provider: provider, size: diameter * (showRing ? 0.56 : 0.8))
        }
        .frame(width: diameter, height: diameter)
    }
}
