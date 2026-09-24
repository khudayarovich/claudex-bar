import ClaudexCore
import Foundation
import Observation

/// Derived, display-ready state. Assigns properties only when values change, so views that
/// read them don't re-render on every poll.
@Observable
final class IslandViewModel {
    struct UsageRowModel: Equatable, Identifiable {
        var id: String
        var label: String
        var percentText: String
        var fraction: Double?
        var level: UsageLevel
        var resetText: String?
        var resetHelp: String?
    }

    struct ProviderSummary: Equatable {
        var provider: Provider
        var lamps = LampTriple.allOff
        var counts: AgentLamps
        var ring: Double?
        var ringLevel = UsageLevel.normal
        var plan: String?
        var usage: [UsageRowModel] = []
        var usageNote: String?
        var accessibility = ""

        init(provider: Provider) {
            self.provider = provider
            counts = AgentLamps(provider: provider)
        }
    }

    struct SessionRowModel: Equatable, Identifiable {
        var id: String
        var provider: Provider
        var lamps: LampTriple
        var title: String
        var activity: String
        var since: Date
        var badge: String
        var appBundleID: String?
        var pid: Int32?
        var isAttention: Bool
    }

    private(set) var claude = ProviderSummary(provider: .claude)
    private(set) var codex = ProviderSummary(provider: .codex)
    private(set) var rows: [SessionRowModel] = []
    private(set) var hiddenRowCount = 0
    private(set) var lastUpdate: Date?

    var policy = LampPolicy()
    var maxVisibleRows = 6
    var maxUsageRows = 3
    /// Receives peek events detected in snapshot changes.
    var onPeek: (([PeekEvent]) -> Void)?

    @ObservationIgnored private var sessions = SessionSnapshot.empty
    @ObservationIgnored private var usage = UsageSnapshot.empty
    @ObservationIgnored private var detector = PeekEventDetector()
    @ObservationIgnored private var sessionsByID: [String: AgentSession] = [:]

    func summary(_ p: Provider) -> ProviderSummary { p == .claude ? claude : codex }

    func session(id: String) -> AgentSession? { sessionsByID[id] }

    var contentMetrics: ExpandedContentMetrics {
        let usageRows = min(maxUsageRows, max(1, max(claude.usage.count, codex.usage.count)))
        return ExpandedContentMetrics(usageRows: usageRows, sessionRows: rows.count, hasMoreRow: hiddenRowCount > 0)
    }

    func apply(sessions snapshot: SessionSnapshot, now: Date = Date()) {
        sessions = snapshot
        sessionsByID = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.id, $0) })
        recompute(now: now)
        let events = detector.diff(sessions: snapshot.sessions, now: now)
        if !events.isEmpty { onPeek?(events) }
    }

    func apply(usage snapshot: UsageSnapshot, now: Date = Date()) {
        usage = snapshot
        recompute(now: now)
        let events = detector.diff(usage: snapshot, now: now)
        if !events.isEmpty { onPeek?(events) }
    }

    /// Time-dependent parts (fresh → parked yellow, reset countdowns).
    func tick(now: Date = Date()) { recompute(now: now) }

    private func recompute(now: Date) {
        let lamps = Aggregator.lamps(sessions.sessions, now: now, policy: policy)
        set(\.claude, makeSummary(.claude, lamps: lamps[.claude] ?? AgentLamps(provider: .claude), now: now))
        set(\.codex, makeSummary(.codex, lamps: lamps[.codex] ?? AgentLamps(provider: .codex), now: now))

        let ordered = Aggregator.ordered(sessions.sessions, now: now, policy: policy)
        let visible = ordered.prefix(maxVisibleRows).map { s in
            SessionRowModel(
                id: s.id, provider: s.provider,
                lamps: .single(s.state, fresh: s.freshness(now: now, window: policy.freshWindow) != .parked),
                title: s.project.map { p in p == s.title ? p : s.title } ?? s.title,
                activity: s.activity, since: s.stateSince, badge: s.origin.badge,
                appBundleID: s.appBundleID, pid: s.pid,
                isAttention: s.state.lamp == .red
            )
        }
        set(\.rows, Array(visible))
        set(\.hiddenRowCount, max(0, ordered.count - visible.count))
        let newest = [sessions.generatedAt, usage.generatedAt].filter { $0 != .distantPast }.max()
        set(\.lastUpdate, newest)
    }

    private func makeSummary(_ p: Provider, lamps: AgentLamps, now: Date) -> ProviderSummary {
        var s = ProviderSummary(provider: p)
        s.lamps = LampTriple(lamps)
        s.counts = lamps
        let u = usage[p]
        s.plan = u.plan
        let constrained = u.mostConstrained
        s.ring = constrained?.fraction
        s.ringLevel = UsageLevel(percent: constrained?.usedPercent)
        s.usage = u.windows.prefix(maxUsageRows).map { w in
            UsageRowModel(id: w.id, label: w.label, percentText: Formatters.percent(w.usedPercent),
                          fraction: w.fraction, level: UsageLevel(percent: w.usedPercent),
                          resetText: Formatters.shortReset(w, now: now),
                          resetHelp: Formatters.reset(w, now: now).map { "\($0) · from \(w.source.displayName)" })
        }
        switch u.status {
        case .loading: s.usageNote = "Loading usage…"
        case .ok: s.usageNote = nil
        case let .stale(since): s.usageNote = "As of \(Formatters.elapsed(since: since, now: now)) ago"
        case let .unavailable(reason): s.usageNote = reason
        }
        var parts: [String] = []
        if lamps.attention > 0 { parts.append("\(lamps.attention) need attention") }
        if lamps.working > 0 { parts.append("\(lamps.working) working") }
        let waiting = lamps.waitingFresh + lamps.waitingParked
        if waiting > 0 { parts.append("\(waiting) waiting for you") }
        if parts.isEmpty { parts.append("no sessions") }
        if let c = constrained, let v = c.usedPercent { parts.append("\(c.label) usage \(Int(v)) percent") }
        s.accessibility = "\(p.displayName): " + parts.joined(separator: ", ")
        return s
    }

    private func set<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<IslandViewModel, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
}
