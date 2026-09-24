import Foundation

public enum ClaudeActivity {
    /// Builds the display summary for a Claude Code tool call.
    public static func summarize(name: String, input: JSONValue?) -> ToolSummary {
        func s(_ key: String) -> String? {
            guard let v = input?[key]?.string, !v.isEmpty else { return nil }
            return v
        }
        func clean(_ text: String?, _ max: Int = 60) -> String? {
            guard let text, !text.isEmpty else { return nil }
            let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            let out = TextSanitizer.oneLine(firstLine, maxLength: max)
            return out.isEmpty ? nil : out
        }
        func file(_ key: String) -> String? { s(key).map(Paths.basename) }

        switch name {
        case "Bash":
            let command = clean(s("command"))
            let label = clean(s("description"), 70) ?? command
            return ToolSummary(name: name, detail: command, working: "Running Bash" + (label.map { ": \($0)" } ?? ""))
        case "BashOutput", "KillShell", "KillBash":
            return ToolSummary(name: name, detail: nil, working: "Checking background shell")
        case "Read":
            let f = file("file_path")
            return ToolSummary(name: name, detail: f, working: "Reading" + (f.map { " \($0)" } ?? " file"))
        case "Write":
            let f = file("file_path")
            return ToolSummary(name: name, detail: f, working: "Writing" + (f.map { " \($0)" } ?? " file"))
        case "Edit", "MultiEdit":
            let f = file("file_path")
            return ToolSummary(name: name, detail: f, working: "Editing" + (f.map { " \($0)" } ?? " file"))
        case "NotebookEdit":
            let f = file("notebook_path") ?? file("file_path")
            return ToolSummary(name: name, detail: f, working: "Editing" + (f.map { " \($0)" } ?? " notebook"))
        case "Grep":
            let p = clean(s("pattern"), 40)
            return ToolSummary(name: name, detail: p, working: "Searching" + (p.map { " '\($0)'" } ?? ""))
        case "Glob":
            let p = clean(s("pattern"), 40)
            return ToolSummary(name: name, detail: p, working: "Finding files" + (p.map { " '\($0)'" } ?? ""))
        case "WebFetch":
            let host = s("url").flatMap { URL(string: $0)?.host } ?? clean(s("url"), 40)
            return ToolSummary(name: name, detail: host, working: "Fetching" + (host.map { " \($0)" } ?? " a page"))
        case "WebSearch":
            let q = clean(s("query"), 50)
            return ToolSummary(name: name, detail: q, working: "Searching the web" + (q.map { ": \($0)" } ?? ""))
        case "Task", "Agent":
            let d = clean(s("description"), 60) ?? clean(s("subagent_type"), 40)
            return ToolSummary(name: name, detail: d, working: "Running agent" + (d.map { ": \($0)" } ?? ""))
        case "TodoWrite":
            return ToolSummary(name: name, detail: nil, working: "Updating todos")
        case "AskUserQuestion":
            let q = input?["questions"]?[0]
            let header = clean(q?["header"]?.string, 50) ?? clean(q?["question"]?.string, 60)
            return ToolSummary(name: name, detail: header, working: "Asking a question", questionHeader: header)
        case "ExitPlanMode":
            return ToolSummary(name: name, detail: "plan", working: "Plan ready for review")
        case "EnterPlanMode":
            return ToolSummary(name: name, detail: nil, working: "Planning")
        case "Skill":
            let skill = clean(s("skill") ?? s("command") ?? s("name"), 40)
            return ToolSummary(name: name, detail: skill, working: "Using skill" + (skill.map { " \($0)" } ?? ""))
        default:
            if name.hasPrefix("mcp__") {
                let parts = name.dropFirst(5).components(separatedBy: "__")
                let server = parts.first.map { String($0.prefix(30)) } ?? "server"
                let tool = parts.dropFirst().joined(separator: "__")
                return ToolSummary(name: name, detail: tool.isEmpty ? nil : tool,
                                   working: "MCP \(server)" + (tool.isEmpty ? "" : " · \(tool)"))
            }
            return ToolSummary(name: name, detail: nil, working: "Running \(TextSanitizer.oneLine(name, maxLength: 40))")
        }
    }

    /// Display name for a tool in approval prompts ("mcp__github__create_issue" → "github · create_issue").
    public static func displayName(_ tool: String) -> String {
        guard tool.hasPrefix("mcp__") else { return tool }
        let parts = tool.dropFirst(5).components(separatedBy: "__")
        return parts.joined(separator: " · ")
    }
}

/// Maps Claude's `waitingFor` strings to attention reasons.
public enum AttentionMapper {
    public static func map(_ waitingFor: String?, pending: PendingTool?) -> AttentionReason {
        let w = (waitingFor ?? "").trimmingCharacters(in: .whitespaces)
        let pendingName = pending?.summary.name
        switch w.lowercased() {
        case "":
            if let p = pending {
                if p.summary.name == "AskUserQuestion" { return .question(p.summary.questionHeader) }
                return .approval(tool: ClaudeActivity.displayName(p.summary.name), detail: p.summary.detail)
            }
            return .input(nil)
        case "permission prompt":
            if pendingName == "AskUserQuestion" { return .question(pending?.summary.questionHeader) }
            if pendingName == "ExitPlanMode" { return .approval(tool: "Plan", detail: nil) }
            return .approval(tool: pendingName.map(ClaudeActivity.displayName), detail: pending?.summary.detail)
        case "approve plan":
            return .approval(tool: "Plan", detail: nil)
        case "input needed":
            if pendingName == "AskUserQuestion" { return .question(pending?.summary.questionHeader) }
            return .input("Input needed")
        case "dialog open":
            return .input("Dialog open")
        case "sandbox request":
            return .approval(tool: "Sandbox", detail: "network access")
        case "worker request":
            return .approval(tool: "Worker", detail: nil)
        default:
            if w.lowercased().hasPrefix("approve ") {
                let rest = String(w.dropFirst("approve ".count))
                let parts = rest.split(separator: ":", maxSplits: 1)
                let tool = parts.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? rest
                if tool == "AskUserQuestion" { return .question(pending?.summary.questionHeader) }
                let detail = parts.count > 1
                    ? TextSanitizer.oneLine(String(parts[1]), maxLength: 60)
                    : pending?.summary.detail
                return .approval(tool: ClaudeActivity.displayName(tool), detail: detail)
            }
            return .input(TextSanitizer.oneLine(w, maxLength: 60))
        }
    }

    /// Activity line for a red state.
    public static func text(_ reason: AttentionReason) -> String {
        switch reason {
        case let .approval(tool, detail):
            let t = tool ?? "tool"
            return "Needs approval · \(t)" + (detail.map { ": \($0)" } ?? "")
        case let .question(header):
            return "Question: " + (header ?? "waiting for your answer")
        case let .input(text):
            return text ?? "Needs input"
        case let .error(text):
            return "Error: " + (text ?? "the turn failed")
        case .usageLimit:
            return "Usage limit reached"
        }
    }
}
