using System.Text.Json.Nodes;
using Microsoft.Data.Sqlite;

namespace ClaudexBar.Core;

public sealed record CodexPaths(string Home)
{
    public static CodexPaths Standard() =>
        new(Environment.GetEnvironmentVariable("CODEX_HOME") is { Length: > 0 } h
            ? h
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex"));

    public string SessionsDir => Path.Combine(Home, "sessions");
    public string LocksDir => Path.Combine(Home, "thread-writer-locks");
    public string SessionIndex => Path.Combine(Home, "session_index.jsonl");
    public string AuthFile => Path.Combine(Home, "auth.json");

    public string? StateDatabase()
    {
        (int Version, string Path)? best = null;
        foreach (var dir in new[] { Home, System.IO.Path.Combine(Home, "sqlite") })
            foreach (var name in FileReading.List(dir))
            {
                if (!name.StartsWith("state_", StringComparison.Ordinal) || !name.EndsWith(".sqlite", StringComparison.Ordinal)) continue;
                if (int.TryParse(name["state_".Length..^".sqlite".Length], out var v) && (best is null || v > best.Value.Version))
                    best = (v, System.IO.Path.Combine(dir, name));
            }
        return best?.Path;
    }

    public static string? ThreadIdFromRollout(string path)
    {
        var name = PathUtil.BaseName(path);
        if (!name.StartsWith("rollout-", StringComparison.Ordinal) || !name.EndsWith(".jsonl", StringComparison.Ordinal)) return null;
        var stem = name[..^6];
        if (stem.Length <= 36) return null;
        var id = stem[^36..];
        return IsUuidLike(id) ? id : null;
    }

    public static string? ThreadIdFromLock(string path)
    {
        var name = PathUtil.BaseName(path);
        if (!name.EndsWith(".lock", StringComparison.Ordinal)) return null;
        var id = name[..^5];
        return IsUuidLike(id) ? id : null;
    }

    public static bool IsUuidLike(string s)
    {
        if (s.Length != 36) return false;
        for (int i = 0; i < 36; i++)
        {
            if (i is 8 or 13 or 18 or 23) { if (s[i] != '-') return false; }
            else if (!Uri.IsHexDigit(s[i])) return false;
        }
        return true;
    }
}

public sealed record CodexTurnError(string? Message, string? Info)
{
    public bool IsUsageLimit => Info is { } i && (i.Contains("usagelimit") || i.Contains("ratelimit"));
}

public sealed record RateWindowObservation(double? Minutes, double? UsedPercent, DateTimeOffset? ResetsAt);

public sealed record CodexRateLimits(string? LimitId, string? PlanType, List<RateWindowObservation> Windows, string? ReachedType);

public sealed record CodexSessionMeta(string? Id, string? Cwd, string? Originator, string? Source, string? CliVersion);

public abstract record CodexRecord
{
    public sealed record TaskStarted(string? TurnId, DateTimeOffset? At) : CodexRecord;
    public sealed record TaskComplete(string? TurnId, DateTimeOffset? At, CodexTurnError? Error) : CodexRecord;
    public sealed record TurnAborted(string? TurnId, DateTimeOffset? At, string? Reason) : CodexRecord;
    public sealed record ToolCall(string CallId, ToolSummary Summary, DateTimeOffset? At) : CodexRecord;
    public sealed record ToolOutput(string CallId, DateTimeOffset? At) : CodexRecord;
    public sealed record Activity(string Text, DateTimeOffset? At) : CodexRecord;
    public sealed record Reasoning(DateTimeOffset? At) : CodexRecord;
    public sealed record AgentMessage(DateTimeOffset? At) : CodexRecord;
    public sealed record TokenCount(CodexRateLimits? Limits, DateTimeOffset? At) : CodexRecord;
    public sealed record TurnContext(string? Cwd, string? ApprovalPolicy, DateTimeOffset? At) : CodexRecord;
    public sealed record SessionMeta(CodexSessionMeta Meta, DateTimeOffset? At) : CodexRecord;
    public sealed record LegacyError(string? Message, DateTimeOffset? At) : CodexRecord;
    public sealed record Other(DateTimeOffset? At) : CodexRecord;

    public DateTimeOffset? Timestamp => this switch
    {
        TaskStarted r => r.At,
        TaskComplete r => r.At,
        TurnAborted r => r.At,
        ToolCall r => r.At,
        ToolOutput r => r.At,
        Activity r => r.At,
        Reasoning r => r.At,
        AgentMessage r => r.At,
        TokenCount r => r.At,
        TurnContext r => r.At,
        SessionMeta r => r.At,
        LegacyError r => r.At,
        Other r => r.At,
        _ => null,
    };
}

public static class CodexRecordDecoder
{
    public const int MaxLineBytes = 1 << 20;

    public static CodexRecord Decode(JsonLine line)
    {
        var bytes = line.Bytes;
        var head = bytes.AsSpan(0, Math.Min(bytes.Length, 4096));
        var (type, payloadType) = JsonSniff.CodexKinds(head);
        var at = TimeParsing.Iso8601(JsonSniff.String("timestamp", head));

        switch (type, payloadType)
        {
            case ("response_item", "reasoning"):
                return new CodexRecord.Reasoning(at);
            case ("response_item", { } p) when p.EndsWith("_output", StringComparison.Ordinal):
                return JsonSniff.String("call_id", bytes.AsSpan(0, Math.Min(bytes.Length, 16_384))) is { } id
                    ? new CodexRecord.ToolOutput(id, at)
                    : new CodexRecord.Other(at);
            case ("response_item", "message"):
                return JsonSniff.String("role", bytes.AsSpan(0, Math.Min(bytes.Length, 8192))) == "assistant"
                    ? new CodexRecord.AgentMessage(at)
                    : new CodexRecord.Other(at);
            case ("response_item", "web_search_call"):
                return new CodexRecord.Activity("Searching the web", at);
            case ("response_item", "image_generation_call"):
                return new CodexRecord.Activity("Generating an image", at);
            case ("event_msg", "item_completed"):
            {
                int itemPos = JsonSniff.Find(head, "\"item\":"u8);
                var kind = itemPos >= 0 ? JsonSniff.String("type", head, itemPos) : null;
                return kind switch
                {
                    "ContextCompaction" => new CodexRecord.Activity("Compacting context…", at),
                    "Reasoning" => new CodexRecord.Reasoning(at),
                    "AgentMessage" => new CodexRecord.AgentMessage(at),
                    _ => new CodexRecord.Other(at),
                };
            }
            case ("compacted", _) or ("world_state", _) or ("token_usage_record", _):
                return new CodexRecord.Other(at);
        }

        if (line.IsOversize || Json.Parse(bytes) is not JsonObject o) return new CodexRecord.Other(at);
        var p2 = o.Get("payload");
        if (p2 is null) return new CodexRecord.Other(at);
        at = TimeParsing.Iso8601(o.Str("timestamp")) ?? at;
        switch (o.Str("type"))
        {
            case "event_msg":
                switch (p2.Str("type"))
                {
                    case "task_started":
                        return new CodexRecord.TaskStarted(p2.Str("turn_id"), p2.Num("started_at") is { } s ? TimeParsing.Epoch(s) : at);
                    case "task_complete":
                        return new CodexRecord.TaskComplete(p2.Str("turn_id"),
                            p2.Num("completed_at") is { } c ? TimeParsing.Epoch(c) : at, TurnError(p2.Get("error")));
                    case "turn_aborted":
                        return new CodexRecord.TurnAborted(p2.Str("turn_id"),
                            p2.Num("completed_at") is { } c2 ? TimeParsing.Epoch(c2) : at, p2.Str("reason"));
                    case "token_count":
                        return new CodexRecord.TokenCount(RateLimits(p2.Get("rate_limits")), at);
                    case "error" or "stream_error":
                        return new CodexRecord.LegacyError(p2.Str("message") is { } m ? TextSanitizer.OneLine(m, 90) : null, at);
                }
                return new CodexRecord.Other(at);
            case "response_item":
                switch (p2.Str("type"))
                {
                    case "function_call" or "custom_tool_call" when p2.Str("call_id") is { } cid && p2.Str("name") is { } name:
                        return new CodexRecord.ToolCall(cid, CodexActivity.Summarize(name, p2.Str("namespace"), p2.Str("arguments"), p2.Str("input")), at);
                    case "local_shell_call" when (p2.Str("call_id") ?? p2.Str("id")) is { } sid:
                        var cmd = p2.Get("action").Arr("command")?.Select(n => n.AsStr()).OfType<string>().LastOrDefault();
                        return new CodexRecord.ToolCall(sid, CodexActivity.Shell(cmd), at);
                }
                return new CodexRecord.Other(at);
            case "turn_context":
                return new CodexRecord.TurnContext(p2.Str("cwd"), p2.Str("approval_policy"), at);
            case "session_meta":
            {
                var src = p2["source"].AsStr() ?? (p2["source"] as JsonObject)?.Select(kv => kv.Key).Order().FirstOrDefault();
                return new CodexRecord.SessionMeta(new CodexSessionMeta(p2.Str("id"), p2.Str("cwd"), p2.Str("originator"), src,
                    p2.Str("cli_version")), at);
            }
        }
        return new CodexRecord.Other(at);
    }

    public static CodexTurnError? TurnError(JsonNode? v)
    {
        if (v is null) return null;
        if (v.AsStr() is { } s) return new CodexTurnError(TextSanitizer.OneLine(s, 90), null);
        if (v is not JsonObject) return null;
        var message = v.Str("message") is { } m ? TextSanitizer.OneLine(m, 90) : null;
        string? info = null;
        if ((v.Get("codex_error_info") ?? v.Get("codexErrorInfo")) is { } raw)
        {
            if (raw.AsStr() is { } str) info = Normalize(str);
            else if (raw is JsonObject ro && ro.Select(kv => kv.Key).Order().FirstOrDefault() is { } key) info = Normalize(key);
        }
        return new CodexTurnError(message, info);
    }

    private static string Normalize(string s) => new(s.ToLowerInvariant().Where(c => c != '_' && c != '-').ToArray());

    /// <summary>Rollout (`primary`/`secondary`) or app-server style rate limits.</summary>
    public static CodexRateLimits? RateLimits(JsonNode? v)
    {
        if (v is not JsonObject) return null;
        RateWindowObservation? Window(JsonNode? w)
        {
            if (w is not JsonObject) return null;
            var minutes = w.Num("window_minutes") ?? w.Num("windowDurationMins") ?? (w.Num("limit_window_seconds") is { } sec ? sec / 60 : null);
            var used = w.Num("used_percent") ?? w.Num("usedPercent");
            var resets = TimeParsing.Flexible(w.Get("resets_at") ?? w.Get("resetsAt") ?? w.Get("reset_at"));
            return new RateWindowObservation(minutes, used, resets);
        }
        var windows = new[] { Window(v.Get("primary")), Window(v.Get("secondary")) }.OfType<RateWindowObservation>().ToList();
        var reached = v.Str("rate_limit_reached_type") ?? v.Get("rate_limit_reached_type").Str("type") ?? v.Str("rateLimitReachedType");
        return new CodexRateLimits(v.Str("limit_id") ?? v.Str("limitId"), v.Str("plan_type") ?? v.Str("planType"), windows, reached);
    }
}

public static class CodexActivity
{
    public static ToolSummary Summarize(string name, string? ns, string? arguments, string? input)
    {
        var args = arguments is null ? null : Json.Parse(arguments);
        if (ns is { } n && (n.StartsWith("mcp__", StringComparison.Ordinal) || n.StartsWith("mcp:", StringComparison.Ordinal)))
            return new ToolSummary(name, name, $"MCP {n[5..Math.Min(n.Length, 35)]} · {name}");
        if (name.StartsWith("mcp__", StringComparison.Ordinal))
        {
            var parts = name[5..].Split("__");
            var tool = string.Join("__", parts.Skip(1));
            return new ToolSummary(name, tool, $"MCP {parts[0]} · {tool}");
        }
        switch (name)
        {
            case "exec": return Exec(input);
            case "exec_command" or "shell" or "container.exec" or "local_shell":
                return Shell(args.Str("cmd") ?? args.Str("command")
                             ?? args.Arr("command")?.Select(x => x.AsStr()).OfType<string>().LastOrDefault());
            case "write_stdin" or "wait": return new ToolSummary(name, null, "Waiting on command output");
            case "apply_patch":
            {
                var f = PatchFile(input ?? args.Str("input") ?? arguments);
                return new ToolSummary(name, f, "Editing " + (f ?? "files"));
            }
            case "update_plan": return new ToolSummary(name, null, "Updating plan");
            case "view_image": return new ToolSummary(name, null, "Viewing an image");
            case "request_user_input":
            {
                var q = args.Arr("questions").At(0);
                var header = (q.Str("header") ?? q.Str("question")) is { } h ? TextSanitizer.OneLine(h, 50) : null;
                return new ToolSummary(name, header, "Asking a question", header);
            }
            case "web_search" or "web.run" or "search": return new ToolSummary(name, null, "Searching the web");
            default: return new ToolSummary(name, null, $"Running {TextSanitizer.OneLine(name, 40)}");
        }
    }

    public static ToolSummary Shell(string? command)
    {
        var cmd = command is null ? null : Clean(command);
        return new ToolSummary("shell", cmd, "Running" + (cmd is null ? " a command" : $": {cmd}"));
    }

    private static ToolSummary Exec(string? input)
    {
        if (input is null) return new ToolSummary("exec", null, "Running code");
        if (input.Contains("*** Begin Patch", StringComparison.Ordinal))
        {
            var f = PatchFile(input);
            return new ToolSummary("exec", f, "Editing " + (f ?? "files"));
        }
        int i = input.IndexOf("exec_command(", StringComparison.Ordinal);
        if (i >= 0)
        {
            var rest = System.Text.Encoding.UTF8.GetBytes(input[(i + "exec_command(".Length)..].Substring(0, Math.Min(4096, input.Length - i - 13)));
            if (JsonSniff.String("cmd", rest) is { } cmd)
            {
                var c = Clean(cmd);
                return new ToolSummary("exec", c, $"Running: {c}");
            }
        }
        return new ToolSummary("exec", null, "Running code");
    }

    private static string? PatchFile(string? patch)
    {
        if (patch is null) return null;
        foreach (var marker in new[] { "*** Update File: ", "*** Add File: ", "*** Delete File: " })
        {
            int i = patch.IndexOf(marker, StringComparison.Ordinal);
            if (i < 0) continue;
            var rest = patch[(i + marker.Length)..];
            int end = rest.IndexOfAny(['\n', '\\', '"', '`']);
            var line = (end >= 0 ? rest[..end] : rest).Trim();
            var name = PathUtil.BaseName(line);
            if (name.Length > 0) return name;
        }
        return null;
    }

    private static string Clean(string command)
    {
        var first = command.Split(['\n', '\r'], StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? command;
        return TextSanitizer.OneLine(first, 70);
    }
}

public sealed class CodexThreadState
{
    public enum TurnKind { None, Active, Completed, Aborted }

    public TurnKind Turn { get; private set; } = TurnKind.None;
    public DateTimeOffset? TurnAt { get; private set; }
    public CodexTurnError? TurnError { get; private set; }
    public Dictionary<string, PendingTool> Pending { get; } = [];
    public string? Activity { get; private set; }
    public DateTimeOffset? LastEventAt { get; private set; }
    public string? ApprovalPolicy { get; private set; }
    public CodexSessionMeta? Meta { get; private set; }
    public string? Cwd { get; private set; }
    public CodexRateLimits? RateLimits { get; private set; }
    public DateTimeOffset? RateLimitsAt { get; private set; }

    public void StartActive(DateTimeOffset? since)
    {
        Turn = TurnKind.Active;
        TurnAt = since;
    }

    public void Apply(CodexRecord r)
    {
        switch (r)
        {
            case CodexRecord.TaskStarted s:
                Turn = TurnKind.Active; TurnAt = s.At; TurnError = null; Pending.Clear(); Activity = "Thinking…";
                break;
            case CodexRecord.TaskComplete c:
                Turn = TurnKind.Completed; TurnAt = c.At; TurnError = c.Error; Pending.Clear(); Activity = null;
                break;
            case CodexRecord.TurnAborted a:
                Turn = TurnKind.Aborted; TurnAt = a.At; TurnError = null; Pending.Clear(); Activity = null;
                break;
            case CodexRecord.ToolCall call:
                Pending[call.CallId] = new PendingTool(call.CallId, call.Summary, call.At);
                Activity = call.Summary.Working;
                break;
            case CodexRecord.ToolOutput output:
                Pending.Remove(output.CallId);
                Activity = LatestPending?.Summary.Working ?? "Thinking…";
                break;
            case CodexRecord.Activity a:
                Activity = a.Text;
                break;
            case CodexRecord.Reasoning:
                if (Pending.Count == 0) Activity = "Thinking…";
                break;
            case CodexRecord.AgentMessage:
                if (Pending.Count == 0) Activity = "Responding…";
                break;
            case CodexRecord.TokenCount { Limits: { } limits } t:
                RateLimits = limits; RateLimitsAt = t.At;
                break;
            case CodexRecord.TurnContext ctx:
                if (ctx.ApprovalPolicy is not null) ApprovalPolicy = ctx.ApprovalPolicy;
                if (ctx.Cwd is not null) Cwd = ctx.Cwd;
                break;
            case CodexRecord.SessionMeta m:
                Meta = m.Meta;
                Cwd ??= m.Meta.Cwd;
                break;
            case CodexRecord.LegacyError e when Turn == TurnKind.Active:
                Turn = TurnKind.Completed; TurnAt = e.At; TurnError = new CodexTurnError(e.Message, null); Pending.Clear();
                break;
        }
        if (r.Timestamp is { } ts && ts > (LastEventAt ?? DateTimeOffset.MinValue)) LastEventAt = ts;
    }

    public PendingTool? LatestPending => Pending.Values.OrderByDescending(p => p.At ?? DateTimeOffset.MinValue).FirstOrDefault();

    public PendingTool? PendingQuestion => Pending.Values.Where(p => p.Summary.Name == "request_user_input")
        .OrderByDescending(p => p.At ?? DateTimeOffset.MinValue).FirstOrDefault();

    public bool IsActive => Turn == TurnKind.Active;
}

public sealed record CodexThreadContext(int? OwnerPid, DateTimeOffset? OwnerStart, DateTimeOffset? LockBirth, bool Loaded, Confidence Confidence);

public static class CodexStateDeriver
{
    public static readonly TimeSpan QuietNote = TimeSpan.FromMinutes(15);
    public static readonly TimeSpan StaleTurn = TimeSpan.FromHours(2);

    public static DerivedState Derive(CodexThreadState s, CodexThreadContext c, DateTimeOffset fallbackSince, DateTimeOffset now)
    {
        switch (s.Turn)
        {
            case CodexThreadState.TurnKind.Active:
            {
                var started = s.TurnAt ?? s.LastEventAt ?? fallbackSince;
                if (s.PendingQuestion is { } q)
                {
                    var r = AttentionReason.Question(q.Summary.QuestionHeader);
                    return new(SessionState.Attention(r), AttentionMapper.Text(r), q.At ?? started, Confidence.Reported);
                }
                if (c.OwnerStart is { } os && os > started.AddSeconds(5))
                    return new(SessionState.WaitingForUser, "Interrupted (app restarted)", s.LastEventAt ?? started, Confidence.Inferred);
                var quiet = now - (s.LastEventAt ?? started);
                if (quiet > StaleTurn)
                    return new(SessionState.WaitingForUser, $"No activity for {Durations.Short(quiet)} — turn may be stuck",
                        s.LastEventAt ?? started, Confidence.Inferred);
                var text = s.Activity ?? "Working…";
                if (quiet > QuietNote) text += $" · quiet {Durations.Short(quiet)}";
                return new(SessionState.Working, text, started, c.Confidence);
            }
            case CodexThreadState.TurnKind.Completed when s.TurnError is { } err:
            {
                var r = err.IsUsageLimit ? AttentionReason.UsageLimit : AttentionReason.Error(err.Message);
                return new(SessionState.Attention(r), AttentionMapper.Text(r), s.TurnAt ?? s.LastEventAt ?? fallbackSince, Confidence.Reported);
            }
            case CodexThreadState.TurnKind.Completed:
                return new(SessionState.WaitingForUser, "Waiting for you", s.TurnAt ?? s.LastEventAt ?? fallbackSince, Confidence.Reported);
            case CodexThreadState.TurnKind.Aborted:
                return new(SessionState.WaitingForUser, "Interrupted", s.TurnAt ?? s.LastEventAt ?? fallbackSince, Confidence.Reported);
            default:
                return new(SessionState.WaitingForUser, "New thread", c.LockBirth ?? s.LastEventAt ?? fallbackSince, Confidence.Inferred);
        }
    }

    public static SessionOrigin Origin(CodexSessionMeta? meta, string? ownerAppName)
    {
        var app = ownerAppName?.ToLowerInvariant() ?? "";
        if (app is "codex" or "chatgpt") return SessionOrigin.Desktop;
        if (app is "code" or "cursor" or "windsurf") return SessionOrigin.Ide;
        var originator = meta?.Originator?.ToLowerInvariant() ?? "";
        var source = meta?.Source?.ToLowerInvariant() ?? "";
        if (originator.Contains("desktop")) return SessionOrigin.Desktop;
        if (source == "exec" || originator.Contains("exec")) return SessionOrigin.Background;
        if (source == "vscode") return SessionOrigin.Ide;
        return SessionOrigin.Terminal;
    }
}

public sealed record CodexThreadInfo(string Id, string? Title, string? Cwd, bool Archived, bool IsSubagent, string? RolloutPath,
    DateTimeOffset? UpdatedAt);

/// <summary>Thread metadata from Codex's state database (read-only; never creates side files).</summary>
public static class CodexThreadIndex
{
    public static Dictionary<string, CodexThreadInfo> Load(IReadOnlyCollection<string> ids, CodexPaths paths)
    {
        var result = new Dictionary<string, CodexThreadInfo>();
        if (ids.Count == 0) return result;
        try
        {
            if (paths.StateDatabase() is { } db) LoadFromSqlite(db, ids, result);
        }
        catch (Exception e) when (e is SqliteException or IOException or InvalidOperationException) { }

        var missing = ids.Where(id => !result.TryGetValue(id, out var i) || i.Title is null).ToList();
        if (missing.Count > 0)
        {
            var names = SessionIndexNames(paths);
            foreach (var id in missing)
            {
                if (!names.TryGetValue(id, out var name)) continue;
                result[id] = result.TryGetValue(id, out var info)
                    ? info with { Title = name }
                    : new CodexThreadInfo(id, name, null, false, false, null, null);
            }
        }
        return result;
    }

    private static void LoadFromSqlite(string db, IReadOnlyCollection<string> ids, Dictionary<string, CodexThreadInfo> result)
    {
        bool hasWal = File.Exists(db + "-wal"), hasShm = File.Exists(db + "-shm");
        // A plain read-only open of a WAL database creates -shm; use immutable when no WAL exists.
        var uri = new Uri(db).AbsoluteUri + (!hasWal || !hasShm ? "?immutable=1" : "?mode=ro");
        using var conn = new SqliteConnection($"Data Source={uri};Mode=ReadOnly;Pooling=False");
        conn.Open();
        var cols = new HashSet<string>();
        using (var info = conn.CreateCommand())
        {
            info.CommandText = "PRAGMA table_info(threads)";
            using var r = info.ExecuteReader();
            while (r.Read()) cols.Add(r.GetString(1));
        }
        if (!cols.Contains("id")) return;
        var wanted = new[] { "id", "name", "title", "cwd", "archived", "agent_role", "rollout_path", "updated_at_ms", "updated_at" }
            .Where(cols.Contains).ToList();
        using var cmd = conn.CreateCommand();
        var ps = ids.Select((id, i) => { cmd.Parameters.AddWithValue($"$p{i}", id); return $"$p{i}"; });
        cmd.CommandText = $"SELECT {string.Join(",", wanted)} FROM threads WHERE id IN ({string.Join(",", ps)})";
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            string? Get(string c) => wanted.Contains(c) && !reader.IsDBNull(reader.GetOrdinal(c)) ? Convert.ToString(reader[c]) : null;
            var id = Get("id");
            if (id is null) continue;
            var name = Get("name") is { Length: > 0 } n ? n : null;
            var title = Get("title") is { Length: > 0 } t ? t : null;
            DateTimeOffset? updated = long.TryParse(Get("updated_at_ms") ?? Get("updated_at"), out var ms) ? TimeParsing.Epoch(ms) : null;
            result[id] = new CodexThreadInfo(id, name ?? title, Get("cwd"), Get("archived") is "1",
                Get("agent_role") is { Length: > 0 }, Get("rollout_path"), updated);
        }
    }

    public static Dictionary<string, string> SessionIndexNames(CodexPaths paths)
    {
        var names = new Dictionary<string, string>();
        if (FileReading.Stat(paths.SessionIndex) is not { IsDirectory: false } st) return names;
        int length = (int)Math.Min(st.Size, 256 * 1024);
        var data = FileReading.Read(paths.SessionIndex, st.Size - length, length);
        if (data is null) return names;
        foreach (var line in System.Text.Encoding.UTF8.GetString(data).Split('\n'))
            if (Json.Parse(line) is JsonObject o && o.Str("id") is { } id && o.Str("thread_name") is { Length: > 0 } name)
                names[id] = name;
        return names;
    }
}

public sealed record CodexRateLimitObservation(CodexRateLimits Limits, DateTimeOffset ObservedAt, UsageSource Source);

public static class CodexRolloutScanner
{
    public static (CodexThreadState State, BackwardScanner.Result Result)? Bootstrap(string path, int budget = 8 << 20)
    {
        var records = new List<CodexRecord>();
        var result = BackwardScanner.Scan(path, budget, CodexRecordDecoder.MaxLineBytes, line =>
        {
            var r = CodexRecordDecoder.Decode(line);
            records.Add(r);
            return r is CodexRecord.TaskStarted;
        });
        if (result is null) return null;
        records.Reverse();
        var state = new CodexThreadState();
        if (result.Exhausted && !records.Any(r => r is CodexRecord.TaskStarted))
            state.StartActive(records.Select(r => r.Timestamp).FirstOrDefault(t => t is not null));
        foreach (var r in records) state.Apply(r);
        return (state, result);
    }

    public static List<string> NewestRollouts(CodexPaths paths, int limit = 3)
    {
        IEnumerable<string> Sorted(string dir) => FileReading.List(dir).Where(n => int.TryParse(n, out _)).OrderDescending();
        var files = new List<(string Path, DateTimeOffset Modified)>();
        foreach (var y in Sorted(paths.SessionsDir))
        foreach (var m in Sorted(Path.Combine(paths.SessionsDir, y)))
        foreach (var d in Sorted(Path.Combine(paths.SessionsDir, y, m)))
        {
            var dir = Path.Combine(paths.SessionsDir, y, m, d);
            foreach (var name in FileReading.List(dir).Where(n => n.StartsWith("rollout-") && n.EndsWith(".jsonl")))
                if (FileReading.Stat(Path.Combine(dir, name)) is { } st) files.Add((Path.Combine(dir, name), st.Modified));
            if (files.Count >= limit) return files.OrderByDescending(f => f.Modified).Take(limit).Select(f => f.Path).ToList();
        }
        return files.OrderByDescending(f => f.Modified).Take(limit).Select(f => f.Path).ToList();
    }

    public static CodexRateLimitObservation? LatestRateLimits(CodexPaths paths)
    {
        foreach (var path in NewestRollouts(paths))
        {
            CodexRateLimitObservation? found = null;
            BackwardScanner.Scan(path, 2 << 20, CodexRecordDecoder.MaxLineBytes, line =>
            {
                if (CodexRecordDecoder.Decode(line) is CodexRecord.TokenCount { Limits: { } l } t && (l.LimitId is null or "codex"))
                {
                    found = new CodexRateLimitObservation(l, t.At ?? DateTimeOffset.MinValue, UsageSource.CodexRollout);
                    return true;
                }
                return false;
            });
            if (found is not null) return found;
        }
        return null;
    }
}
