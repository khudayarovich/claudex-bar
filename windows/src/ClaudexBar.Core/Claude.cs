using System.Text.Json.Nodes;

namespace ClaudexBar.Core;

public sealed record ClaudePaths(string Home, string DesktopSupport, string AccountFile)
{
    public static ClaudePaths Standard()
    {
        var user = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var home = Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR") is { Length: > 0 } dir ? dir : Path.Combine(user, ".claude");
        string desktop = OperatingSystem.IsWindows()
            ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Claude")
            : Path.Combine(user, "Library", "Application Support", "Claude");
        return new ClaudePaths(home, desktop, Path.Combine(user, ".claude.json"));
    }

    public string SessionsDir => Path.Combine(Home, "sessions");
    public string ProjectsDir => Path.Combine(Home, "projects");
    public string CredentialsFile => Path.Combine(Home, ".credentials.json");
    public string PlanUsageHistory => Path.Combine(DesktopSupport, "plan-usage-history.json");
}

// MARK: - Registry

public enum ClaudeStatus { Busy, Shell, Idle, Waiting, Unknown }

public enum ClaudeKind { Interactive, Bg, Daemon, DaemonWorker, Unknown }

/// <summary>One ~/.claude/sessions/&lt;pid&gt;.json entry, decoded leniently.</summary>
public sealed record ClaudeRegistryEntry
{
    public int? Pid { get; init; }
    public string? SessionId { get; init; }
    public string? Cwd { get; init; }
    public double? StartedAt { get; init; }
    public string? ProcStart { get; init; }
    public string? Version { get; init; }
    public ClaudeKind? Kind { get; init; }
    public string? Entrypoint { get; init; }
    public string? Name { get; init; }
    public ClaudeStatus? Status { get; init; }
    public string? StatusRaw { get; init; }
    public string? WaitingFor { get; init; }
    public double? UpdatedAt { get; init; }
    public double? StatusUpdatedAt { get; init; }
    public string? PidDomain { get; init; }
    public bool? Spare { get; init; }
    public string? State { get; init; }
    public string? Detail { get; init; }
    public string? Tempo { get; init; }
    public string? Needs { get; init; }

    private static double? Ts(double? v) => v is { } d && double.IsFinite(d) && d > 0 && d < 4e15 ? d : null;

    public static DateTimeOffset? FromMs(double? ms) => ms is { } v ? DateTimeOffset.FromUnixTimeMilliseconds((long)v) : null;

    public static ClaudeRegistryEntry? Parse(byte[] data)
    {
        if (Json.Parse(data) is not JsonObject o) return null;
        var pid = o["pid"].AsNum();
        var statusRaw = o.Str("status");
        return new ClaudeRegistryEntry
        {
            Pid = pid is { } p && p > 0 && p < int.MaxValue && o["pid"] is JsonValue pv && !pv.TryGetValue<string>(out _) ? (int)p : null,
            SessionId = o.Str("sessionId"),
            Cwd = o.Str("cwd"),
            StartedAt = Ts(o["startedAt"] is JsonValue sv && !sv.TryGetValue<string>(out _) ? o.Num("startedAt") : null),
            ProcStart = o.Str("procStart"),
            Version = o.Str("version"),
            Kind = o.Str("kind") switch
            {
                null => null,
                "interactive" => ClaudeKind.Interactive,
                "bg" or "background" => ClaudeKind.Bg,
                "daemon" => ClaudeKind.Daemon,
                "daemon-worker" => ClaudeKind.DaemonWorker,
                _ => ClaudeKind.Unknown,
            },
            Entrypoint = o.Str("entrypoint"),
            Name = o.Str("name"),
            StatusRaw = statusRaw,
            Status = statusRaw switch
            {
                null => null,
                "busy" => ClaudeStatus.Busy,
                "shell" => ClaudeStatus.Shell,
                "idle" => ClaudeStatus.Idle,
                "waiting" => ClaudeStatus.Waiting,
                _ => ClaudeStatus.Unknown,
            },
            WaitingFor = o.Str("waitingFor"),
            UpdatedAt = Ts(o.Num("updatedAt")),
            StatusUpdatedAt = Ts(o.Num("statusUpdatedAt")),
            PidDomain = o.Str("pidDomain"),
            Spare = o.Bool("spare"),
            State = o.Str("state"),
            Detail = o.Str("detail"),
            Tempo = o.Str("tempo"),
            Needs = o.Str("needs"),
        };
    }

    /// <summary>Hide daemons, pre-warmed spares, SDK sessions, and other OS domains (e.g. WSL).</summary>
    public bool IsDisplayable
    {
        get
        {
            if (Spare == true) return false;
            if (PidDomain is { } d && (d.StartsWith("linux", StringComparison.OrdinalIgnoreCase) || (!OperatingSystem.IsWindows() && d != "darwin")))
                return false;
            if (Kind is ClaudeKind.Daemon or ClaudeKind.DaemonWorker or ClaudeKind.Unknown) return false;
            if (Entrypoint is { } e && e.StartsWith("sdk-", StringComparison.Ordinal)) return false;
            return true;
        }
    }

    public SessionOrigin Origin
    {
        get
        {
            if (Kind == ClaudeKind.Bg) return SessionOrigin.Background;
            return Entrypoint switch
            {
                "claude-desktop" or "local-agent" => SessionOrigin.Desktop,
                { } e when e.StartsWith("claude-coworker", StringComparison.Ordinal) =>
                    e.EndsWith("-terminal", StringComparison.Ordinal) ? SessionOrigin.Terminal : SessionOrigin.Desktop,
                "cli" or null => SessionOrigin.Terminal,
                "claude-vscode" => SessionOrigin.Ide,
                { } e when e.StartsWith("sdk-", StringComparison.Ordinal) => SessionOrigin.Sdk,
                { } e => new SessionOrigin(OriginKind.Other, e),
            };
        }
    }
}

public sealed class ClaudeRegistryReader
{
    public const int MaxFileBytes = 262_144;
    private readonly Dictionary<string, (FileStat Stat, ClaudeRegistryEntry Entry)> _cache = [];
    public HashSet<string> TornNames { get; } = [];

    public sealed record Item(ClaudeRegistryEntry Entry, DateTimeOffset Modified);

    public static bool IsRegistryName(string name)
    {
        if (!name.EndsWith(".json", StringComparison.Ordinal)) return false;
        var stem = name[..^5];
        return stem.Length > 0 && stem[0] != '0' && stem.All(char.IsAsciiDigit) && int.TryParse(stem, out var v) && v.ToString() == stem;
    }

    /// <summary>Parseable entries by file name. Never opens the secret *.key files.</summary>
    public Dictionary<string, Item> Scan(string dir)
    {
        var result = new Dictionary<string, Item>();
        TornNames.Clear();
        var live = new HashSet<string>();
        foreach (var name in FileReading.List(dir).Where(IsRegistryName))
        {
            live.Add(name);
            var path = Path.Combine(dir, name);
            if (FileReading.Stat(path) is not { IsDirectory: false } st || st.Size > MaxFileBytes) continue;
            if (_cache.TryGetValue(name, out var cached) && cached.Stat == st)
            {
                result[name] = new Item(cached.Entry, st.Modified);
                continue;
            }
            var data = FileReading.ReadAll(path, MaxFileBytes);
            if (data is not null && ClaudeRegistryEntry.Parse(data) is { } entry)
            {
                _cache[name] = (st, entry);
                result[name] = new Item(entry, st.Modified);
            }
            else
            {
                TornNames.Add(name);
                if (_cache.TryGetValue(name, out var prev)) result[name] = new Item(prev.Entry, prev.Stat.Modified);
            }
        }
        foreach (var gone in _cache.Keys.Where(k => !live.Contains(k)).ToList()) _cache.Remove(gone);
        return result;
    }
}

public static class ClaudeLiveness
{
    public static bool IsAlive(ClaudeRegistryEntry e, IProcessInspector inspector)
    {
        if (e.Pid is not { } pid || !inspector.IsAlive(pid)) return false;
        var kernelStart = inspector.StartTime(pid);
        if (TimeParsing.ProcStart(e.ProcStart) is { } parsed)
        {
            if (kernelStart is null) return true;
            return Math.Abs(Math.Floor(kernelStart.Value.ToUnixTimeMilliseconds() / 1000.0) - parsed.ToUnixTimeSeconds()) <= 1;
        }
        if (ClaudeRegistryEntry.FromMs(e.StartedAt) is { } started && kernelStart is { } ks)
            return ks <= started.AddSeconds(2) && started - ks < TimeSpan.FromSeconds(120);
        return true;
    }
}

// MARK: - Transcript

public sealed record ToolSummary(string Name, string? Detail, string Working, string? QuestionHeader = null);

public sealed record PendingTool(string Id, ToolSummary Summary, DateTimeOffset? At);

public sealed record TerminalError(DateTimeOffset? At, string? Category, string? Text);

public sealed record RetryInfo(DateTimeOffset? At, string? Message, int? Attempt, int? MaxAttempts, double? RetryInMs);

public enum TitleKind { Custom, Agent, Ai }

public abstract record ClaudeRecord
{
    public sealed record UserPrompt(DateTimeOffset? At, bool IsInterrupt) : ClaudeRecord;
    public sealed record ToolResults(List<string> Ids, DateTimeOffset? At) : ClaudeRecord;
    public sealed record Assistant(DateTimeOffset? At, string? MessageId, string? StopReason, List<PendingTool> ToolUses,
        bool IsApiError, string? ErrorCategory, string? ErrorText) : ClaudeRecord;
    public sealed record ApiRetry(RetryInfo Info) : ClaudeRecord;
    public sealed record Title(TitleKind Kind, string Value) : ClaudeRecord;
    public sealed record Sidechain : ClaudeRecord;
    public sealed record Other(DateTimeOffset? At) : ClaudeRecord;

    public DateTimeOffset? Timestamp => this switch
    {
        UserPrompt u => u.At,
        ToolResults t => t.At,
        Assistant a => a.At,
        ApiRetry r => r.Info.At,
        Other o => o.At,
        _ => null,
    };

    public bool IsTurnStart => this is UserPrompt { IsInterrupt: false };
}

public static class ClaudeRecordDecoder
{
    public const int MaxLineBytes = 2 << 20;

    public static ClaudeRecord Decode(JsonLine line)
    {
        if (line.IsOversize) return Sniff(line.Bytes);
        if (Json.Parse(line.Bytes) is not JsonObject o) return new ClaudeRecord.Other(null);
        var at = TimeParsing.Iso8601(o.Str("timestamp"));
        if (o.Bool("isSidechain") == true) return new ClaudeRecord.Sidechain();
        switch (o.Str("type"))
        {
            case "user":
            {
                if (o.Bool("isMeta") == true || o.Bool("isCompactSummary") == true) return new ClaudeRecord.Other(at);
                var content = o.Get("message").Get("content");
                if (content.AsStr() is { } text) return new ClaudeRecord.UserPrompt(at, IsInterrupt(text));
                if (content is JsonArray blocks)
                {
                    var ids = blocks.Where(b => b.Str("type") == "tool_result").Select(b => b.Str("tool_use_id")).OfType<string>().ToList();
                    if (ids.Count > 0) return new ClaudeRecord.ToolResults(ids, at);
                    var texts = blocks.Where(b => b.Str("type") == "text").Select(b => b.Str("text")).OfType<string>().ToList();
                    return texts.Count == 0 ? new ClaudeRecord.Other(at) : new ClaudeRecord.UserPrompt(at, texts.Any(IsInterrupt));
                }
                return new ClaudeRecord.Other(at);
            }
            case "assistant":
            {
                var message = o.Get("message");
                var tools = new List<PendingTool>();
                string? firstText = null;
                if (message.Get("content") is JsonArray blocks)
                {
                    foreach (var b in blocks)
                    {
                        var type = b.Str("type");
                        if (type == "tool_use" && b.Str("id") is { } id && b.Str("name") is { } name)
                            tools.Add(new PendingTool(id, ClaudeActivity.Summarize(name, b.Get("input")), at));
                        else if (type == "text" && firstText is null)
                            firstText = b.Str("text");
                    }
                }
                bool isError = o.Bool("isApiErrorMessage") == true || (message.Str("model") == "<synthetic>" && o["error"] is not null);
                return new ClaudeRecord.Assistant(at, message.Str("id"), message.Str("stop_reason"), tools, isError,
                    isError ? o["error"].AsStr() : null, isError && firstText is not null ? TextSanitizer.OneLine(firstText, 90) : null);
            }
            case "system" when o.Str("subtype") == "api_error":
            {
                var err = o["error"];
                var msg = err.Str("formatted") ?? err.Str("message") ?? err.AsStr();
                return new ClaudeRecord.ApiRetry(new RetryInfo(at, msg is null ? null : TextSanitizer.OneLine(msg, 70),
                    (int?)o.Num("retryAttempt"), (int?)o.Num("maxRetries"), o.Num("retryInMs")));
            }
            case "custom-title" when o.Str("customTitle") is { Length: > 0 } t: return new ClaudeRecord.Title(TitleKind.Custom, t);
            case "agent-name" when o.Str("agentName") is { Length: > 0 } t: return new ClaudeRecord.Title(TitleKind.Agent, t);
            case "ai-title" when o.Str("aiTitle") is { Length: > 0 } t: return new ClaudeRecord.Title(TitleKind.Ai, t);
            default: return new ClaudeRecord.Other(at);
        }
    }

    public static bool IsInterrupt(string s) => s.StartsWith("[Request interrupted by user", StringComparison.Ordinal);

    private static ClaudeRecord Sniff(byte[] prefix)
    {
        if (JsonSniff.String("tool_use_id", prefix) is { } id) return new ClaudeRecord.ToolResults([id], null);
        int pos = JsonSniff.Find(prefix, "\"type\":\"tool_use\""u8);
        if (pos >= 0 && JsonSniff.String("id", prefix, pos) is { } toolId && JsonSniff.String("name", prefix, pos) is { } name)
            return new ClaudeRecord.Assistant(null, null, "tool_use",
                [new PendingTool(toolId, ClaudeActivity.Summarize(name, null), null)], false, null, null);
        return new ClaudeRecord.Other(null);
    }
}

public sealed class ClaudeTranscriptState
{
    public DateTimeOffset? LastPromptAt { get; private set; }
    public DateTimeOffset? LastAssistantAt { get; private set; }
    public string? LastStopReason { get; private set; }
    public string? LastMessageId { get; private set; }
    public bool LastMessageHasToolUse { get; private set; }
    public Dictionary<string, PendingTool> Pending { get; } = [];
    public TerminalError? Error { get; private set; }
    public RetryInfo? LastRetry { get; private set; }
    public DateTimeOffset? InterruptedAt { get; private set; }
    public DateTimeOffset? LastRecordAt { get; private set; }
    public Dictionary<TitleKind, string> Titles { get; } = [];
    public bool SawTurnStart { get; private set; }
    private readonly Queue<string> _resolvedOrder = new();
    private readonly HashSet<string> _resolved = [];

    public void Apply(ClaudeRecord record)
    {
        switch (record)
        {
            case ClaudeRecord.Sidechain:
                return;
            case ClaudeRecord.UserPrompt { IsInterrupt: true } u:
                InterruptedAt = u.At ?? InterruptedAt;
                Pending.Clear();
                break;
            case ClaudeRecord.UserPrompt u:
                if (u.At is { } at && LastPromptAt is { } last && at < last) break;
                LastPromptAt = u.At ?? LastPromptAt;
                SawTurnStart = true;
                Pending.Clear();
                LastRetry = null;
                InterruptedAt = null;
                if (Error is { } e && u.At is { } promptAt && (e.At ?? DateTimeOffset.MinValue) <= promptAt) Error = null;
                break;
            case ClaudeRecord.ToolResults t:
                foreach (var id in t.Ids)
                {
                    Pending.Remove(id);
                    if (_resolved.Add(id))
                    {
                        _resolvedOrder.Enqueue(id);
                        if (_resolvedOrder.Count > 512) _resolved.Remove(_resolvedOrder.Dequeue());
                    }
                }
                break;
            case ClaudeRecord.Assistant a when a.IsApiError:
                Error = new TerminalError(a.At, a.ErrorCategory, a.ErrorText);
                break;
            case ClaudeRecord.Assistant a:
                if (a.At is null || a.At >= (LastAssistantAt ?? DateTimeOffset.MinValue))
                {
                    LastAssistantAt = a.At ?? LastAssistantAt;
                    if (a.StopReason is not null) LastStopReason = a.StopReason;
                    if (a.MessageId is null || a.MessageId != LastMessageId)
                    {
                        LastMessageId = a.MessageId;
                        LastMessageHasToolUse = a.ToolUses.Count > 0;
                    }
                    else if (a.ToolUses.Count > 0) LastMessageHasToolUse = true;
                }
                foreach (var t in a.ToolUses.Where(t => !_resolved.Contains(t.Id))) Pending[t.Id] = t;
                if (Error is { At: { } eat } && a.At is { } aat && aat > eat) Error = null;
                break;
            case ClaudeRecord.ApiRetry r:
                LastRetry = r.Info;
                break;
            case ClaudeRecord.Title t:
                Titles[t.Kind] = t.Value;
                break;
        }
        if (record.Timestamp is { } ts && ts > (LastRecordAt ?? DateTimeOffset.MinValue)) LastRecordAt = ts;
    }

    public PendingTool? LatestPending => Pending.Values.OrderByDescending(p => p.At ?? DateTimeOffset.MinValue).FirstOrDefault();

    public DateTimeOffset? TurnEndedAt =>
        Pending.Count == 0 && LastAssistantAt is { } a && a >= (LastPromptAt ?? DateTimeOffset.MinValue) && !LastMessageHasToolUse
        && LastStopReason is "end_turn" or "stop_sequence" or "max_tokens" or "refusal"
            ? a
            : null;

    public TerminalError? CurrentTurnError =>
        Error is { } e && !(e.At is { } at && LastPromptAt is { } p && at < p) ? e : null;

    public string? BestTitle =>
        Titles.TryGetValue(TitleKind.Custom, out var c) ? c
        : Titles.TryGetValue(TitleKind.Agent, out var a) ? a
        : Titles.TryGetValue(TitleKind.Ai, out var i) ? i : null;
}

public static class ClaudeActivity
{
    public static ToolSummary Summarize(string name, JsonNode? input)
    {
        string? S(string key) => input.Str(key) is { Length: > 0 } v ? v : null;
        string? Clean(string? text, int max = 60)
        {
            if (string.IsNullOrEmpty(text)) return null;
            var first = text.Split(['\n', '\r'], StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? text;
            var outText = TextSanitizer.OneLine(first, max);
            return outText.Length == 0 ? null : outText;
        }
        string? File(string key) => S(key) is { } p ? PathUtil.BaseName(p) : null;

        switch (name)
        {
            case "Bash":
            {
                var command = Clean(S("command"));
                var label = Clean(S("description"), 70) ?? command;
                return new ToolSummary(name, command, "Running Bash" + (label is null ? "" : $": {label}"));
            }
            case "BashOutput" or "KillShell" or "KillBash":
                return new ToolSummary(name, null, "Checking background shell");
            case "Read":
                return new ToolSummary(name, File("file_path"), "Reading " + (File("file_path") ?? "file"));
            case "Write":
                return new ToolSummary(name, File("file_path"), "Writing " + (File("file_path") ?? "file"));
            case "Edit" or "MultiEdit":
                return new ToolSummary(name, File("file_path"), "Editing " + (File("file_path") ?? "file"));
            case "NotebookEdit":
            {
                var f = File("notebook_path") ?? File("file_path");
                return new ToolSummary(name, f, "Editing " + (f ?? "notebook"));
            }
            case "Grep":
            {
                var p = Clean(S("pattern"), 40);
                return new ToolSummary(name, p, "Searching" + (p is null ? "" : $" '{p}'"));
            }
            case "Glob":
            {
                var p = Clean(S("pattern"), 40);
                return new ToolSummary(name, p, "Finding files" + (p is null ? "" : $" '{p}'"));
            }
            case "WebFetch":
            {
                var host = Uri.TryCreate(S("url"), UriKind.Absolute, out var u) ? u.Host : Clean(S("url"), 40);
                return new ToolSummary(name, host, "Fetching " + (host ?? "a page"));
            }
            case "WebSearch":
            {
                var q = Clean(S("query"), 50);
                return new ToolSummary(name, q, "Searching the web" + (q is null ? "" : $": {q}"));
            }
            case "Task" or "Agent":
            {
                var d = Clean(S("description"), 60) ?? Clean(S("subagent_type"), 40);
                return new ToolSummary(name, d, "Running agent" + (d is null ? "" : $": {d}"));
            }
            case "TodoWrite":
                return new ToolSummary(name, null, "Updating todos");
            case "AskUserQuestion":
            {
                var q = input.Arr("questions").At(0);
                var header = Clean(q.Str("header"), 50) ?? Clean(q.Str("question"), 60);
                return new ToolSummary(name, header, "Asking a question", header);
            }
            case "ExitPlanMode":
                return new ToolSummary(name, "plan", "Plan ready for review");
            case "EnterPlanMode":
                return new ToolSummary(name, null, "Planning");
            case "Skill":
            {
                var skill = Clean(S("skill") ?? S("command") ?? S("name"), 40);
                return new ToolSummary(name, skill, "Using skill" + (skill is null ? "" : $" {skill}"));
            }
            default:
                if (name.StartsWith("mcp__", StringComparison.Ordinal))
                {
                    var parts = name[5..].Split("__");
                    var server = parts[0].Length > 30 ? parts[0][..30] : parts[0];
                    var tool = string.Join("__", parts.Skip(1));
                    return new ToolSummary(name, tool.Length == 0 ? null : tool, $"MCP {server}" + (tool.Length == 0 ? "" : $" · {tool}"));
                }
                return new ToolSummary(name, null, $"Running {TextSanitizer.OneLine(name, 40)}");
        }
    }

    public static string DisplayName(string tool) =>
        tool.StartsWith("mcp__", StringComparison.Ordinal) ? string.Join(" · ", tool[5..].Split("__")) : tool;
}

public static class AttentionMapper
{
    public static AttentionReason Map(string? waitingFor, PendingTool? pending)
    {
        var w = (waitingFor ?? "").Trim();
        var pendingName = pending?.Summary.Name;
        switch (w.ToLowerInvariant())
        {
            case "":
                if (pending is { } p)
                    return p.Summary.Name == "AskUserQuestion"
                        ? AttentionReason.Question(p.Summary.QuestionHeader)
                        : AttentionReason.Approval(ClaudeActivity.DisplayName(p.Summary.Name), p.Summary.Detail);
                return AttentionReason.Input(null);
            case "permission prompt":
                if (pendingName == "AskUserQuestion") return AttentionReason.Question(pending!.Summary.QuestionHeader);
                if (pendingName == "ExitPlanMode") return AttentionReason.Approval("Plan", null);
                return AttentionReason.Approval(pendingName is null ? null : ClaudeActivity.DisplayName(pendingName), pending?.Summary.Detail);
            case "approve plan":
                return AttentionReason.Approval("Plan", null);
            case "input needed":
                return pendingName == "AskUserQuestion"
                    ? AttentionReason.Question(pending!.Summary.QuestionHeader)
                    : AttentionReason.Input("Input needed");
            case "dialog open":
                return AttentionReason.Input("Dialog open");
            case "sandbox request":
                return AttentionReason.Approval("Sandbox", "network access");
            case "worker request":
                return AttentionReason.Approval("Worker", null);
            default:
                if (w.StartsWith("approve ", StringComparison.OrdinalIgnoreCase))
                {
                    var rest = w["approve ".Length..];
                    int colon = rest.IndexOf(':');
                    var tool = (colon >= 0 ? rest[..colon] : rest).Trim();
                    if (tool == "AskUserQuestion") return AttentionReason.Question(pending?.Summary.QuestionHeader);
                    var detail = colon >= 0 ? TextSanitizer.OneLine(rest[(colon + 1)..], 60) : pending?.Summary.Detail;
                    return AttentionReason.Approval(ClaudeActivity.DisplayName(tool), detail);
                }
                return AttentionReason.Input(TextSanitizer.OneLine(w, 60));
        }
    }

    public static string Text(AttentionReason r) => r.Kind switch
    {
        AttentionKind.Approval => $"Needs approval · {r.Tool ?? "tool"}" + (r.Detail is null ? "" : $": {r.Detail}"),
        AttentionKind.Question => "Question: " + (r.Detail ?? "waiting for your answer"),
        AttentionKind.Input => r.Detail ?? "Needs input",
        AttentionKind.Error => "Error: " + (r.Detail ?? "the turn failed"),
        _ => "Usage limit reached",
    };
}

public sealed record DerivedState(SessionState State, string Activity, DateTimeOffset Since, Confidence Confidence);

public static class ClaudeStateDeriver
{
    public static readonly TimeSpan BusyDemoteGrace = TimeSpan.FromSeconds(60);

    public static DerivedState Derive(ClaudeRegistryEntry e, ClaudeTranscriptState? t, DateTimeOffset? registryModified, DateTimeOffset now)
    {
        var since = ClaudeRegistryEntry.FromMs(e.StatusUpdatedAt ?? e.UpdatedAt) ?? registryModified
                    ?? ClaudeRegistryEntry.FromMs(e.StartedAt) ?? now;
        var pending = t?.LatestPending;

        if (e.Kind == ClaudeKind.Bg)
        {
            var detail = e.Detail ?? e.Needs;
            detail = detail is null ? null : TextSanitizer.OneLine(detail, 80);
            var state = e.State?.ToLowerInvariant();
            var tempo = e.Tempo?.ToLowerInvariant();
            if (state == "failed")
                return new(SessionState.Attention(AttentionReason.Error(detail)), AttentionMapper.Text(AttentionReason.Error(detail)), since, Confidence.Reported);
            if (state == "blocked" || tempo == "blocked")
            {
                var r = AttentionReason.Input(e.Needs is null ? detail : TextSanitizer.OneLine(e.Needs, 80));
                return new(SessionState.Attention(r), AttentionMapper.Text(r), since, Confidence.Reported);
            }
            if (state == "working" || tempo == "active")
                return new(SessionState.Working, detail ?? pending?.Summary.Working ?? "Working in background", since, Confidence.Reported);
            if (state == "done") return new(SessionState.WaitingForUser, "Finished", since, Confidence.Reported);
            if (state == "stopped") return new(SessionState.WaitingForUser, "Stopped", since, Confidence.Reported);
        }

        switch (e.Status)
        {
            case ClaudeStatus.Waiting:
            {
                var reason = AttentionMapper.Map(e.WaitingFor, pending);
                return new(SessionState.Attention(reason), AttentionMapper.Text(reason), since, Confidence.Reported);
            }
            case ClaudeStatus.Busy:
            {
                if (t is not null && t.TurnEndedAt is { } ended && t.Pending.Count == 0 && now - ended >= BusyDemoteGrace
                    && ended >= since.AddSeconds(-1))
                    return new(SessionState.WaitingForUser, "Background task running", ended, Confidence.Inferred);
                if (t?.LastRetry is { At: { } rat } r
                    && rat >= Max(t.LastAssistantAt, t.LastPromptAt)
                    && now - rat < TimeSpan.FromSeconds((r.RetryInMs ?? 0) / 1000 + 30))
                {
                    var text = "Retrying";
                    if (r.Attempt is { } a && r.MaxAttempts is { } m) text += $" ({a}/{m})";
                    if (r.Message is { } msg) text += $": {msg}";
                    return new(SessionState.Working, text, since, Confidence.Reported);
                }
                var activity = pending?.Summary.Working ?? (t?.LastPromptAt is not null ? "Thinking…" : "Working…");
                return new(SessionState.Working, activity, since, Confidence.Reported);
            }
            case ClaudeStatus.Shell:
                return new(SessionState.WaitingForUser, "Background shell running", since, Confidence.Reported);
            case ClaudeStatus.Idle:
            {
                if (t?.CurrentTurnError is { } err)
                {
                    var reason = err.Category == "rate_limit" ? AttentionReason.UsageLimit : AttentionReason.Error(err.Text);
                    return new(SessionState.Attention(reason), AttentionMapper.Text(reason), err.At ?? since, Confidence.Reported);
                }
                var idleSince = since;
                if (ClaudeRegistryEntry.FromMs(e.StartedAt) is { } started && Math.Abs((since - started).TotalSeconds) < 5)
                    idleSince = t?.TurnEndedAt ?? t?.LastRecordAt ?? since;
                bool interrupted = t?.InterruptedAt is { } ia && ia >= (t.LastAssistantAt ?? DateTimeOffset.MinValue);
                return new(SessionState.WaitingForUser, interrupted ? "Interrupted" : "Waiting for you", idleSince, Confidence.Reported);
            }
            default:
            {
                if (t?.CurrentTurnError is { } err)
                {
                    var reason = err.Category == "rate_limit" ? AttentionReason.UsageLimit : AttentionReason.Error(err.Text);
                    return new(SessionState.Attention(reason), AttentionMapper.Text(reason), err.At ?? since, Confidence.Inferred);
                }
                if (pending is not null && t?.LastRecordAt is { } last && now - last < TimeSpan.FromMinutes(10))
                    return new(SessionState.Working, pending.Summary.Working, pending.At ?? since, Confidence.Inferred);
                return new(SessionState.WaitingForUser, "Waiting for you", t?.TurnEndedAt ?? t?.LastRecordAt ?? since, Confidence.Inferred);
            }
        }
    }

    private static DateTimeOffset Max(DateTimeOffset? a, DateTimeOffset? b) =>
        (a ?? DateTimeOffset.MinValue) > (b ?? DateTimeOffset.MinValue) ? a ?? DateTimeOffset.MinValue : b ?? DateTimeOffset.MinValue;

    public static string Title(ClaudeRegistryEntry e, ClaudeTranscriptState? t)
    {
        foreach (var c in new[] { e.Name, t?.BestTitle, e.Cwd is null ? null : PathUtil.BaseName(e.Cwd) })
            if (!string.IsNullOrWhiteSpace(c)) return TextSanitizer.OneLine(c, 60);
        return "Claude session";
    }
}
