import ClaudexCore
import SwiftUI

/// Callbacks from the island's views to the window controller.
struct IslandActions {
    var activateSession: (String) -> Void = { _ in }
    var togglePin: () -> Void = {}
    var collapse: () -> Void = {}
    var openSettings: () -> Void = {}
    var refresh: () -> Void = {}
    var quit: () -> Void = {}
}

enum EarSide { case left, right }

/// One side of the band: glyph at the outer edge, traffic light next to the notch. When
/// expanded, the provider name and plan fade in beside the glyph. A ZStack keeps both ends
/// pinned so the content can never overflow the ear, whatever its (animated) width.
struct EarView: View {
    let summary: IslandViewModel.ProviderSummary
    let side: EarSide
    let expanded: Bool
    let showRing: Bool
    let compact: Bool

    var body: some View {
        let outer: CGFloat = expanded ? 14 : (compact ? 6 : 7)
        let inner: CGFloat = expanded ? 12 : (compact ? 4 : 5)
        ZStack {
            HStack(spacing: 8) {
                if side == .left {
                    glyph
                    if expanded { labels(alignment: .leading).transition(Self.labelTransition) }
                } else {
                    if expanded { labels(alignment: .trailing).transition(Self.labelTransition) }
                    glyph
                }
            }
            .frame(maxWidth: .infinity, alignment: side == .left ? .leading : .trailing)
            TrafficLight(lamps: summary.lamps, style: compact && !expanded ? .earCompact : .ear)
                .frame(maxWidth: .infinity, alignment: side == .left ? .trailing : .leading)
        }
        .padding(.leading, side == .left ? outer : inner)
        .padding(.trailing, side == .left ? inner : outer)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.accessibility)
    }

    /// Labels appear once the band has mostly spread out (so they never overlap the glyph or
    /// get clipped by the still-growing island) and vanish quickly on collapse.
    static let labelTransition = AnyTransition.asymmetric(
        insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.16)),
        removal: .opacity.animation(.easeIn(duration: 0.08))
    )

    private var glyph: some View {
        GlyphWithRing(provider: summary.provider, fraction: summary.ring, level: summary.ringLevel,
                      diameter: compact && !expanded ? 17 : 19, showRing: showRing)
    }

    private func labels(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(summary.provider.displayName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            if let plan = summary.plan {
                Text(plan)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

struct BandView: View {
    let vm: IslandViewModel
    let notchWidth: CGFloat
    let expanded: Bool
    let showRing: Bool
    let compact: Bool

    var body: some View {
        HStack(spacing: 0) {
            EarView(summary: vm.claude, side: .left, expanded: expanded, showRing: showRing, compact: compact)
                .frame(maxWidth: .infinity)
            Color.clear.frame(width: notchWidth)
            EarView(summary: vm.codex, side: .right, expanded: expanded, showRing: showRing, compact: compact)
                .frame(maxWidth: .infinity)
        }
    }
}

struct PeekLineView: View {
    let event: PeekEvent

    var body: some View {
        HStack(spacing: 8) {
            TrafficLight(lamps: lamps, style: .row)
            ProviderGlyph(provider: event.provider, size: 11)
            Text(event.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Text(event.detail)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.horizontal, 16)
    }

    private var lamps: LampTriple {
        switch event.lamp {
        case .red: return LampTriple(red: .blinking)
        case .yellow: return LampTriple(yellow: .steady)
        case .green: return LampTriple(green: .breathing)
        }
    }

    static func textWidth(_ e: PeekEvent) -> CGFloat {
        let bold = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let regular = NSFont.systemFont(ofSize: 12)
        let a = (e.title as NSString).size(withAttributes: [.font: bold]).width
        let b = (e.detail as NSString).size(withAttributes: [.font: regular]).width
        // lamp (14) + glyph (11) + four 8-pt gaps + 16-pt padding each side + slack.
        return ceil(a + b + 14 + 11 + 4 * 8 + 32 + 12)
    }
}

// MARK: - Expanded

struct UsageBar: View {
    let fraction: Double?
    let level: UsageLevel

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                if let fraction {
                    Capsule()
                        .fill(Theme.usage(level))
                        .frame(width: max(3, geo.size.width * fraction))
                        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: fraction)
                }
            }
        }
        .frame(height: 4)
    }
}

struct UsageCardView: View {
    let summary: IslandViewModel.ProviderSummary
    let rows: Int
    let metrics: IslandMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ProviderGlyph(provider: summary.provider, size: 11)
                Text(summary.provider.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                if let plan = summary.plan {
                    Text(plan).font(.system(size: 10)).foregroundStyle(Theme.tertiaryText)
                }
                Spacer(minLength: 0)
                if let note = summary.usageNote, !summary.usage.isEmpty {
                    Text(note).font(.system(size: 9.5)).foregroundStyle(Theme.tertiaryText)
                }
            }
            .lineLimit(1)
            .frame(height: metrics.usageCardChrome - 6, alignment: .center)
            .padding(.bottom, 6)

            if summary.usage.isEmpty {
                Text(summary.usageNote ?? "No usage data")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                    .frame(height: metrics.usageRowHeight, alignment: .leading)
            }
            ForEach(summary.usage.prefix(rows)) { row in
                HStack(spacing: 7) {
                    Text(row.label)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 46, alignment: .leading)
                    UsageBar(fraction: row.fraction, level: row.level)
                    Text(row.percentText)
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.primaryText)
                        .contentTransition(.numericText())
                        .frame(width: 34, alignment: .trailing)
                    Text(row.resetText ?? "")
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(width: 58, alignment: .leading)
                }
                .help(row.resetHelp ?? "")
                .lineLimit(1)
                .frame(height: metrics.usageRowHeight)
            }
            Spacer(minLength: 0)
        }
    }
}

struct SessionRowView: View {
    let row: IslandViewModel.SessionRowModel
    let height: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                TrafficLight(lamps: row.lamps, style: .row)
                ProviderGlyph(provider: row.provider, size: 11)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                    Text(row.activity)
                        .font(.system(size: 10.5))
                        .foregroundStyle(row.isAttention ? Color(nsColor: Theme.red).opacity(0.95) : Theme.secondaryText)
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    TimelineView(.periodic(from: .now, by: 15)) { ctx in
                        Text(Formatters.elapsed(since: row.since, now: ctx.date))
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Text(row.badge)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 9).fill(hovering ? Theme.rowHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(row.provider.displayName) session \(row.title): \(row.activity)")
    }
}

struct FooterView: View {
    let vm: IslandViewModel
    let actions: IslandActions
    let pinned: Bool

    var body: some View {
        HStack(spacing: 14) {
            TimelineView(.periodic(from: .now, by: 10)) { ctx in
                Text(Self.updatedText(vm.lastUpdate, now: ctx.date))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
            }
            Spacer()
            footerButton("arrow.clockwise", "Refresh now", actions.refresh)
            footerButton(pinned ? "pin.fill" : "pin", pinned ? "Unpin" : "Keep open", actions.togglePin)
            footerButton("gearshape", "Settings", actions.openSettings)
            footerButton("power", "Quit ClaudexBar", actions.quit)
        }
        .padding(.horizontal, 6)
    }

    static func updatedText(_ date: Date?, now: Date) -> String {
        guard let date else { return "Starting…" }
        let e = Formatters.elapsed(since: date, now: now)
        return e == "now" ? "Updated just now" : "Updated \(e) ago"
    }

    private func footerButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct ExpandedContentView: View {
    let vm: IslandViewModel
    let metrics: IslandMetrics
    let actions: IslandActions
    let pinned: Bool

    var body: some View {
        let content = vm.contentMetrics
        VStack(spacing: 0) {
            Color.clear.frame(height: metrics.contentTopGap)
            HStack(alignment: .top, spacing: 18) {
                UsageCardView(summary: vm.claude, rows: content.usageRows, metrics: metrics)
                UsageCardView(summary: vm.codex, rows: content.usageRows, metrics: metrics)
            }
            .frame(height: metrics.usageCardChrome + CGFloat(content.usageRows) * metrics.usageRowHeight, alignment: .top)
            .padding(.horizontal, 6)

            Rectangle().fill(Theme.separator).frame(height: 1)
                .padding(.vertical, (metrics.sectionGap - 1) / 2)

            if vm.rows.isEmpty {
                VStack(spacing: 2) {
                    Text("No active sessions")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                    Text("Claude Code and Codex sessions appear here while they run")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryText)
                }
                .frame(height: metrics.emptyStateHeight)
            } else {
                VStack(spacing: 0) {
                    ForEach(vm.rows) { row in
                        SessionRowView(row: row, height: metrics.sessionRowHeight) { actions.activateSession(row.id) }
                    }
                    if vm.hiddenRowCount > 0 {
                        Text("+\(vm.hiddenRowCount) more")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.tertiaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 10)
                            .frame(height: metrics.sessionRowHeight)
                    }
                }
            }

            Rectangle().fill(Theme.separator).frame(height: 1)
                .padding(.vertical, (metrics.sectionGap - 1) / 2)
            FooterView(vm: vm, actions: actions, pinned: pinned)
                .frame(height: metrics.footerHeight)
            Color.clear.frame(height: metrics.bottomPadding)
        }
        .padding(.horizontal, 12)
    }
}
