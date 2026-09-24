import Foundation

public enum UsageSource: String, Sendable, Hashable {
    case claudeOAuthAPI, claudeDesktopCache, codexWham, codexAppServer, codexRollout, demo

    public var displayName: String {
        switch self {
        case .claudeOAuthAPI: return "Anthropic API"
        case .claudeDesktopCache: return "Claude app"
        case .codexWham: return "ChatGPT API"
        case .codexAppServer: return "Codex app-server"
        case .codexRollout: return "Codex logs"
        case .demo: return "Demo"
        }
    }
}

public enum WindowKind: Sendable, Hashable {
    case session5h
    case weekly
    case weeklyScoped(String)
    case other(String)
}

public struct UsageWindow: Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: WindowKind
    /// Short label: "5h", "Weekly", "Weekly · Opus".
    public var label: String
    /// 0…100; nil when the source has no value for this window.
    public var usedPercent: Double?
    public var resetsAt: Date?
    public var windowDuration: TimeInterval?
    public var source: UsageSource
    /// When the value was observed (sample time, response time, or log record time).
    public var fetchedAt: Date
    /// The window has reset since the value was observed (value shown as 0 %).
    public var isReset: Bool
    /// `resetsAt` was estimated from sampled history rather than reported.
    public var resetIsEstimate: Bool

    public init(
        id: String, kind: WindowKind, label: String, usedPercent: Double?, resetsAt: Date?,
        windowDuration: TimeInterval?, source: UsageSource, fetchedAt: Date, isReset: Bool = false,
        resetIsEstimate: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.windowDuration = windowDuration
        self.source = source
        self.fetchedAt = fetchedAt
        self.isReset = isReset
        self.resetIsEstimate = resetIsEstimate
    }

    /// Applies the reset rule: if the window has already reset, report 0 %.
    public func resolved(now: Date) -> UsageWindow {
        guard let r = resetsAt, r <= now, fetchedAt < r else { return self }
        var copy = self
        copy.usedPercent = 0
        copy.isReset = true
        copy.resetsAt = nil
        copy.resetIsEstimate = false
        return copy
    }

    /// Fraction 0…1 for rings and bars.
    public var fraction: Double? { usedPercent.map { min(max($0 / 100, 0), 1) } }
}

public enum UsageStatus: Sendable, Hashable {
    case loading
    case ok
    case stale(since: Date)
    case unavailable(String)
}

public struct ProviderUsage: Sendable, Hashable {
    public var provider: Provider
    public var plan: String?
    public var windows: [UsageWindow]
    public var limitReached: Bool
    public var status: UsageStatus
    public var lastSuccessAt: Date?

    public init(provider: Provider, plan: String? = nil, windows: [UsageWindow] = [], limitReached: Bool = false,
                status: UsageStatus = .loading, lastSuccessAt: Date? = nil) {
        self.provider = provider
        self.plan = plan
        self.windows = windows
        self.limitReached = limitReached
        self.status = status
        self.lastSuccessAt = lastSuccessAt
    }

    /// The window closest to its limit (drives the ring around the glyph).
    public var mostConstrained: UsageWindow? {
        windows.filter { $0.usedPercent != nil }.max { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) }
    }

    public var isAtLimit: Bool { limitReached || (mostConstrained?.usedPercent ?? 0) >= 100 }
}

public struct UsageSnapshot: Sendable, Equatable {
    public var claude: ProviderUsage
    public var codex: ProviderUsage
    public var generatedAt: Date

    public init(claude: ProviderUsage, codex: ProviderUsage, generatedAt: Date) {
        self.claude = claude
        self.codex = codex
        self.generatedAt = generatedAt
    }

    public static let empty = UsageSnapshot(
        claude: ProviderUsage(provider: .claude), codex: ProviderUsage(provider: .codex), generatedAt: .distantPast)

    public subscript(provider: Provider) -> ProviderUsage {
        provider == .claude ? claude : codex
    }
}

public enum WindowLabeler {
    public static func kind(minutes: Double) -> WindowKind {
        if abs(minutes - 300) < 1 { return .session5h }
        if abs(minutes - 10_080) < 1 { return .weekly }
        return .other(label(minutes: minutes))
    }

    public static func label(minutes: Double) -> String {
        if abs(minutes - 300) < 1 { return "5h" }
        if abs(minutes - 10_080) < 1 { return "Weekly" }
        if abs(minutes - 1440) < 1 { return "Daily" }
        if minutes >= 1440, minutes.truncatingRemainder(dividingBy: 1440) < 1 { return "\(Int(minutes / 1440))d" }
        if minutes >= 60 { return "\(Int((minutes / 60).rounded()))h" }
        return "\(Int(minutes))m"
    }

    /// Sort order for display: 5h, weekly, weekly-scoped, others.
    public static func order(_ kind: WindowKind) -> Int {
        switch kind {
        case .session5h: return 0
        case .weekly: return 1
        case .weeklyScoped: return 2
        case .other: return 3
        }
    }
}
