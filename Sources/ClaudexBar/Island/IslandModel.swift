import ClaudexCore
import Observation
import SwiftUI

/// Presentation state of one island (one per screen).
@Observable
final class IslandModel {
    var mode: IslandMode = .collapsed
    var pinned = false
    var peek: PeekEvent?
    var layout: IslandLayout
    var geometry: NotchGeometry
    var metrics: IslandMetrics
    var showUsageRing = true
    var forceReduceMotion = false
    /// Sub-point residual between the notch center and the backing-aligned canvas center.
    var contentOffsetX: CGFloat = 0

    init(geometry: NotchGeometry, metrics: IslandMetrics) {
        self.geometry = geometry
        self.metrics = metrics
        self.layout = IslandLayoutEngine.layout(mode: .collapsed, geometry: geometry, metrics: metrics)
    }
}
