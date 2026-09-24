import Foundation

public enum YellowLamp: Sendable, Hashable { case off, parked, fresh }

/// Which lamps of one agent's traffic light are lit, aggregated over its sessions.
public struct AgentLamps: Sendable, Hashable {
    public var provider: Provider
    public var green = false
    public var yellow = YellowLamp.off
    public var red = false
    public var working = 0
    public var waitingFresh = 0
    public var waitingParked = 0
    public var attention = 0

    public init(provider: Provider) { self.provider = provider }

    public var total: Int { working + waitingFresh + waitingParked + attention }
    public var isIdle: Bool { total == 0 }
}

public struct LampPolicy: Sendable, Hashable {
    /// A finished turn counts as "fresh" (bright yellow) for this long.
    public var freshWindow: TimeInterval

    public init(freshWindow: TimeInterval = 30 * 60) { self.freshWindow = freshWindow }
}

public enum Aggregator {
    public static func lamps(_ sessions: [AgentSession], now: Date, policy: LampPolicy = .init()) -> [Provider: AgentLamps] {
        var out: [Provider: AgentLamps] = [:]
        for p in Provider.allCases { out[p] = AgentLamps(provider: p) }
        for s in sessions {
            var l = out[s.provider] ?? AgentLamps(provider: s.provider)
            switch s.state {
            case .working: l.working += 1
            case .waitingForUser:
                if now.timeIntervalSince(s.stateSince) < policy.freshWindow { l.waitingFresh += 1 } else { l.waitingParked += 1 }
            case .needsAttention: l.attention += 1
            }
            out[s.provider] = l
        }
        for p in Provider.allCases {
            guard var l = out[p] else { continue }
            l.green = l.working > 0
            l.red = l.attention > 0
            l.yellow = l.waitingFresh > 0 ? .fresh : (l.waitingParked > 0 ? .parked : .off)
            out[p] = l
        }
        return out
    }

    /// Driver order: red (by reason, longest waiting first), fresh yellow (newest first),
    /// green (most recent change first), parked yellow (newest first).
    public static func ordered(_ sessions: [AgentSession], now: Date, policy: LampPolicy = .init()) -> [AgentSession] {
        func bucket(_ s: AgentSession) -> Int {
            switch s.state {
            case .needsAttention: return 0
            case .waitingForUser: return now.timeIntervalSince(s.stateSince) < policy.freshWindow ? 1 : 3
            case .working: return 2
            }
        }
        return sessions.sorted { a, b in
            let ba = bucket(a), bb = bucket(b)
            if ba != bb { return ba < bb }
            if case let .needsAttention(ra) = a.state, case let .needsAttention(rb) = b.state, ra.rank != rb.rank {
                return ra.rank < rb.rank
            }
            if a.stateSince != b.stateSince {
                // Red: longest waiting first. Others: most recent first.
                return ba == 0 ? a.stateSince < b.stateSince : a.stateSince > b.stateSince
            }
            if a.provider != b.provider { return a.provider.rawValue < b.provider.rawValue }
            if a.title != b.title { return a.title < b.title }
            return a.id < b.id
        }
    }
}

/// Holds transitions *into* yellow for a short grace period so quick busy→idle→busy flaps
/// (e.g. queued prompts) don't flash the lamp. Red and green publish immediately.
public struct StateSmoother: Sendable {
    public var holdInterval: TimeInterval
    private var published: [String: AgentSession] = [:]
    private var pendingSince: [String: Date] = [:]

    public init(holdInterval: TimeInterval = 1.5) { self.holdInterval = holdInterval }

    /// Returns the sessions to publish and, if something is being held, when to re-evaluate.
    public mutating func apply(_ raw: [AgentSession], now: Date) -> (sessions: [AgentSession], recheckAt: Date?) {
        var out: [AgentSession] = []
        var nextCheck: Date?
        var seen = Set<String>()
        for s in raw {
            seen.insert(s.id)
            let previous = published[s.id]
            let enteringYellow = s.state == .waitingForUser && previous != nil && previous?.state != .waitingForUser
            if enteringYellow, let previous {
                let since = pendingSince[s.id] ?? now
                pendingSince[s.id] = since
                if now.timeIntervalSince(since) < holdInterval {
                    out.append(previous)
                    let due = since.addingTimeInterval(holdInterval)
                    nextCheck = min(nextCheck ?? due, due)
                    continue
                }
            }
            pendingSince[s.id] = nil
            published[s.id] = s
            out.append(s)
        }
        for id in published.keys where !seen.contains(id) {
            published[id] = nil
            pendingSince[id] = nil
        }
        return (out, nextCheck)
    }
}
