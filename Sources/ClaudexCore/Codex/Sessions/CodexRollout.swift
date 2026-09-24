import Foundation

public struct CodexTurnError: Sendable, Hashable {
    public var message: String?
    /// Normalized `codex_error_info` ("usagelimitexceeded", "unauthorized", "other", …).
    public var info: String?

    public var isUsageLimit: Bool {
        guard let info else { return false }
        return info.contains("usagelimit") || info.contains("ratelimit")
    }
}

public struct RateWindowObservation: Sendable, Hashable {
    public var minutes: Double?
    public var usedPercent: Double?
    public var resetsAt: Date?
}

/// `token_count.rate_limits` (or an equivalent from wham/app-server).
public struct CodexRateLimits: Sendable, Hashable {
    public var limitID: String?
    public var planType: String?
    public var windows: [RateWindowObservation]
    public var reachedType: String?
}

public struct CodexSessionMeta: Sendable, Hashable {
    public var id: String?
    public var cwd: String?
    public var originator: String?
    public var source: String?
    public var cliVersion: String?
}

public enum CodexRecord: Sendable, Equatable {
    case taskStarted(turnID: String?, at: Date?)
    case taskComplete(turnID: String?, at: Date?, error: CodexTurnError?)
    case turnAborted(turnID: String?, at: Date?, reason: String?)
    case toolCall(callID: String, summary: ToolSummary, at: Date?)
    case toolOutput(callID: String, at: Date?)
    case activity(String, at: Date?)
    case reasoning(at: Date?)
    case agentMessage(at: Date?)
    case tokenCount(CodexRateLimits?, at: Date?)
    case turnContext(cwd: String?, approvalPolicy: String?, at: Date?)
    case sessionMeta(CodexSessionMeta, at: Date?)
    case legacyError(message: String?, at: Date?)
    case other(at: Date?)

    public var timestamp: Date? {
        switch self {
        case let .taskStarted(_, at), let .taskComplete(_, at, _), let .turnAborted(_, at, _),
             let .toolCall(_, _, at), let .toolOutput(_, at), let .activity(_, at), let .reasoning(at),
             let .agentMessage(at), let .tokenCount(_, at), let .turnContext(_, _, at), let .sessionMeta(_, at),
             let .legacyError(_, at), let .other(at):
            return at
        }
    }

    public var isTaskStarted: Bool {
        if case .taskStarted = self { return true }
        return false
    }
}

// MARK: - Decoding

private struct RawCodexLine: Decodable {
    var timestamp: String?
    var type: String?
    var payload: RawPayload?

    enum CodingKeys: String, CodingKey { case timestamp, type, payload }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = c.lenient(String.self, .timestamp)
        type = c.lenient(String.self, .type)
        payload = c.lenient(RawPayload.self, .payload)
    }
}

private struct RawPayload: Decodable {
    var type: String?
    var turnID: String?
    var startedAt: Double?
    var completedAt: Double?
    var error: JSONValue?
    var reason: String?
    var rateLimits: JSONValue?
    var name: String?
    var callID: String?
    var arguments: String?
    var input: String?
    var namespace: String?
    var action: JSONValue?
    var cwd: String?
    var approvalPolicy: String?
    var id: String?
    var originator: String?
    var source: JSONValue?
    var cliVersion: String?
    var message: String?
    var role: String?

    enum CodingKeys: String, CodingKey {
        case type, error, reason, name, arguments, input, namespace, action, cwd, id, originator, source, message, role
        case turnID = "turn_id"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case rateLimits = "rate_limits"
        case callID = "call_id"
        case approvalPolicy = "approval_policy"
        case cliVersion = "cli_version"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.lenient(String.self, .type)
        turnID = c.lenient(String.self, .turnID)
        startedAt = c.lenient(Double.self, .startedAt)
        completedAt = c.lenient(Double.self, .completedAt)
        error = c.lenient(JSONValue.self, .error)
        reason = c.lenient(String.self, .reason)
        rateLimits = c.lenient(JSONValue.self, .rateLimits)
        name = c.lenient(String.self, .name)
        callID = c.lenient(String.self, .callID)
        arguments = c.lenient(String.self, .arguments)
        input = c.lenient(String.self, .input)
        namespace = c.lenient(String.self, .namespace)
        action = c.lenient(JSONValue.self, .action)
        cwd = c.lenient(String.self, .cwd)
        approvalPolicy = c.lenient(String.self, .approvalPolicy)
        id = c.lenient(String.self, .id)
        originator = c.lenient(String.self, .originator)
        source = c.lenient(JSONValue.self, .source)
        cliVersion = c.lenient(String.self, .cliVersion)
        message = c.lenient(String.self, .message)
        role = c.lenient(String.self, .role)
    }
}

public enum CodexRecordDecoder {
    public static let maxLineBytes = 1 << 20

    public static func decode(_ line: JSONLine) -> CodexRecord {
        let bytes = line.bytes
        let head = bytes.prefix(4096)
        let kinds = JSONSniff.codexKinds(head)
        let at = JSONSniff.string("timestamp", in: head).flatMap(TimeParsing.iso8601)

        // Cheap paths: never fully decode bulky records.
        switch (kinds.type, kinds.payloadType) {
        case ("response_item", "reasoning"?):
            return .reasoning(at: at)
        case ("response_item", let p?) where p.hasSuffix("_output"):
            if let id = JSONSniff.string("call_id", in: bytes.prefix(16_384)) { return .toolOutput(callID: id, at: at) }
            return .other(at: at)
        case ("response_item", "message"?):
            let role = JSONSniff.string("role", in: bytes.prefix(8192))
            return role == "assistant" ? .agentMessage(at: at) : .other(at: at)
        case ("response_item", "web_search_call"?):
            return .activity("Searching the web", at: at)
        case ("response_item", "image_generation_call"?):
            return .activity("Generating an image", at: at)
        case ("event_msg", "item_completed"?):
            if let itemPos = JSONSniff.find(Array(#""item":"#.utf8), in: [UInt8](head), from: 0),
               let kind = JSONSniff.string("type", in: head, after: itemPos) {
                switch kind {
                case "ContextCompaction": return .activity("Compacting context…", at: at)
                case "Reasoning": return .reasoning(at: at)
                case "AgentMessage": return .agentMessage(at: at)
                default: return .other(at: at)
                }
            }
            return .other(at: at)
        case ("compacted", _), ("world_state", _), ("token_usage_record", _):
            return .other(at: at)
        default:
            break
        }

        guard case let .complete(data) = line,
              let raw = try? JSONDecoder().decode(RawCodexLine.self, from: data) else {
            return .other(at: at)
        }
        return map(raw, fallbackAt: at)
    }

    private static func map(_ raw: RawCodexLine, fallbackAt: Date?) -> CodexRecord {
        let at = raw.timestamp.flatMap(TimeParsing.iso8601) ?? fallbackAt
        guard let p = raw.payload else { return .other(at: at) }
        switch raw.type {
        case "event_msg":
            switch p.type {
            case "task_started":
                return .taskStarted(turnID: p.turnID, at: p.startedAt.flatMap(TimeParsing.epoch) ?? at)
            case "task_complete":
                return .taskComplete(turnID: p.turnID, at: p.completedAt.flatMap(TimeParsing.epoch) ?? at,
                                     error: turnError(p.error))
            case "turn_aborted":
                return .turnAborted(turnID: p.turnID, at: p.completedAt.flatMap(TimeParsing.epoch) ?? at, reason: p.reason)
            case "token_count":
                return .tokenCount(rateLimits(p.rateLimits), at: at)
            case "error", "stream_error":
                return .legacyError(message: p.message.map { TextSanitizer.oneLine($0, maxLength: 90) }, at: at)
            default:
                return .other(at: at)
            }
        case "response_item":
            switch p.type {
            case "function_call", "custom_tool_call":
                guard let callID = p.callID, let name = p.name else { return .other(at: at) }
                let summary = CodexActivity.summarize(name: name, namespace: p.namespace, arguments: p.arguments, input: p.input)
                return .toolCall(callID: callID, summary: summary, at: at)
            case "local_shell_call":
                guard let callID = p.callID ?? p.id else { return .other(at: at) }
                let command = p.action?["command"]?.array?.compactMap(\.string).last
                let summary = CodexActivity.shell(command)
                return .toolCall(callID: callID, summary: summary, at: at)
            default:
                return .other(at: at)
            }
        case "turn_context":
            return .turnContext(cwd: p.cwd, approvalPolicy: p.approvalPolicy, at: at)
        case "session_meta":
            let source: String? = p.source?.string ?? p.source?.object?.keys.sorted().first
            return .sessionMeta(CodexSessionMeta(id: p.id, cwd: p.cwd, originator: p.originator, source: source,
                                                 cliVersion: p.cliVersion), at: at)
        default:
            return .other(at: at)
        }
    }

    static func turnError(_ v: JSONValue?) -> CodexTurnError? {
        guard let v, !v.isNull else { return nil }
        if let s = v.string { return CodexTurnError(message: TextSanitizer.oneLine(s, maxLength: 90), info: nil) }
        let message = v["message"]?.string.map { TextSanitizer.oneLine($0, maxLength: 90) }
        var info: String?
        if let raw = v["codex_error_info"] ?? v["codexErrorInfo"] {
            if let s = raw.string {
                info = normalize(s)
            } else if let key = raw.object?.keys.sorted().first {
                info = normalize(key)
            }
        }
        return CodexTurnError(message: message, info: info)
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0 != "_" && $0 != "-" }
    }

    /// Parses the rollout/wham-style `rate_limits` object.
    public static func rateLimits(_ v: JSONValue?) -> CodexRateLimits? {
        guard let v, let obj = v.object else { return nil }
        func window(_ w: JSONValue?) -> RateWindowObservation? {
            guard let w, w.object != nil else { return nil }
            let minutes = w["window_minutes"]?.double ?? w["windowDurationMins"]?.double
                ?? w["limit_window_seconds"]?.double.map { $0 / 60 }
            let used = w["used_percent"]?.double ?? w["usedPercent"]?.double
            let resets = TimeParsing.flexible(w["resets_at"] ?? w["resetsAt"] ?? w["reset_at"])
            return RateWindowObservation(minutes: minutes, usedPercent: used, resetsAt: resets)
        }
        let windows = [window(obj["primary"]), window(obj["secondary"])].compactMap { $0 }
        let reached: String? = v["rate_limit_reached_type"]?.string ?? v["rate_limit_reached_type"]?["type"]?.string
        return CodexRateLimits(
            limitID: v["limit_id"]?.string ?? v["limitId"]?.string,
            planType: v["plan_type"]?.string ?? v["planType"]?.string,
            windows: windows,
            reachedType: reached
        )
    }
}

// MARK: - Reducer

public struct CodexThreadState: Sendable, Equatable {
    public enum Turn: Sendable, Equatable {
        case none
        case active(id: String?, startedAt: Date?)
        case completed(id: String?, at: Date?, error: CodexTurnError?)
        case aborted(id: String?, at: Date?, reason: String?)
    }

    public var turn: Turn = .none
    public var pending: [String: PendingTool] = [:]
    public var activity: String?
    public var lastEventAt: Date?
    public var approvalPolicy: String?
    public var meta: CodexSessionMeta?
    public var metaCwd: String?
    public var rateLimits: CodexRateLimits?
    public var rateLimitsAt: Date?

    public init() {}

    public mutating func apply(_ r: CodexRecord) {
        switch r {
        case let .taskStarted(id, at):
            turn = .active(id: id, startedAt: at)
            pending.removeAll()
            activity = "Thinking…"
        case let .taskComplete(id, at, error):
            turn = .completed(id: id, at: at, error: error)
            pending.removeAll()
            activity = nil
        case let .turnAborted(id, at, reason):
            turn = .aborted(id: id, at: at, reason: reason)
            pending.removeAll()
            activity = nil
        case let .toolCall(callID, summary, at):
            pending[callID] = PendingTool(id: callID, summary: summary, at: at)
            activity = summary.working
        case let .toolOutput(callID, _):
            pending[callID] = nil
            activity = latestPending?.summary.working ?? "Thinking…"
        case let .activity(text, _):
            activity = text
        case .reasoning:
            if pending.isEmpty { activity = "Thinking…" }
        case .agentMessage:
            if pending.isEmpty { activity = "Responding…" }
        case let .tokenCount(limits, at):
            if let limits {
                rateLimits = limits
                rateLimitsAt = at
            }
        case let .turnContext(cwd, policy, _):
            if let policy { approvalPolicy = policy }
            if let cwd { metaCwd = cwd }
        case let .sessionMeta(m, _):
            meta = m
            if metaCwd == nil { metaCwd = m.cwd }
        case let .legacyError(message, at):
            if case let .active(id, _) = turn {
                turn = .completed(id: id, at: at, error: CodexTurnError(message: message, info: nil))
                pending.removeAll()
            }
        case .other:
            break
        }
        if let ts = r.timestamp, ts > (lastEventAt ?? .distantPast) { lastEventAt = ts }
    }

    public var latestPending: PendingTool? {
        pending.values.max { ($0.at ?? .distantPast) < ($1.at ?? .distantPast) }
    }

    public var pendingQuestion: PendingTool? {
        pending.values.filter { $0.summary.name == "request_user_input" }
            .max { ($0.at ?? .distantPast) < ($1.at ?? .distantPast) }
    }

    public var isActive: Bool {
        if case .active = turn { return true }
        return false
    }
}
