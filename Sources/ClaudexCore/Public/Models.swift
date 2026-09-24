import Foundation

public enum Provider: String, Sendable, Hashable, CaseIterable, Codable {
    case claude, codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    /// Bundle identifier of the provider's desktop app.
    public var desktopBundleID: String {
        switch self {
        case .claude: return "com.anthropic.claudefordesktop"
        case .codex: return "com.openai.codex"
        }
    }
}

public enum SessionOrigin: Sendable, Hashable {
    case desktop, terminal, ide, background, sdk
    case other(String)

    public var badge: String {
        switch self {
        case .desktop: return "Desktop"
        case .terminal: return "Terminal"
        case .ide: return "IDE"
        case .background: return "Background"
        case .sdk: return "SDK"
        case let .other(raw): return raw.isEmpty ? "Other" : raw
        }
    }
}

public enum AttentionReason: Sendable, Hashable {
    /// A permission / approval prompt (tool call, plan, sandbox, worker).
    case approval(tool: String?, detail: String?)
    /// The agent asked the user a question (AskUserQuestion, request_user_input).
    case question(String?)
    /// Some other input is needed (dialog open, input needed).
    case input(String?)
    /// The turn ended in an error.
    case error(String?)
    /// The plan's usage limit was hit.
    case usageLimit

    /// Lower is more urgent.
    public var rank: Int {
        switch self {
        case .approval: return 0
        case .question: return 1
        case .input: return 2
        case .error: return 3
        case .usageLimit: return 4
        }
    }
}

public enum LampColor: String, Sendable, Hashable, CaseIterable {
    case red, yellow, green
}

public enum SessionState: Sendable, Hashable {
    case working
    case waitingForUser
    case needsAttention(AttentionReason)

    public var lamp: LampColor {
        switch self {
        case .working: return .green
        case .waitingForUser: return .yellow
        case .needsAttention: return .red
        }
    }
}

public enum Confidence: Sendable, Hashable {
    /// Reported directly by the tool (e.g. Claude's session registry).
    case reported
    /// Inferred from logs/heuristics.
    case inferred
}

public enum WaitingFreshness: Sendable, Hashable { case fresh, parked }

public struct AgentSession: Sendable, Hashable, Identifiable {
    /// Stable id, e.g. `claude:<sessionId>#<pid>` or `codex:<threadId>`.
    public var id: String
    public var provider: Provider
    public var state: SessionState
    /// When the current state began; always derived from data so elapsed timers are stable.
    public var stateSince: Date
    /// One line, redacted, ≤100 characters.
    public var activity: String
    public var title: String
    /// Basename of the working directory.
    public var project: String?
    public var cwd: String?
    public var origin: SessionOrigin
    /// The agent process (Claude CLI, or the Codex app-server/TUI that has the thread loaded).
    public var pid: Int32?
    /// Bundle id of the desktop app to activate, when the session lives in one.
    public var appBundleID: String?
    public var lastEventAt: Date?
    public var confidence: Confidence

    public init(
        id: String, provider: Provider, state: SessionState, stateSince: Date, activity: String,
        title: String, project: String?, cwd: String?, origin: SessionOrigin, pid: Int32?,
        appBundleID: String?, lastEventAt: Date?, confidence: Confidence
    ) {
        self.id = id
        self.provider = provider
        self.state = state
        self.stateSince = stateSince
        self.activity = activity
        self.title = title
        self.project = project
        self.cwd = cwd
        self.origin = origin
        self.pid = pid
        self.appBundleID = appBundleID
        self.lastEventAt = lastEventAt
        self.confidence = confidence
    }

    public func freshness(now: Date, window: TimeInterval) -> WaitingFreshness? {
        guard case .waitingForUser = state else { return nil }
        return now.timeIntervalSince(stateSince) < window ? .fresh : .parked
    }
}

public enum SourceID: String, Sendable, Hashable, CaseIterable {
    case claudeSessions, codexSessions
}

public enum SourceHealth: Sendable, Hashable {
    case ok
    case notInstalled
    case degraded(String)
}

public struct SessionSnapshot: Sendable, Equatable {
    public var generatedAt: Date
    public var sessions: [AgentSession]
    public var health: [SourceID: SourceHealth]

    public init(generatedAt: Date, sessions: [AgentSession], health: [SourceID: SourceHealth] = [:]) {
        self.generatedAt = generatedAt
        self.sessions = sessions
        self.health = health
    }

    public static let empty = SessionSnapshot(generatedAt: .distantPast, sessions: [])

    public func sessions(for provider: Provider) -> [AgentSession] {
        sessions.filter { $0.provider == provider }
    }
}

/// A batch of sessions from one provider's source.
public struct ProviderSessions: Sendable, Equatable {
    public var provider: Provider
    public var sessions: [AgentSession]
    public var health: SourceHealth

    public init(provider: Provider, sessions: [AgentSession], health: SourceHealth) {
        self.provider = provider
        self.sessions = sessions
        self.health = health
    }
}
