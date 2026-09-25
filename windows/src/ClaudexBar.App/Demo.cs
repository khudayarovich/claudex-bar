using ClaudexBar.Core;

namespace ClaudexBar.App;

/// <summary>Scripted sessions and usage for demos, snapshots and visual checks.</summary>
internal static class DemoScenarios
{
    public static AgentSession Session(string id, Provider p, SessionState state, string title, string activity, double agoSeconds,
        DateTimeOffset now, SessionOrigin? origin = null) =>
        new($"{p}:demo-{id}", p, state, now.AddSeconds(-agoSeconds), activity, title, title, null, origin ?? SessionOrigin.Desktop, null,
            null, now, Confidence.Reported);

    private static UsageWindow W(Provider p, double minutes, double pct, TimeSpan? resetIn, DateTimeOffset now) =>
        new($"{p}.{(int)minutes}", WindowLabeler.Kind(minutes), WindowLabeler.Label(minutes), pct, resetIn is { } r ? now + r : null,
            TimeSpan.FromMinutes(minutes), UsageSource.Demo, now);

    public static UsageSnapshot Usage(DateTimeOffset now, double claude5h = 24, double claudeWeek = 41, double codexWeek = 63) => new(
        new ProviderUsage(Provider.Claude, "Max 20×",
            [W(Provider.Claude, 300, claude5h, TimeSpan.FromMinutes(133), now), W(Provider.Claude, 10_080, claudeWeek, TimeSpan.FromHours(76), now)],
            claude5h >= 100, UsageStatus.Ok, now),
        new ProviderUsage(Provider.Codex, "Pro Lite", [W(Provider.Codex, 10_080, codexWeek, TimeSpan.FromHours(40), now)],
            codexWeek >= 100, UsageStatus.Ok, now),
        now);

    public static List<AgentSession> Sessions(string name, DateTimeOffset now) => name switch
    {
        "single-green" => [Session("a", Provider.Claude, SessionState.Working, "claudex-bar", "Running Bash: dotnet build", 95, now)],
        "mixed" =>
        [
            Session("a", Provider.Claude, SessionState.Working, "claudex-bar", "Editing IslandWindow.cs", 312, now),
            Session("b", Provider.Claude, SessionState.Attention(AttentionReason.Approval("Bash", "rm -rf bin")), "api-server",
                "Needs approval · Bash: rm -rf bin", 42, now, SessionOrigin.Terminal),
            Session("c", Provider.Codex, SessionState.WaitingForUser, "report-agent", "Waiting for you", 380, now),
            Session("d", Provider.Codex, SessionState.WaitingForUser, "docs-site", "Waiting for you", 3 * 3600, now),
        ],
        "all-lit" =>
        [
            Session("a", Provider.Claude, SessionState.Working, "claudex-bar", "Running Bash: npm test", 60, now),
            Session("b", Provider.Claude, SessionState.WaitingForUser, "jev-voice-agent", "Waiting for you", 240, now),
            Session("c", Provider.Claude, SessionState.Attention(AttentionReason.Question("Database")), "api-server", "Question: Database", 30, now),
            Session("d", Provider.Codex, SessionState.Working, "report-agent", "Running: uv run pytest -q", 120, now),
            Session("e", Provider.Codex, SessionState.WaitingForUser, "docs-site", "Waiting for you", 600, now),
            Session("f", Provider.Codex, SessionState.Attention(AttentionReason.Error("stream disconnected")), "infra",
                "Error: stream disconnected", 15, now),
        ],
        "attention" =>
        [
            Session("a", Provider.Claude, SessionState.Attention(AttentionReason.Approval("Edit", "Program.cs")), "claudex-bar",
                "Needs approval · Edit: Program.cs", 20, now),
            Session("b", Provider.Codex, SessionState.Attention(AttentionReason.Question("Deploy target")), "report-agent",
                "Question: Deploy target", 65, now),
        ],
        _ => [],
    };
}

internal sealed class DemoFeed(string? scenario) : IStatusFeed
{
    public event Action<SessionSnapshot>? SessionsChanged;
    public event Action<UsageSnapshot>? UsageChanged;
    private CancellationTokenSource? _cts;

    public void Start()
    {
        _cts = new CancellationTokenSource();
        var token = _cts.Token;
        if (scenario is { } name)
        {
            var now = DateTimeOffset.UtcNow;
            SessionsChanged?.Invoke(new SessionSnapshot(now, DemoScenarios.Sessions(name, now)));
            UsageChanged?.Invoke(DemoScenarios.Usage(now, codexWeek: name == "all-lit" ? 44 : 63));
            return;
        }
        Task.Run(() => Timeline(token), token);
    }

    private async Task Timeline(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            var t0 = DateTimeOffset.UtcNow;
            AgentSession Claude(SessionState s, string activity, double since) =>
                DemoScenarios.Session("c", Provider.Claude, s, "claudex-bar", activity, 0, t0) with { StateSince = t0.AddSeconds(since) };
            AgentSession Codex(SessionState s, string activity, double since) =>
                DemoScenarios.Session("r", Provider.Codex, s, "report-agent", activity, 0, t0) with { StateSince = t0.AddSeconds(since) };
            void Push(double claude5h, params AgentSession[] sessions)
            {
                SessionsChanged?.Invoke(new SessionSnapshot(DateTimeOffset.UtcNow, sessions));
                UsageChanged?.Invoke(DemoScenarios.Usage(DateTimeOffset.UtcNow, claude5h));
            }
            async Task Wait(double s) => await Task.Delay(TimeSpan.FromSeconds(s), token);

            Push(24);
            await Wait(2);
            Push(24, Claude(SessionState.Working, "Thinking…", 2));
            await Wait(3);
            Push(24, Claude(SessionState.Working, "Running Bash: dotnet build", 2), Codex(SessionState.Working, "Running: uv run pytest -q", 0));
            await Wait(4);
            Push(24, Claude(SessionState.Attention(AttentionReason.Approval("Bash", "rm -rf bin")), "Needs approval · Bash: rm -rf bin", 9),
                Codex(SessionState.Working, "Editing agent.py", 0));
            await Wait(6);
            Push(78, Claude(SessionState.Working, "Editing IslandWindow.cs", 2), Codex(SessionState.Working, "Running: uv run ruff check .", 0));
            await Wait(5);
            Push(82, Claude(SessionState.Working, "Running Bash: dotnet test", 2), Codex(SessionState.WaitingForUser, "Waiting for you", 20));
            await Wait(6);
            Push(83, Claude(SessionState.Working, "Reading App.cs", 2),
                Codex(SessionState.Attention(AttentionReason.Question("Deploy target")), "Question: Deploy target", 26));
            await Wait(6);
            Push(85, Claude(SessionState.WaitingForUser, "Waiting for you", 37), Codex(SessionState.Working, "Running: make deploy", 32));
            await Wait(8);
        }
    }

    public void RefreshNow() { }

    public void Dispose() => _cts?.Cancel();
}
