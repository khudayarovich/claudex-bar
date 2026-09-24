import SwiftUI

/// The island silhouette: concave "shoulders" at the top that blend into the screen edge,
/// and rounded bottom corners. The frame width includes both shoulders.
nonisolated struct IslandShape: Shape {
    var shoulder: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, bottom) }
        set {
            shoulder = newValue.first
            bottom = newValue.second
        }
    }

    func path(in r: CGRect) -> Path {
        let s = max(0, min(shoulder, r.height / 2, r.width / 4))
        let b = max(0, min(bottom, r.height - s, (r.width - 2 * s) / 2))
        let left = r.minX + s
        let right = r.maxX - s
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addArc(
            center: CGPoint(x: r.minX, y: r.minY + s), radius: s,
            startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false
        )
        p.addLine(to: CGPoint(x: left, y: r.maxY - b))
        p.addArc(
            center: CGPoint(x: left + b, y: r.maxY - b), radius: b,
            startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true
        )
        p.addLine(to: CGPoint(x: right - b, y: r.maxY))
        p.addArc(
            center: CGPoint(x: right - b, y: r.maxY - b), radius: b,
            startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true
        )
        p.addLine(to: CGPoint(x: right, y: r.minY + s))
        p.addArc(
            center: CGPoint(x: r.maxX, y: r.minY + s), radius: s,
            startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false
        )
        p.closeSubpath()
        return p
    }
}
