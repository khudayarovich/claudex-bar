import CoreGraphics
import Foundation

public enum IslandMode: String, Sendable, Equatable {
    case collapsed, peek, expanded
}

/// Tunable constants shared by the layout engine and the SwiftUI views, so the window
/// frame and the drawn shape can never disagree.
public struct IslandMetrics: Sendable, Equatable {
    public var earWidth: CGFloat

    public var collapsedShoulder: CGFloat = 6
    public var collapsedBottom: CGFloat = 10

    public var peekShoulder: CGFloat = 8
    public var peekBottom: CGFloat = 16
    public var peekLineHeight: CGFloat = 30
    public var peekMaxWidth: CGFloat = 480
    public var peekMargin: CGFloat = 18

    public var expandedShoulder: CGFloat = 14
    public var expandedBottom: CGFloat = 24
    public var expandedWidth: CGFloat = 560
    public var expandedMargin: CGFloat = 30

    // Expanded content rhythm (points).
    public var contentTopGap: CGFloat = 8
    public var usageRowHeight: CGFloat = 18
    public var usageCardChrome: CGFloat = 26   // provider title row + padding
    public var sectionGap: CGFloat = 10
    public var sessionRowHeight: CGFloat = 34
    public var emptyStateHeight: CGFloat = 44
    public var footerHeight: CGFloat = 26
    public var bottomPadding: CGFloat = 12
    public var maxVisibleRows: Int = 6

    public init(earWidth: CGFloat) { self.earWidth = earWidth }

    public static let regular = IslandMetrics(earWidth: 72)
    public static let compact = IslandMetrics(earWidth: 60)
}

/// What the expanded panel will show; drives its (deterministic) height.
public struct ExpandedContentMetrics: Sendable, Equatable {
    public var usageRows: Int
    public var sessionRows: Int
    public var hasMoreRow: Bool

    public init(usageRows: Int, sessionRows: Int, hasMoreRow: Bool) {
        self.usageRows = usageRows
        self.sessionRows = sessionRows
        self.hasMoreRow = hasMoreRow
    }

    public static let empty = ExpandedContentMetrics(usageRows: 0, sessionRows: 0, hasMoreRow: false)
}

public struct IslandLayout: Sendable, Equatable {
    public var mode: IslandMode
    /// Size of the island shape's frame, including the concave shoulders on both sides.
    public var bodySize: CGSize
    public var shoulder: CGFloat
    public var bottomRadius: CGFloat
    /// Window frame in AppKit global coordinates.
    public var canvas: CGRect
    /// Region that counts as "hovering the island" in AppKit global coordinates.
    public var hoverRect: CGRect
    public var shadowOpacity: Double
    public var shadowRadius: CGFloat
}

public enum IslandLayoutEngine {
    public static func collapsedBodyWidth(_ g: NotchGeometry, _ m: IslandMetrics) -> CGFloat {
        let ear = min(m.earWidth, g.maxEarWidth)
        return g.notch.width + 2 * ear + 2 * m.collapsedShoulder
    }

    public static func expandedHeight(_ g: NotchGeometry, _ m: IslandMetrics, _ c: ExpandedContentMetrics) -> CGFloat {
        let usage = c.usageRows > 0 ? m.usageCardChrome + CGFloat(c.usageRows) * m.usageRowHeight : 0
        let rows = CGFloat(min(c.sessionRows, m.maxVisibleRows)) + (c.hasMoreRow ? 1 : 0)
        let list = c.sessionRows == 0 ? m.emptyStateHeight : rows * m.sessionRowHeight
        return g.bandHeight + m.contentTopGap + usage + m.sectionGap + list + m.sectionGap + m.footerHeight + m.bottomPadding
    }

    public static func layout(
        mode: IslandMode,
        geometry g: NotchGeometry,
        metrics m: IslandMetrics,
        peekTextWidth: CGFloat = 0,
        content: ExpandedContentMetrics = .empty
    ) -> IslandLayout {
        let top = g.screenFrame.maxY
        let midX = g.notch.midX
        let collapsedWidth = collapsedBodyWidth(g, m)

        switch mode {
        case .collapsed:
            let size = CGSize(width: collapsedWidth, height: g.bandHeight)
            let body = CGRect(x: midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
            return IslandLayout(
                mode: mode, bodySize: size, shoulder: m.collapsedShoulder, bottomRadius: m.collapsedBottom,
                canvas: body, hoverRect: body.insetBy(dx: m.collapsedShoulder, dy: 0),
                shadowOpacity: 0, shadowRadius: 0
            )

        case .peek:
            let screenLimit = g.screenFrame.width - 32
            let width = min(max(peekTextWidth + 2 * m.peekShoulder, collapsedWidth), m.peekMaxWidth, screenLimit)
            let size = CGSize(width: width, height: g.bandHeight + m.peekLineHeight)
            let body = CGRect(x: midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
            let canvas = CGRect(
                x: body.minX - m.peekMargin, y: body.minY - m.peekMargin,
                width: body.width + 2 * m.peekMargin, height: body.height + m.peekMargin
            )
            return IslandLayout(
                mode: mode, bodySize: size, shoulder: m.peekShoulder, bottomRadius: m.peekBottom,
                canvas: canvas, hoverRect: body.insetBy(dx: m.peekShoulder, dy: 0),
                shadowOpacity: 0.35, shadowRadius: 10
            )

        case .expanded:
            let width = min(max(m.expandedWidth, collapsedWidth), g.screenFrame.width - 32)
            let height = expandedHeight(g, m, content)
            let size = CGSize(width: width, height: height)
            let body = CGRect(x: midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
            let canvas = CGRect(
                x: body.minX - m.expandedMargin, y: body.minY - m.expandedMargin,
                width: body.width + 2 * m.expandedMargin, height: body.height + m.expandedMargin
            )
            return IslandLayout(
                mode: mode, bodySize: size, shoulder: m.expandedShoulder, bottomRadius: m.expandedBottom,
                canvas: canvas, hoverRect: body.insetBy(dx: m.expandedShoulder, dy: 0),
                shadowOpacity: 0.55, shadowRadius: 18
            )
        }
    }
}
