import Foundation

public enum CodexActivity {
    public static func summarize(name: String, namespace: String?, arguments: String?, input: String?) -> ToolSummary {
        let args = arguments.flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }

        if let ns = namespace, ns.hasPrefix("mcp__") || ns.hasPrefix("mcp:") {
            let server = String(ns.dropFirst(5).prefix(30))
            return ToolSummary(name: name, detail: name, working: "MCP \(server) · \(name)")
        }
        if name.hasPrefix("mcp__") {
            let parts = name.dropFirst(5).components(separatedBy: "__")
            let tool = parts.dropFirst().joined(separator: "__")
            return ToolSummary(name: name, detail: tool, working: "MCP \(parts.first ?? "") · \(tool)")
        }

        switch name {
        case "exec":
            return exec(input)
        case "exec_command", "shell", "container.exec", "local_shell":
            let cmd = args?["cmd"]?.string
                ?? args?["command"]?.string
                ?? args?["command"]?.array?.compactMap(\.string).last
            return shell(cmd)
        case "write_stdin", "wait":
            return ToolSummary(name: name, detail: nil, working: "Waiting on command output")
        case "apply_patch":
            let file = patchFile(input ?? args?["input"]?.string ?? arguments)
            return ToolSummary(name: name, detail: file, working: "Editing" + (file.map { " \($0)" } ?? " files"))
        case "update_plan":
            return ToolSummary(name: name, detail: nil, working: "Updating plan")
        case "view_image":
            return ToolSummary(name: name, detail: nil, working: "Viewing an image")
        case "request_user_input":
            let q = args?["questions"]?[0]
            let header = (q?["header"]?.string ?? q?["question"]?.string).map { TextSanitizer.oneLine($0, maxLength: 50) }
            return ToolSummary(name: name, detail: header, working: "Asking a question", questionHeader: header)
        case "web_search", "web.run", "search":
            return ToolSummary(name: name, detail: nil, working: "Searching the web")
        default:
            return ToolSummary(name: name, detail: nil, working: "Running \(TextSanitizer.oneLine(name, maxLength: 40))")
        }
    }

    public static func shell(_ command: String?) -> ToolSummary {
        let cmd = command.map { clean($0) }
        return ToolSummary(name: "shell", detail: cmd, working: "Running" + (cmd.map { ": \($0)" } ?? " a command"))
    }

    /// Code-mode `exec`: JavaScript that calls `tools.exec_command({"cmd": …})`, applies a
    /// patch, or runs arbitrary code.
    static func exec(_ input: String?) -> ToolSummary {
        guard let input else { return ToolSummary(name: "exec", detail: nil, working: "Running code") }
        if input.contains("*** Begin Patch") {
            let file = patchFile(input)
            return ToolSummary(name: "exec", detail: file, working: "Editing" + (file.map { " \($0)" } ?? " files"))
        }
        if let range = input.range(of: "exec_command(") {
            let rest = Data(input[range.upperBound...].prefix(4096).utf8)
            if let cmd = JSONSniff.string("cmd", in: rest) {
                let c = clean(cmd)
                return ToolSummary(name: "exec", detail: c, working: "Running: \(c)")
            }
        }
        return ToolSummary(name: "exec", detail: nil, working: "Running code")
    }

    static func patchFile(_ patch: String?) -> String? {
        guard let patch else { return nil }
        for marker in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] {
            if let r = patch.range(of: marker) {
                let line = patch[r.upperBound...].prefix { $0 != "\n" && $0 != "\\" && $0 != "\"" }
                let name = Paths.basename(String(line).trimmingCharacters(in: .whitespaces))
                if !name.isEmpty { return name }
            }
        }
        return nil
    }

    static func clean(_ command: String) -> String {
        let firstLine = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? command
        return TextSanitizer.oneLine(firstLine, maxLength: 70)
    }
}

/// Everything about a loaded Codex thread needed for derivation.
public struct CodexThreadContext: Sendable, Equatable {
    public var ownerPID: Int32?
    public var ownerStart: Date?
    public var lockBirth: Date?
    public var loaded: Bool
    public var confidence: Confidence

    public init(ownerPID: Int32?, ownerStart: Date?, lockBirth: Date?, loaded: Bool, confidence: Confidence) {
        self.ownerPID = ownerPID
        self.ownerStart = ownerStart
        self.lockBirth = lockBirth
        self.loaded = loaded
        self.confidence = confidence
    }
}

public enum CodexStateDeriver {
    public static let quietNote: TimeInterval = 15 * 60
    public static let staleTurn: TimeInterval = 2 * 3600

    public static func derive(_ s: CodexThreadState, context c: CodexThreadContext, fallbackSince: Date, now: Date) -> DerivedState {
        switch s.turn {
        case let .active(_, startedAt):
            let started = startedAt ?? s.lastEventAt ?? fallbackSince
            if let q = s.pendingQuestion {
                let reason = AttentionReason.question(q.summary.questionHeader)
                return .init(state: .needsAttention(reason), activity: AttentionMapper.text(reason),
                             since: q.at ?? started, confidence: .reported)
            }
            if let ownerStart = c.ownerStart, ownerStart > started.addingTimeInterval(5) {
                return .init(state: .waitingForUser, activity: "Interrupted (app restarted)",
                             since: s.lastEventAt ?? started, confidence: .inferred)
            }
            if let birth = c.lockBirth, birth > started.addingTimeInterval(5), !c.loaded {
                return .init(state: .waitingForUser, activity: "Interrupted",
                             since: s.lastEventAt ?? started, confidence: .inferred)
            }
            let quiet = now.timeIntervalSince(s.lastEventAt ?? started)
            if quiet > staleTurn {
                return .init(state: .waitingForUser, activity: "No activity for \(Durations.short(quiet)) — turn may be stuck",
                             since: s.lastEventAt ?? started, confidence: .inferred)
            }
            var text = s.activity ?? "Working…"
            if quiet > quietNote { text += " · quiet \(Durations.short(quiet))" }
            return .init(state: .working, activity: text, since: started, confidence: c.confidence)

        case let .completed(_, at, error?):
            let reason: AttentionReason = error.isUsageLimit ? .usageLimit : .error(error.message)
            return .init(state: .needsAttention(reason), activity: AttentionMapper.text(reason),
                         since: at ?? s.lastEventAt ?? fallbackSince, confidence: .reported)
        case let .completed(_, at, nil):
            return .init(state: .waitingForUser, activity: "Waiting for you",
                         since: at ?? s.lastEventAt ?? fallbackSince, confidence: .reported)
        case let .aborted(_, at, _):
            return .init(state: .waitingForUser, activity: "Interrupted",
                         since: at ?? s.lastEventAt ?? fallbackSince, confidence: .reported)
        case .none:
            return .init(state: .waitingForUser, activity: "New thread",
                         since: c.lockBirth ?? s.lastEventAt ?? fallbackSince, confidence: .inferred)
        }
    }

    public static func origin(meta: CodexSessionMeta?, ownerAppPath: String?) -> SessionOrigin {
        if let app = ownerAppPath {
            if app.hasSuffix("/ChatGPT.app") || app.hasSuffix("/Codex.app") { return .desktop }
            if app.contains("Visual Studio Code") || app.hasSuffix("/Cursor.app") || app.hasSuffix("/Windsurf.app") {
                return .ide
            }
        }
        let originator = meta?.originator?.lowercased() ?? ""
        let source = meta?.source?.lowercased() ?? ""
        if originator.contains("desktop") { return .desktop }
        if source == "exec" || originator.contains("exec") { return .background }
        if source == "vscode" { return .ide }
        if source == "cli" || originator.contains("cli") { return .terminal }
        return ownerAppPath == nil ? .terminal : .other(Paths.basename(ownerAppPath!))
    }
}

public enum Durations {
    /// "45s", "12m", "3h", "2d".
    public static func short(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }
}
