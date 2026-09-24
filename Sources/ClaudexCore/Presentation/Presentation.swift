import Foundation

// MARK: - Lamps

public enum LampMode: Sendable, Equatable {
    case off, dim, steady, breathing, blinking
}

/// The three lamps of one traffic light.
public struct LampTriple: Sendable, Equatable {
    public var red: LampMode
    public var yellow: LampMode
    public var green: LampMode

    public init(red: LampMode = .off, yellow: LampMode = .off, green: LampMode = .off) {
        self.red = red
        self.yellow = yellow
        self.green = green
    }

    public static let allOff = LampTriple()

    public init(_ lamps: AgentLamps) {
        self.init(
            red: lamps.red ? .blinking : .off,
            yellow: lamps.yellow == .fresh ? .steady : (lamps.yellow == .parked ? .dim : .off),
            green: lamps.green ? .breathing : .off
        )
    }

    /// The single lamp shown next to one session.
    public static func single(_ state: SessionState, fresh: Bool) -> LampTriple {
        switch state {
        case .needsAttention: return LampTriple(red: .blinking)
        case .waitingForUser: return LampTriple(yellow: fresh ? .steady : .dim)
        case .working: return LampTriple(green: .breathing)
        }
    }

    public var isAllOff: Bool { red == .off && yellow == .off && green == .off }
}

// MARK: - Formatting

public enum Formatters {
    /// "now", "45s", "12m", "3h", "2d".
    public static func elapsed(since: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(since))
        if s < 5 { return "now" }
        return Durations.short(s)
    }

    /// "2h 13m", "45m", "3d 4h".
    public static func countdown(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        if s < 60 { return "<1m" }
        let d = s / 86_400, h = (s % 86_400) / 3600, m = (s % 3600) / 60
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(m)m"
    }

    /// "resets in 2h 13m", "≈ resets in 40m", "reset", or nil when unknown.
    public static func reset(_ window: UsageWindow, now: Date) -> String? {
        if window.isReset { return "reset" }
        guard let r = window.resetsAt, r > now else { return nil }
        return (window.resetIsEstimate ? "≈ " : "") + "resets in " + countdown(r.timeIntervalSince(now))
    }

    /// Compact form for tight columns: "↻ 2h 13m", "≈↻ 40m", "reset".
    public static func shortReset(_ window: UsageWindow, now: Date) -> String? {
        if window.isReset { return "reset" }
        guard let r = window.resetsAt, r > now else { return nil }
        return (window.resetIsEstimate ? "≈" : "") + "↻ " + countdown(r.timeIntervalSince(now))
    }

    public static func percent(_ v: Double?) -> String {
        guard let v else { return "—" }
        return "\(Int(v.rounded()))%"
    }
}

public enum UsageLevel: Sendable, Equatable {
    case normal, elevated, high, critical

    public init(percent: Double?) {
        let p = percent ?? 0
        if p >= 100 { self = .critical } else if p >= 80 { self = .high } else if p >= 50 { self = .elevated } else { self = .normal }
    }
}

// MARK: - Peek events

public struct PeekEvent: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case attention, usage, finished

        public var priority: Int {
            switch self {
            case .attention: return 3
            case .usage: return 2
            case .finished: return 1
            }
        }

        public var duration: TimeInterval {
            switch self {
            case .attention: return 5
            case .usage: return 4
            case .finished: return 3
            }
        }
    }

    public var id: UUID
    /// Coalescing key, e.g. `attn:<session>`, `done:<session>`, `usage:<window>`.
    public var key: String
    public var kind: Kind
    public var provider: Provider
    public var lamp: LampColor
    public var title: String
    public var detail: String
    public var sessionID: String?
    public var createdAt: Date

    public init(key: String, kind: Kind, provider: Provider, lamp: LampColor, title: String, detail: String,
                sessionID: String?, createdAt: Date, id: UUID = UUID()) {
        self.id = id
        self.key = key
        self.kind = kind
        self.provider = provider
        self.lamp = lamp
        self.title = title
        self.detail = detail
        self.sessionID = sessionID
        self.createdAt = createdAt
    }
}

/// Turns snapshot changes into peek events. The first snapshot after launch never peeks.
public struct PeekEventDetector: Sendable {
    public var finishedMinimumTurn: TimeInterval = 20
    public var thresholds: [Double] = [80, 100]
    private var previous: [String: AgentSession] = [:]
    private var sessionsInitialized = false
    private var usageSeen: [String: Double] = [:]
    private var usageInitialized = false

    public init() {}

    public mutating func diff(sessions: [AgentSession], now: Date) -> [PeekEvent] {
        defer {
            previous = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
            sessionsInitialized = true
        }
        guard sessionsInitialized else { return [] }
        var events: [PeekEvent] = []
        for s in sessions {
            let prev = previous[s.id]
            let name = "\(s.provider.displayName) · \(s.project ?? s.title)"
            switch s.state {
            case let .needsAttention(reason):
                if prev?.state != s.state {
                    events.append(PeekEvent(key: "attn:\(s.id)", kind: .attention, provider: s.provider, lamp: .red,
                                            title: name, detail: Self.attentionDetail(reason, activity: s.activity),
                                            sessionID: s.id, createdAt: now))
                }
            case .waitingForUser:
                if let prev, prev.state == .working, now.timeIntervalSince(prev.stateSince) >= finishedMinimumTurn {
                    events.append(PeekEvent(key: "done:\(s.id)", kind: .finished, provider: s.provider, lamp: .yellow,
                                            title: "Done · \(s.project ?? s.title)", detail: s.provider.displayName,
                                            sessionID: s.id, createdAt: now))
                }
            case .working:
                break
            }
        }
        return events
    }

    static func attentionDetail(_ reason: AttentionReason, activity: String) -> String {
        switch reason {
        case let .approval(tool, _): return "needs approval" + (tool.map { " — \($0)" } ?? "")
        case let .question(h): return "has a question" + (h.map { " — \($0)" } ?? "")
        case .input: return activity
        case .error: return activity
        case .usageLimit: return "hit the usage limit"
        }
    }

    public mutating func diff(usage: UsageSnapshot, now: Date) -> [PeekEvent] {
        var events: [PeekEvent] = []
        for provider in Provider.allCases {
            for w in usage[provider].windows {
                guard let v = w.usedPercent else { continue }
                let key = "\(provider.rawValue):\(w.id)"
                let old = usageSeen[key]
                usageSeen[key] = v
                guard usageInitialized, let old else { continue }
                for t in thresholds where old < t && v >= t {
                    let reset = Formatters.reset(w, now: now).map { " · \($0)" } ?? ""
                    events.append(PeekEvent(key: "usage:\(key)", kind: .usage, provider: provider,
                                            lamp: t >= 100 ? .red : .yellow,
                                            title: "\(provider.displayName) \(w.label) at \(Int(t))%",
                                            detail: (t >= 100 ? "limit reached" : "usage is high") + reset,
                                            sessionID: nil, createdAt: now))
                }
            }
        }
        if !usage.claude.windows.isEmpty || !usage.codex.windows.isEmpty { usageInitialized = true }
        return events
    }
}

/// Priority queue of peeks with coalescing, preemption and hover-hold.
public struct PeekQueue: Sendable {
    public enum Effect: Sendable, Equatable {
        case none
        case show(PeekEvent)
        case hide
    }

    public private(set) var current: PeekEvent?
    public private(set) var shownAt: Date?
    public private(set) var deadline: Date?
    public private(set) var queued: [PeekEvent] = []
    public private(set) var isHeld = false
    private var heldRemaining: TimeInterval?

    public var maxQueued = 5
    public var maxQueueAge: TimeInterval = 30
    public var minimumShowBeforePreempt: TimeInterval = 1.2

    public init() {}

    public mutating func enqueue(_ e: PeekEvent, now: Date) -> Effect {
        if var cur = current, cur.key == e.key {
            cur.title = e.title
            cur.detail = e.detail
            current = cur
            if !isHeld { deadline = max(deadline ?? now, now.addingTimeInterval(2)) }
            return .show(cur)
        }
        queued.removeAll { $0.key == e.key }
        guard let cur = current else {
            return show(e, now: now)
        }
        let canPreempt = !isHeld && now.timeIntervalSince(shownAt ?? now) >= minimumShowBeforePreempt
        if e.kind.priority > cur.kind.priority && canPreempt {
            if cur.kind != .finished { insert(cur) }
            return show(e, now: now)
        }
        insert(e)
        return .none
    }

    /// The current peek's timer fired.
    public mutating func expire(now: Date) -> Effect {
        guard !isHeld, let d = deadline, now >= d.addingTimeInterval(-0.05) else { return .none }
        current = nil
        shownAt = nil
        deadline = nil
        while let next = queued.first {
            queued.removeFirst()
            if now.timeIntervalSince(next.createdAt) <= maxQueueAge { return show(next, now: now) }
        }
        return .hide
    }

    public mutating func hold(now: Date) {
        guard !isHeld, current != nil else { return }
        isHeld = true
        heldRemaining = deadline.map { max(0, $0.timeIntervalSince(now)) }
        deadline = nil
    }

    public mutating func release(now: Date) {
        guard isHeld else { return }
        isHeld = false
        if current != nil { deadline = now.addingTimeInterval(max(1.5, heldRemaining ?? 1.5)) }
        heldRemaining = nil
    }

    public mutating func clear() {
        current = nil
        shownAt = nil
        deadline = nil
        queued.removeAll()
        isHeld = false
        heldRemaining = nil
    }

    private mutating func show(_ e: PeekEvent, now: Date) -> Effect {
        current = e
        shownAt = now
        deadline = now.addingTimeInterval(e.kind.duration)
        return .show(e)
    }

    private mutating func insert(_ e: PeekEvent) {
        queued.append(e)
        queued.sort { a, b in
            a.kind.priority != b.kind.priority ? a.kind.priority > b.kind.priority : a.createdAt < b.createdAt
        }
        if queued.count > maxQueued { queued.removeLast(queued.count - maxQueued) }
    }
}
