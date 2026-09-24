import Foundation

/// Summary of a tool call for display.
public struct ToolSummary: Sendable, Hashable {
    public var name: String
    /// Short argument (command, file name, pattern, host) for approval prompts.
    public var detail: String?
    /// Activity line while the tool runs, e.g. "Running Bash: npm test".
    public var working: String
    /// For AskUserQuestion: the first question's header.
    public var questionHeader: String?
}

public struct PendingTool: Sendable, Hashable {
    public var id: String
    public var summary: ToolSummary
    public var at: Date?
}

public struct TerminalError: Sendable, Hashable {
    public var at: Date?
    public var category: String?
    public var text: String?
}

public struct RetryInfo: Sendable, Hashable {
    public var at: Date?
    public var message: String?
    public var attempt: Int?
    public var maxAttempts: Int?
    public var retryInMs: Double?
}

/// A decoded transcript line, reduced to what status derivation needs.
public enum ClaudeRecord: Sendable, Equatable {
    case userPrompt(at: Date?, isInterrupt: Bool)
    case toolResults(ids: [String], at: Date?)
    case assistant(AssistantPart)
    case apiRetry(RetryInfo)
    case title(kind: TitleKind, value: String)
    case sidechain
    case other(at: Date?)

    public enum TitleKind: Sendable, Hashable { case custom, agent, ai }

    public struct AssistantPart: Sendable, Equatable {
        public var at: Date?
        public var messageID: String?
        public var stopReason: String?
        public var toolUses: [PendingTool]
        public var isApiError: Bool
        public var errorCategory: String?
        public var errorText: String?
    }

    public var timestamp: Date? {
        switch self {
        case let .userPrompt(at, _): return at
        case let .toolResults(_, at): return at
        case let .assistant(p): return p.at
        case let .apiRetry(r): return r.at
        case let .other(at): return at
        case .title, .sidechain: return nil
        }
    }

    /// A real user turn start (used as the backward-scan stop marker).
    public var isTurnStart: Bool {
        if case let .userPrompt(_, isInterrupt) = self { return !isInterrupt }
        return false
    }
}

// MARK: - Decoding

private struct RawLine: Decodable {
    var type: String?
    var subtype: String?
    var timestamp: String?
    var isSidechain: Bool?
    var isMeta: Bool?
    var isCompactSummary: Bool?
    var isApiErrorMessage: Bool?
    var error: JSONValue?
    var message: RawMessage?
    var retryAttempt: Int?
    var maxRetries: Int?
    var retryInMs: Double?
    var customTitle: String?
    var agentName: String?
    var aiTitle: String?

    enum CodingKeys: String, CodingKey {
        case type, subtype, timestamp, isSidechain, isMeta, isCompactSummary, isApiErrorMessage, error, message
        case retryAttempt, maxRetries, retryInMs, customTitle, agentName, aiTitle
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.lenient(String.self, .type)
        subtype = c.lenient(String.self, .subtype)
        timestamp = c.lenient(String.self, .timestamp)
        isSidechain = c.lenient(Bool.self, .isSidechain)
        isMeta = c.lenient(Bool.self, .isMeta)
        isCompactSummary = c.lenient(Bool.self, .isCompactSummary)
        isApiErrorMessage = c.lenient(Bool.self, .isApiErrorMessage)
        error = c.lenient(JSONValue.self, .error)
        message = c.lenient(RawMessage.self, .message)
        retryAttempt = c.lenient(Int.self, .retryAttempt)
        maxRetries = c.lenient(Int.self, .maxRetries)
        retryInMs = c.lenient(Double.self, .retryInMs)
        customTitle = c.lenient(String.self, .customTitle)
        agentName = c.lenient(String.self, .agentName)
        aiTitle = c.lenient(String.self, .aiTitle)
    }
}

private struct RawMessage: Decodable {
    var id: String?
    var model: String?
    var stopReason: String?
    var content: RawContent?

    enum CodingKeys: String, CodingKey {
        case id, model, content
        case stopReason = "stop_reason"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(String.self, .id)
        model = c.lenient(String.self, .model)
        stopReason = c.lenient(String.self, .stopReason)
        content = c.lenient(RawContent.self, .content)
    }
}

private enum RawContent: Decodable {
    case text(String)
    case blocks([RawBlock])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .text(s); return }
        self = .blocks((try? c.decode([RawBlock].self)) ?? [])
    }
}

private struct RawBlock: Decodable {
    var type: String?
    var id: String?
    var name: String?
    var input: JSONValue?
    var toolUseID: String?
    var text: String?

    enum CodingKeys: String, CodingKey {
        case type, id, name, input, text
        case toolUseID = "tool_use_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.lenient(String.self, .type)
        id = c.lenient(String.self, .id)
        name = c.lenient(String.self, .name)
        toolUseID = c.lenient(String.self, .toolUseID)
        text = c.lenient(String.self, .text)
        // Only tool_use blocks need their (possibly large) input.
        input = type == "tool_use" ? c.lenient(JSONValue.self, .input) : nil
    }
}

public enum ClaudeRecordDecoder {
    public static let maxLineBytes = 2 << 20

    public static func decode(_ line: JSONLine) -> ClaudeRecord {
        switch line {
        case let .complete(data):
            guard let raw = try? JSONDecoder().decode(RawLine.self, from: data) else { return .other(at: nil) }
            return map(raw)
        case let .oversize(prefix, _):
            return sniff(prefix)
        }
    }

    private static func map(_ raw: RawLine) -> ClaudeRecord {
        let at = raw.timestamp.flatMap(TimeParsing.iso8601)
        if raw.isSidechain == true { return .sidechain }
        switch raw.type {
        case "user":
            if raw.isMeta == true || raw.isCompactSummary == true { return .other(at: at) }
            switch raw.message?.content {
            case let .text(s)?:
                return .userPrompt(at: at, isInterrupt: isInterruptMarker(s))
            case let .blocks(blocks)?:
                let ids = blocks.compactMap { $0.type == "tool_result" ? $0.toolUseID : nil }
                if !ids.isEmpty { return .toolResults(ids: ids, at: at) }
                let texts = blocks.compactMap { $0.type == "text" ? $0.text : nil }
                if texts.isEmpty { return .other(at: at) }
                return .userPrompt(at: at, isInterrupt: texts.contains(where: isInterruptMarker))
            case nil:
                return .other(at: at)
            }

        case "assistant":
            var tools: [PendingTool] = []
            var text: String?
            if case let .blocks(blocks)? = raw.message?.content {
                for b in blocks {
                    if b.type == "tool_use", let id = b.id, let name = b.name {
                        tools.append(PendingTool(id: id, summary: ClaudeActivity.summarize(name: name, input: b.input), at: at))
                    } else if b.type == "text", let t = b.text, text == nil {
                        text = t
                    }
                }
            }
            let isError = raw.isApiErrorMessage == true || raw.message?.model == "<synthetic>" && raw.error != nil
            return .assistant(.init(
                at: at,
                messageID: raw.message?.id,
                stopReason: raw.message?.stopReason,
                toolUses: tools,
                isApiError: isError,
                errorCategory: isError ? raw.error?.string : nil,
                errorText: isError ? text.map { TextSanitizer.oneLine($0, maxLength: 90) } : nil
            ))

        case "system" where raw.subtype == "api_error":
            let message = raw.error?["formatted"]?.string ?? raw.error?["message"]?.string ?? raw.error?.string
            return .apiRetry(RetryInfo(
                at: at,
                message: message.map { TextSanitizer.oneLine($0, maxLength: 70) },
                attempt: raw.retryAttempt,
                maxAttempts: raw.maxRetries,
                retryInMs: raw.retryInMs
            ))

        case "custom-title":
            if let t = raw.customTitle, !t.isEmpty { return .title(kind: .custom, value: t) }
            return .other(at: nil)
        case "agent-name":
            if let t = raw.agentName, !t.isEmpty { return .title(kind: .agent, value: t) }
            return .other(at: nil)
        case "ai-title":
            if let t = raw.aiTitle, !t.isEmpty { return .title(kind: .ai, value: t) }
            return .other(at: nil)

        default:
            return .other(at: at)
        }
    }

    static func isInterruptMarker(_ s: String) -> Bool {
        s.hasPrefix("[Request interrupted by user")
    }

    /// Oversize lines are almost always huge tool results (or tool calls with huge input).
    private static func sniff(_ prefix: Data) -> ClaudeRecord {
        if let id = JSONSniff.string("tool_use_id", in: prefix) {
            return .toolResults(ids: [id], at: nil)
        }
        let bytes = [UInt8](prefix)
        if let pos = JSONSniff.find(Array(#""type":"tool_use""#.utf8), in: bytes, from: 0),
           let id = JSONSniff.string("id", in: prefix, after: pos),
           let name = JSONSniff.string("name", in: prefix, after: pos) {
            let tool = PendingTool(id: id, summary: ClaudeActivity.summarize(name: name, input: nil), at: nil)
            return .assistant(.init(at: nil, messageID: nil, stopReason: "tool_use", toolUses: [tool],
                                    isApiError: false, errorCategory: nil, errorText: nil))
        }
        return .other(at: nil)
    }
}

// MARK: - Reducer

public struct ClaudeTranscriptState: Sendable, Equatable {
    public var lastPromptAt: Date?
    public var lastAssistantAt: Date?
    public var lastStopReason: String?
    public var lastMessageID: String?
    public var lastMessageHasToolUse = false
    public var pending: [String: PendingTool] = [:]
    public var terminalError: TerminalError?
    public var lastRetry: RetryInfo?
    public var interruptedAt: Date?
    public var lastRecordAt: Date?
    public var titles: [ClaudeRecord.TitleKind: String] = [:]
    public var sawTurnStart = false
    private var resolved: [String] = []   // bounded FIFO of resolved tool ids

    public init() {}

    public mutating func apply(_ record: ClaudeRecord) {
        switch record {
        case .sidechain:
            return
        case let .userPrompt(at, isInterrupt):
            if isInterrupt {
                interruptedAt = at ?? interruptedAt
                pending.removeAll()
                break
            }
            if let at, let last = lastPromptAt, at < last { break }   // out of order
            lastPromptAt = at ?? lastPromptAt
            sawTurnStart = true
            pending.removeAll()
            lastRetry = nil
            interruptedAt = nil
            if let e = terminalError, let at, (e.at ?? .distantPast) <= at { terminalError = nil }
        case let .toolResults(ids, _):
            for id in ids {
                pending[id] = nil
                markResolved(id)
            }
        case let .assistant(p):
            if p.isApiError {
                terminalError = TerminalError(at: p.at, category: p.errorCategory, text: p.errorText)
                break
            }
            if p.at.map({ $0 >= (lastAssistantAt ?? .distantPast) }) ?? true {
                lastAssistantAt = p.at ?? lastAssistantAt
                if let s = p.stopReason { lastStopReason = s }
                if p.messageID == nil || p.messageID != lastMessageID {
                    lastMessageID = p.messageID
                    lastMessageHasToolUse = !p.toolUses.isEmpty
                } else if !p.toolUses.isEmpty {
                    lastMessageHasToolUse = true
                }
            }
            for t in p.toolUses where !resolved.contains(t.id) {
                pending[t.id] = t
            }
            if let e = terminalError, let at = p.at, let eat = e.at, at > eat { terminalError = nil }
        case let .apiRetry(info):
            lastRetry = info
        case let .title(kind, value):
            titles[kind] = value
        case .other:
            break
        }
        if let ts = record.timestamp, ts > (lastRecordAt ?? .distantPast) { lastRecordAt = ts }
    }

    private mutating func markResolved(_ id: String) {
        resolved.append(id)
        if resolved.count > 512 { resolved.removeFirst(resolved.count - 512) }
    }

    public var latestPending: PendingTool? {
        pending.values.max { ($0.at ?? .distantPast) < ($1.at ?? .distantPast) }
    }

    /// When the latest turn ended cleanly (no pending tools, final stop reason).
    public var turnEndedAt: Date? {
        guard pending.isEmpty, let a = lastAssistantAt, a >= (lastPromptAt ?? .distantPast),
              !lastMessageHasToolUse,
              ["end_turn", "stop_sequence", "max_tokens", "refusal"].contains(lastStopReason ?? "")
        else { return nil }
        return a
    }

    /// A terminal API error that belongs to the current turn.
    public var currentTurnError: TerminalError? {
        guard let e = terminalError else { return nil }
        if let at = e.at, let p = lastPromptAt, at < p { return nil }
        return e
    }

    public var bestTitle: String? {
        titles[.custom] ?? titles[.agent] ?? titles[.ai]
    }
}
