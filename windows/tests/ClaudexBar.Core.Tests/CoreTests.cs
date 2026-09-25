using System.Text;
using ClaudexBar.Core;
using Xunit;

namespace ClaudexBar.Core.Tests;

internal static class Fx
{
    public static string Dir => Path.Combine(AppContext.BaseDirectory, "Fixtures");
    public static byte[] Data(string rel) => File.ReadAllBytes(Path.Combine(Dir, rel));
    public static string Text(string rel) => File.ReadAllText(Path.Combine(Dir, rel));
    public static DateTimeOffset T(string iso) => TimeParsing.Iso8601(iso)!.Value;

    public static ClaudeRegistryEntry Entry(string name) => ClaudeRegistryEntry.Parse(Data($"claude/registry/{name}"))!;

    public static ClaudeTranscriptState Transcript(string name)
    {
        var state = new ClaudeTranscriptState();
        foreach (var line in new LineFramer(ClaudeRecordDecoder.MaxLineBytes).Push(Data($"claude/transcripts/{name}")))
            state.Apply(ClaudeRecordDecoder.Decode(line));
        return state;
    }

    public static List<CodexRecord> CodexRecords(string name) =>
        new LineFramer(CodexRecordDecoder.MaxLineBytes).Push(Data($"codex/rollouts/{name}")).Select(CodexRecordDecoder.Decode).ToList();

    public static CodexThreadState CodexState(string name)
    {
        var s = new CodexThreadState();
        foreach (var r in CodexRecords(name)) s.Apply(r);
        return s;
    }

    public static AgentSession Session(string id, Provider p, SessionState st, DateTimeOffset since, string project = "demo") =>
        new(id, p, st, since, "x", project, project, null, SessionOrigin.Desktop, null, null, null, Confidence.Reported);
}

public sealed class TempDir : IDisposable
{
    public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "claudexbar-" + Guid.NewGuid().ToString("N"));
    public TempDir() => Directory.CreateDirectory(Path);
    public string Write(string name, string text)
    {
        var p = System.IO.Path.Combine(Path, name);
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(p)!);
        File.WriteAllText(p, text);
        return p;
    }
    public void Dispose() { try { Directory.Delete(Path, true); } catch (IOException) { } }
}

public class PrimitivesTests
{
    [Theory]
    [InlineData("2026-09-22T19:23:24.036Z", 1_790_105_004_036)]
    [InlineData("2026-09-19T06:09:04.873161Z", 1_789_798_144_873)]
    [InlineData("2026-09-23T08:00:00+05:00", 1_790_132_400_000)]
    public void Iso8601(string input, long expectedMs) =>
        Assert.Equal(expectedMs, TimeParsing.Iso8601(input)!.Value.ToUnixTimeMilliseconds());

    [Fact]
    public void EpochAndProcStart()
    {
        Assert.Equal(1_790_105_004, TimeParsing.Epoch(1_790_105_004)!.Value.ToUnixTimeSeconds());
        Assert.Equal(1_790_105_004_036, TimeParsing.Epoch(1_790_105_004_036)!.Value.ToUnixTimeMilliseconds());
        Assert.Null(TimeParsing.Epoch(0));
        Assert.Equal(1_790_286_626, TimeParsing.ProcStart("Thu Sep 24 21:50:26 2026")!.Value.ToUnixTimeSeconds());
        Assert.Equal(1_788_336_000, TimeParsing.ProcStart("Wed Sep  2 08:00:00 2026")!.Value.ToUnixTimeSeconds());
    }

    [Fact]
    public void LineFramerHoldsPartialsAndCapsOversize()
    {
        var f = new LineFramer(10, 4);
        Assert.Empty(f.Push("0123456789ABCDEF"u8));
        var lines = f.Push("GH\nok\r\n"u8);
        Assert.Equal(2, lines.Count);
        Assert.True(lines[0].IsOversize);
        Assert.Equal(18, lines[0].TotalBytes);
        Assert.Equal("0123", lines[0].Text);
        Assert.Equal("ok", lines[1].Text);
    }

    [Fact]
    public void BackwardScannerStopsAtMarkerAndExcludesPartialTail()
    {
        using var dir = new TempDir();
        var body = string.Join("\n", Enumerable.Range(1, 50).Select(i => i == 40 ? $"{{\"type\":\"task_started\",\"i\":{i}}}" : $"{{\"i\":{i}}}"));
        var path = dir.Write("r.jsonl", body + "\n{\"partial\":");
        var r = BackwardScanner.Scan(path, 1 << 20, 1000, l => l.Text.Contains("task_started"), chunk: 16)!;
        Assert.True(r.ReachedStop);
        Assert.Equal(11, r.Lines.Count);
        Assert.Contains("\"i\":40", r.Lines[0].Text);
        Assert.Equal("{\"i\":50}", r.Lines[^1].Text);
        Assert.Equal(new FileInfo(path).Length - "{\"partial\":".Length, r.EndOffset);
    }

    [Fact]
    public void BackwardScannerBudget()
    {
        using var dir = new TempDir();
        var path = dir.Write("r.jsonl", string.Join("\n", Enumerable.Range(1, 2000).Select(i => $"{{\"i\":{i}}}")) + "\n");
        var r = BackwardScanner.Scan(path, 256, 1000, _ => false, chunk: 64)!;
        Assert.True(r.Exhausted);
        Assert.True(r.BytesRead <= 256 + 64);
        Assert.Equal("{\"i\":2000}", r.Lines[^1].Text);
    }

    [Fact]
    public void ForwardTailerFollowsAppends()
    {
        using var dir = new TempDir();
        var path = dir.Write("log.jsonl", "a\nb\n");
        var created = FileReading.Stat(path)!.Value.Created;
        var t = new ForwardTailer(path, created, 2, 100);
        var (status, lines) = t.Poll();
        Assert.Equal(ForwardTailer.Status.Lines, status);
        Assert.Equal("b", lines.Single().Text);
        Assert.Equal(ForwardTailer.Status.Unchanged, t.Poll().Status);
        File.AppendAllText(path, "c\npart");
        Assert.Equal("c", t.Poll().Lines.Single().Text);
        File.WriteAllText(path, "x\n");
        Assert.Equal(ForwardTailer.Status.NeedsBootstrap, t.Poll().Status);
    }

    [Theory]
    [InlineData("curl -H 'Authorization: Bearer abcdefghijklmnop.qrs' https://x", "abcdefghijklmnop")]
    [InlineData("export ANTHROPIC_API_KEY=sk-ant-api03-FAKEFAKEFAKEFAKE", "FAKEFAKEFAKEFAKE")]
    [InlineData("SECRET_TOKEN=supersecretvalue123 ./run.sh", "supersecretvalue123")]
    [InlineData("mysql --password hunter2hunter2 db", "hunter2hunter2")]
    public void RedactsSecrets(string input, string secret)
    {
        var output = TextSanitizer.OneLine(input, 200);
        Assert.Contains("‹redacted›", output);
        Assert.DoesNotContain(secret, output);
    }

    [Fact]
    public void OneLineStripsAnsiAndTruncates()
    {
        Assert.Equal("npm test red done", TextSanitizer.OneLine("  npm\n\ttest \u001B[31mred\u001B[0m  done "));
        var s = TextSanitizer.OneLine(new string('a', 200), 10);
        Assert.Equal(10, s.Length);
        Assert.EndsWith("…", s);
        Assert.DoesNotContain("FAKE", new SecretToken("sk-ant-FAKE").ToString());
    }

    [Fact]
    public void JsonSniffCodexKinds()
    {
        var line = Encoding.UTF8.GetBytes(@"{""timestamp"":""2026-09-19T06:09:04Z"",""ordinal"":12,""type"":""response_item"",""payload"":{""type"":""function_call_output"",""call_id"":""call_\""abc"",""output"":""…");
        var (type, payload) = JsonSniff.CodexKinds(line);
        Assert.Equal("response_item", type);
        Assert.Equal("function_call_output", payload);
        Assert.Equal("call_\"abc", JsonSniff.String("call_id", line));
    }
}

public class ClaudeTests
{
    private readonly DateTimeOffset _now = Fx.T("2026-09-22T19:30:00Z");

    [Fact]
    public void DecodesRegistryLeniently()
    {
        var e = Fx.Entry("desktop-busy.json");
        Assert.Equal(41001, e.Pid);
        Assert.Equal(ClaudeStatus.Busy, e.Status);
        Assert.Equal(OriginKind.Desktop, e.Origin.Kind);
        var wrong = Fx.Entry("wrong-types.json");
        Assert.Null(wrong.Pid);
        Assert.Null(wrong.SessionId);
        Assert.Null(wrong.StatusUpdatedAt);
        Assert.Equal(ClaudeStatus.Unknown, Fx.Entry("future-fields.json").Status);
        Assert.Null(ClaudeRegistryEntry.Parse(Fx.Data("claude/registry/torn.json")));
    }

    [Theory]
    [InlineData("daemon.json")]
    [InlineData("spare.json")]
    [InlineData("sdk-ts.json")]
    public void HiddenEntries(string name) => Assert.False(Fx.Entry(name).IsDisplayable);

    [Fact]
    public void RegistryNamesAndKeyFilesNeverRead()
    {
        Assert.True(ClaudeRegistryReader.IsRegistryName("41001.json"));
        Assert.False(ClaudeRegistryReader.IsRegistryName("0123.json"));
        Assert.False(ClaudeRegistryReader.IsRegistryName("41001.00ff.key"));
        using var dir = new TempDir();
        dir.Write("41001.json", Fx.Text("claude/registry/desktop-busy.json"));
        dir.Write("41001.abc.key", "DO-NOT-READ");
        var reader = new ClaudeRegistryReader();
        Assert.Equal(["41001.json"], reader.Scan(dir.Path).Keys.ToArray());
        dir.Write("41001.json", Fx.Text("claude/registry/torn.json"));
        Assert.Equal(41001, reader.Scan(dir.Path)["41001.json"].Entry.Pid);
        Assert.Contains("41001.json", reader.TornNames);
    }

    [Fact]
    public void TranscriptReducer()
    {
        var bash = Fx.Transcript("running-bash.jsonl");
        Assert.Equal("Running Bash: Run the test suite", bash.LatestPending!.Summary.Working);
        Assert.Equal("npm test -- --watch=false", bash.LatestPending.Summary.Detail);
        Assert.Null(bash.TurnEndedAt);
        Assert.Equal("Demo title", bash.BestTitle);
        Assert.Equal(Fx.T("2026-09-22T19:10:05Z"), Fx.Transcript("turn-ended.jsonl").TurnEndedAt);
        Assert.Equal(["toolu_C"], Fx.Transcript("split-message-out-of-order.jsonl").Pending.Keys.ToArray());
        Assert.Equal("Database", Fx.Transcript("ask-user-question.jsonl").LatestPending!.Summary.QuestionHeader);
        Assert.Equal("server_error", Fx.Transcript("terminal-server-error.jsonl").CurrentTurnError!.Category);
        Assert.Empty(Fx.Transcript("interrupted.jsonl").Pending);
        Assert.NotNull(Fx.Transcript("sidechain-lines.jsonl").TurnEndedAt);
    }

    [Fact]
    public void DerivationTable()
    {
        var busy = ClaudeStateDeriver.Derive(Fx.Entry("desktop-busy.json"), Fx.Transcript("running-bash.jsonl"), null, _now);
        Assert.Equal(SessionState.Working, busy.State);
        Assert.Equal("Running Bash: Run the test suite", busy.Activity);

        var perm = ClaudeStateDeriver.Derive(Fx.Entry("desktop-waiting-permission.json"), Fx.Transcript("running-bash.jsonl"), null, _now);
        Assert.Equal(SessionState.Attention(AttentionReason.Approval("Bash", "npm test -- --watch=false")), perm.State);
        Assert.Equal("Needs approval · Bash: npm test -- --watch=false", perm.Activity);

        var question = ClaudeStateDeriver.Derive(Fx.Entry("desktop-waiting-input.json"), Fx.Transcript("ask-user-question.jsonl"), null, _now);
        Assert.Equal("Question: Database", question.Activity);

        var tui = ClaudeStateDeriver.Derive(Fx.Entry("tui-2.1.121-approve-bash.json"), null, null, _now);
        Assert.Equal(SessionState.Attention(AttentionReason.Approval("Bash", "npm test")), tui.State);

        Assert.Equal("Background shell running", ClaudeStateDeriver.Derive(Fx.Entry("shell-status.json"), null, null, _now).Activity);
        Assert.Equal(SessionState.Attention(AttentionReason.Input("Needs a GitHub token")),
            ClaudeStateDeriver.Derive(Fx.Entry("bg-blocked-needs.json"), null, null, _now).State);

        var idle = Fx.Entry("desktop-busy.json") with { Status = ClaudeStatus.Idle };
        Assert.Equal(SessionState.Attention(AttentionReason.UsageLimit),
            ClaudeStateDeriver.Derive(idle, Fx.Transcript("terminal-rate-limit.jsonl"), null, _now).State);
    }

    [Fact]
    public void BusyButTurnEndedLongAgoIsBackgroundTask()
    {
        var e = Fx.Entry("desktop-busy.json") with { StatusUpdatedAt = Fx.T("2026-09-22T19:10:00Z").ToUnixTimeMilliseconds() };
        var t = Fx.Transcript("background-bash-2.1.121.jsonl");
        var d = ClaudeStateDeriver.Derive(e, t, null, _now);
        Assert.Equal(SessionState.WaitingForUser, d.State);
        Assert.Equal("Background task running", d.Activity);
        Assert.Equal(SessionState.Working, ClaudeStateDeriver.Derive(e, t, null, Fx.T("2026-09-22T19:10:30Z")).State);
    }

    [Fact]
    public void AttentionMapperStrings()
    {
        Assert.Equal(AttentionReason.Approval("Plan", null), AttentionMapper.Map("approve plan", null));
        Assert.Equal(AttentionReason.Approval("Edit", "src/app.ts"), AttentionMapper.Map("approve Edit: src/app.ts", null));
        Assert.Equal(AttentionReason.Input("Dialog open"), AttentionMapper.Map("dialog open", null));
        Assert.Equal(AttentionReason.Input("brand new reason"), AttentionMapper.Map("brand new reason", null));
    }
}

public class CodexTests
{
    private readonly DateTimeOffset _now = Fx.T("2026-09-19T06:10:00Z");
    private static readonly CodexThreadContext Ctx = new(1, TimeParsing.Epoch(1_789_790_000), null, true, Confidence.Reported);

    [Fact]
    public void DecodesRollouts()
    {
        var r = Fx.CodexRecords("complete.jsonl");
        Assert.Contains(r, x => x is CodexRecord.TaskStarted { TurnId: "t1" });
        Assert.IsType<CodexRecord.TaskComplete>(r[^1]);
        var exec = Fx.CodexRecords("active-exec.jsonl").OfType<CodexRecord.ToolCall>().First();
        Assert.Equal("Running: npm test", exec.Summary.Working);
        Assert.Equal("Editing agent.py", Fx.CodexState("patch-exec.jsonl").Activity);
        var limits = Fx.CodexRecords("token-count-variants.jsonl").OfType<CodexRecord.TokenCount>().Select(t => t.Limits!).ToList();
        Assert.Equal([300.0, 10_080.0], limits[0].Windows.Select(w => w.Minutes!.Value));
        Assert.Equal("codex_bengalfox", limits[1].LimitId);
        Assert.Empty(limits[2].Windows);
    }

    [Fact]
    public void DerivesStates()
    {
        var active = CodexStateDeriver.Derive(Fx.CodexState("active-exec.jsonl"), Ctx, _now, _now);
        Assert.Equal(SessionState.Working, active.State);
        Assert.Equal("Running: npm test", active.Activity);
        Assert.Equal(SessionState.WaitingForUser, CodexStateDeriver.Derive(Fx.CodexState("complete.jsonl"), Ctx, _now, _now).State);
        Assert.Equal("Question: Deploy target",
            CodexStateDeriver.Derive(Fx.CodexState("request-user-input-pending.jsonl"), Ctx, _now, _now).Activity);
        var answered = CodexStateDeriver.Derive(Fx.CodexState("request-user-input-answered-dup.jsonl"), Ctx, _now, _now);
        Assert.Equal("Running: make build", answered.Activity);
        Assert.Equal(AttentionKind.Error,
            CodexStateDeriver.Derive(Fx.CodexState("error-other.jsonl"), Ctx, _now, _now).State.Reason!.Kind);
        Assert.Equal(SessionState.Attention(AttentionReason.UsageLimit),
            CodexStateDeriver.Derive(Fx.CodexState("error-usage-limit.jsonl"), Ctx, _now, _now).State);
        Assert.Equal("Interrupted", CodexStateDeriver.Derive(Fx.CodexState("aborted.jsonl"), Ctx, _now, _now).Activity);
        Assert.Empty(Fx.CodexState("orphan-then-new-start.jsonl").Pending);
        var restarted = CodexStateDeriver.Derive(Fx.CodexState("active-exec.jsonl"), Ctx with { OwnerStart = _now }, _now, _now);
        Assert.Equal("Interrupted (app restarted)", restarted.Activity);
        var stale = CodexStateDeriver.Derive(Fx.CodexState("active-exec.jsonl"), Ctx, _now, Fx.T("2026-09-19T09:30:00Z"));
        Assert.Equal(Confidence.Inferred, stale.Confidence);
    }

    [Fact]
    public void BootstrapFromTail()
    {
        using var dir = new TempDir();
        var path = dir.Write("rollout-2026-09-19T11-07-54-00000000-0000-4000-8000-00000000000c.jsonl",
            Fx.Text("codex/rollouts/orphan-then-new-start.jsonl"));
        var (state, result) = CodexRolloutScanner.Bootstrap(path)!.Value;
        Assert.True(result.ReachedStop);
        Assert.True(state.IsActive);
    }

    [Fact]
    public void PathsAndThreadIndex()
    {
        Assert.Equal("0190aaaa-bbbb-7ccc-8ddd-eeeeffff0000",
            CodexPaths.ThreadIdFromRollout("/h/.codex/sessions/2026/09/19/rollout-2026-09-19T11-07-54-0190aaaa-bbbb-7ccc-8ddd-eeeeffff0000.jsonl"));
        Assert.Null(CodexPaths.ThreadIdFromLock(".coordination.lock"));
        using var dir = new TempDir();
        dir.Write("session_index.jsonl", "{\"id\":\"c\",\"thread_name\":\"From index\"}\n");
        var info = CodexThreadIndex.Load(["c"], new CodexPaths(dir.Path));
        Assert.Equal("From index", info["c"].Title);
    }
}

public class UsageTests
{
    private readonly DateTimeOffset _now = Fx.T("2026-09-24T23:00:00Z");

    [Fact]
    public void ClaudeOAuthAndCache()
    {
        var limits = ClaudeUsageParser.ParseOAuth(Fx.Data("claude/usage/oauth-limits.json"), _now)!;
        Assert.Equal(["5h", "Weekly", "Weekly · Opus", "Monthly"], limits.Windows.Select(w => w.Label));
        var legacy = ClaudeUsageParser.ParseOAuth(Fx.Data("claude/usage/oauth-legacy.json"), _now)!;
        Assert.Equal(["5h", "Weekly", "Weekly · Sonnet"], legacy.Windows.Select(w => w.Label));
        var cache = ClaudeUsageParser.ParseDesktopCache(Fx.Data("claude/usage/plan-usage-history-v2.json"), "org-A")!;
        Assert.Equal([10.0, 16.0, 1.0], cache.Windows.Select(w => w.UsedPercent!.Value));
        var v1 = ClaudeUsageParser.ParseDesktopCache(Fx.Data("claude/usage/plan-usage-history-v1.json"), null)!;
        Assert.Equal(["5h", "Weekly"], v1.Windows.Select(w => w.Label));
    }

    [Fact]
    public void ClaudeMergeKeepsFutureApiReset()
    {
        var reset = _now.AddHours(1);
        var api = new ClaudeUsageReading([new UsageWindow("claude.five_hour", WindowKind.Session5h, "5h", 40, reset, null, UsageSource.ClaudeOAuthApi, _now.AddMinutes(-10))],
            _now.AddMinutes(-10), UsageSource.ClaudeOAuthApi);
        var cache = new ClaudeUsageReading([new UsageWindow("claude.five_hour", WindowKind.Session5h, "5h", 45, null, null, UsageSource.ClaudeDesktopCache, _now)],
            _now, UsageSource.ClaudeDesktopCache);
        var merged = ClaudeUsageParser.Merge(api, cache, _now).Single();
        Assert.Equal(45, merged.UsedPercent);
        Assert.Equal(reset, merged.ResetsAt);
        var later = ClaudeUsageParser.Merge(api, cache, reset.AddSeconds(1)).Single();
        Assert.True(later.IsReset);
        Assert.Equal(0, later.UsedPercent);
    }

    [Fact]
    public void Credentials()
    {
        var c = ClaudeCredential.Parse(Fx.Data("claude/usage/keychain.json"))!;
        Assert.True(c.IsUsable(_now));
        Assert.Equal("Max 20×", ClaudeUsageParser.PlanLabel(c.SubscriptionType, c.RateLimitTier));
        Assert.True(ClaudeCredential.Parse(Fx.Data("claude/usage/keychain.hex.txt"))!.IsUsable(_now));
        Assert.False(ClaudeCredential.Parse(Fx.Data("claude/usage/keychain-empty-token.json"))!.IsUsable(_now));
        Assert.False(ClaudeCredential.Parse(Fx.Data("claude/usage/keychain-no-profile-scope.json"))!.IsUsable(_now));
        Assert.Null(ClaudeCredential.Parse("{\"mcpOAuth\":{}}"u8.ToArray()));
    }

    [Fact]
    public void ResetEstimator()
    {
        var b = Fx.T("2026-09-21T16:00:00Z");
        List<Core.ResetEstimator.Sample> s = [new(b, 37), new(b.AddMinutes(15), 2), new(b.AddMinutes(30), 3)];
        Assert.Equal(b.AddMinutes(7.5).AddHours(5), Core.ResetEstimator.SessionReset(s, b.AddMinutes(30)));
        Assert.Null(Core.ResetEstimator.SessionReset([new(b, 0), new(b.AddMinutes(180), 3)], b.AddMinutes(180)));
    }

    [Fact]
    public void CodexWhamAndMerge()
    {
        var weekly = CodexUsageParser.ParseWham(Fx.Data("codex/usage/wham-weekly-only.json"), _now)!;
        Assert.Equal("prolite", weekly.Limits.PlanType);
        var merged = CodexUsageParser.Merge([weekly], _now);
        Assert.Equal(["Weekly"], merged.Windows.Select(w => w.Label));
        Assert.Equal(62, merged.Windows[0].UsedPercent);
        Assert.Equal("Pro Lite", merged.Plan);
        var reached = CodexUsageParser.ParseWham(Fx.Data("codex/usage/wham-5h-weekly-reached.json"), _now)!;
        Assert.Equal(_now.AddSeconds(1200), reached.Limits.Windows[0].ResetsAt);
        Assert.True(CodexUsageParser.Merge([reached], _now).LimitReached);
        var oldRollout = new CodexRateLimitObservation(new CodexRateLimits("codex", "plus",
            [new RateWindowObservation(300, 50, _now.AddMinutes(10))], null), _now.AddHours(-2), UsageSource.CodexRollout);
        Assert.Equal(["Weekly"], CodexUsageParser.Merge([weekly, oldRollout], _now).Windows.Select(w => w.Label));
        Assert.Equal(["5h"], CodexUsageParser.Merge([oldRollout], _now).Windows.Select(w => w.Label));
    }

    [Fact]
    public void CodexAuthJwt()
    {
        using var dir = new TempDir();
        var path = dir.Write("auth.json", Fx.Text("codex/usage/auth-chatgpt.json"));
        var auth = CodexAuth.Load(path)!;
        Assert.True(auth.UsesChatGpt);
        Assert.Equal("acct-FAKE", auth.AccountId);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1_790_800_000), auth.ExpiresAt);
    }
}

public class PresentationTests
{
    private readonly DateTimeOffset _t0 = DateTimeOffset.FromUnixTimeSeconds(1_790_000_000);

    [Fact]
    public void LampsAndOrdering()
    {
        var sessions = new[]
        {
            Fx.Session("a", Provider.Claude, SessionState.Working, _t0),
            Fx.Session("b", Provider.Claude, SessionState.Attention(AttentionReason.Approval("Bash", null)), _t0),
            Fx.Session("c", Provider.Codex, SessionState.WaitingForUser, _t0.AddSeconds(-60)),
            Fx.Session("d", Provider.Codex, SessionState.WaitingForUser, _t0.AddHours(-2)),
        };
        var lamps = Aggregator.Lamps(sessions, _t0);
        Assert.Equal(new LampTriple(LampMode.Blinking, LampMode.Off, LampMode.Breathing), LampTriple.From(lamps[Provider.Claude]));
        Assert.Equal(new LampTriple(LampMode.Off, LampMode.Steady, LampMode.Off), LampTriple.From(lamps[Provider.Codex]));
        Assert.Equal(["b", "c", "a", "d"], Aggregator.Ordered(sessions, _t0).Select(s => s.Id));
    }

    [Fact]
    public void SmootherHoldsYellowFlaps()
    {
        var s = new StateSmoother(TimeSpan.FromSeconds(1.5));
        var working = Fx.Session("a", Provider.Claude, SessionState.Working, _t0);
        s.Apply([working], _t0);
        var yellow = working with { State = SessionState.WaitingForUser };
        Assert.Equal(StateKind.Working, s.Apply([yellow], _t0.AddSeconds(1)).Sessions[0].State.Kind);
        Assert.Equal(StateKind.WaitingForUser, s.Apply([yellow], _t0.AddSeconds(2.6)).Sessions[0].State.Kind);
    }

    [Fact]
    public void PeekDetectionAndQueue()
    {
        var d = new PeekEventDetector();
        Assert.Empty(d.Diff([Fx.Session("a", Provider.Claude, SessionState.Working, _t0)], _t0));
        var red = d.Diff([Fx.Session("a", Provider.Claude, SessionState.Attention(AttentionReason.Approval("Bash", null)), _t0)], _t0.AddSeconds(5));
        Assert.Equal("needs approval — Bash", red.Single().Detail);

        var q = new PeekQueue();
        var done = new PeekEvent("done", PeekKind.Finished, Provider.Codex, LampColor.Yellow, "Done", "", null, _t0);
        Assert.Equal(PeekQueue.EffectKind.Show, q.Enqueue(done, _t0).Kind);
        var attn = new PeekEvent("attn", PeekKind.Attention, Provider.Claude, LampColor.Red, "Attn", "", null, _t0);
        Assert.Equal(PeekQueue.EffectKind.None, q.Enqueue(attn, _t0.AddSeconds(0.5)).Kind);
        Assert.Equal(PeekQueue.EffectKind.Show, q.Expire(_t0.AddSeconds(3)).Kind);
        Assert.Equal("attn", q.Current!.Key);
        Assert.Equal(PeekQueue.EffectKind.Hide, q.Expire(_t0.AddSeconds(8)).Kind);
    }

    [Fact]
    public void Formatting()
    {
        Assert.Equal("2h 13m", Formatters.Countdown(TimeSpan.FromSeconds(2 * 3600 + 13 * 60 + 5)));
        Assert.Equal("1d 16h", Formatters.Countdown(TimeSpan.FromHours(40)));
        Assert.Equal("now", Formatters.Elapsed(_t0.AddSeconds(-2), _t0));
        Assert.Equal(UsageLevel.High, Formatters.Level(85));
    }
}

public class SourceIntegrationTests
{
    [Fact]
    public void ClaudeSourceFlowsRegistryAndTranscriptChanges()
    {
        using var dir = new TempDir();
        var paths = new ClaudePaths(dir.Path, Path.Combine(dir.Path, "desktop"), Path.Combine(dir.Path, ".claude.json"));
        const string sid = "00000000-0000-4000-8000-000000000001";
        var transcript = $"projects/-Users-test-Projects-demo/{sid}.jsonl";
        dir.Write(transcript, "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"hi\"},\"timestamp\":\"2026-09-22T19:10:00.000Z\"}\n");
        var procStart = TimeParsing.ProcStart("Tue Sep 22 19:03:03 2026")!.Value;
        var entry = $"{{\"pid\":4242,\"sessionId\":\"{sid}\",\"cwd\":\"/Users/test/Projects/demo\",\"kind\":\"interactive\",\"entrypoint\":\"cli\",\"status\":\"busy\",\"procStart\":\"Tue Sep 22 19:03:03 2026\",\"statusUpdatedAt\":{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}}}";
        dir.Write("sessions/4242.json", entry);
        var inspector = new FakeInspector { Alive = [4242], Starts = { [4242] = procStart } };
        using var source = new ClaudeSessionSource(paths, inspector);
        ProviderSessions? last = null;
        source.Changed += b => last = b;
        source.Refresh();
        Assert.Equal("Thinking…", last!.Sessions.Single().Activity);

        File.AppendAllText(Path.Combine(dir.Path, transcript),
            "{\"type\":\"assistant\",\"message\":{\"id\":\"m1\",\"role\":\"assistant\",\"stop_reason\":\"tool_use\",\"content\":[{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Bash\",\"input\":{\"command\":\"make test\",\"description\":\"Run the tests\"}}]},\"timestamp\":\"2026-09-22T19:10:05.000Z\"}\n");
        source.Rescan();
        Assert.Equal("Running Bash: Run the tests", last!.Sessions.Single().Activity);

        dir.Write("sessions/4242.json", entry.Replace("\"status\":\"busy\"", "\"status\":\"waiting\",\"waitingFor\":\"permission prompt\""));
        source.Rescan();
        Assert.Equal(SessionState.Attention(AttentionReason.Approval("Bash", "make test")), last!.Sessions.Single().State);

        inspector.Alive.Clear();
        source.Rescan();
        Assert.Empty(last!.Sessions);
    }

    private sealed class FakeInspector : IProcessInspector
    {
        public HashSet<int> Alive { get; set; } = [];
        public Dictionary<int, DateTimeOffset> Starts { get; } = [];
        public bool IsAlive(int pid) => Alive.Contains(pid);
        public DateTimeOffset? StartTime(int pid) => Starts.TryGetValue(pid, out var s) ? s : null;
        public int? Parent(int pid) => null;
        public string? ProcessName(int pid) => null;
        public IReadOnlyList<int> FileHolders(string path) => [];
        public IReadOnlyList<int> PidsNamed(string processName) => [];
    }
}

public class PlatformTests
{
    [Fact]
    public void ThreadIndexReadsSqliteWithoutSideFiles()
    {
        using var dir = new TempDir();
        var db = Path.Combine(dir.Path, "state_5.sqlite");
        using (var conn = new Microsoft.Data.Sqlite.SqliteConnection($"Data Source={db};Pooling=False"))
        {
            conn.Open();
            using var cmd = conn.CreateCommand();
            cmd.CommandText = "CREATE TABLE threads(id TEXT PRIMARY KEY, rollout_path TEXT, cwd TEXT, title TEXT, name TEXT, archived INTEGER, agent_role TEXT, updated_at_ms INTEGER);" +
                              "INSERT INTO threads VALUES('a','/r/a.jsonl','/p/one','first msg','Named thread',0,NULL,1789802047286);" +
                              "INSERT INTO threads VALUES('b','/r/b.jsonl','/p/two','Only title','',1,NULL,NULL);" +
                              "INSERT INTO threads VALUES('c','/r/c.jsonl','/p/three',NULL,NULL,0,'worker',NULL);";
            cmd.ExecuteNonQuery();
        }
        var before = Directory.GetFiles(dir.Path).Select(Path.GetFileName).Order().ToArray();
        var info = CodexThreadIndex.Load(["a", "b", "c"], new CodexPaths(dir.Path));
        Assert.Equal("Named thread", info["a"].Title);
        Assert.Equal(TimeParsing.Epoch(1_789_802_047_286), info["a"].UpdatedAt);
        Assert.True(info["b"].Archived);
        Assert.True(info["c"].IsSubagent);
        Assert.Equal(before, Directory.GetFiles(dir.Path).Select(Path.GetFileName).Order().ToArray());
    }

    [Fact]
    public void RestartManagerSeesAFileWeHoldOpen()
    {
        if (!OperatingSystem.IsWindows()) return;   // Windows-only API; runs on the Windows CI runner.
        using var dir = new TempDir();
        var path = dir.Write("00000000-0000-4000-8000-00000000000c.lock", "");
        using var held = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite);
        var holders = new LiveProcessInspector().FileHolders(path);
        Assert.Contains(Environment.ProcessId, holders);
    }

    [Fact]
    public void ProcessInspectorKnowsOurselves()
    {
        var inspector = new LiveProcessInspector();
        Assert.True(inspector.IsAlive(Environment.ProcessId));
        Assert.NotNull(inspector.StartTime(Environment.ProcessId));
        Assert.False(inspector.IsAlive(int.MaxValue - 7));
        if (OperatingSystem.IsWindows()) Assert.NotNull(inspector.Parent(Environment.ProcessId));
    }
}
