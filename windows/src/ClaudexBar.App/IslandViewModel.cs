using ClaudexBar.Core;

namespace ClaudexBar.App;

internal sealed record UsageRowModel(string Id, string Label, string PercentText, double? Fraction, UsageLevel Level, string? ResetText);

internal sealed record ProviderSummary(
    Provider Provider,
    LampTriple Lamps,
    AgentLamps Counts,
    double? Ring,
    UsageLevel RingLevel,
    string? Plan,
    IReadOnlyList<UsageRowModel> Usage,
    string? UsageNote)
{
    public bool SameAs(ProviderSummary? o) =>
        o is not null && o.Provider == Provider && o.Lamps == Lamps && o.Counts == Counts && o.Ring == Ring &&
        o.RingLevel == RingLevel && o.Plan == Plan && o.UsageNote == UsageNote && o.Usage.SequenceEqual(Usage);
}

internal sealed record SessionRowModel(string Id, Provider Provider, LampTriple Lamps, string Title, string Activity,
    DateTimeOffset Since, string Badge, bool IsAttention);

/// <summary>Display-ready state derived from the engine's snapshots.</summary>
internal sealed class IslandViewModel
{
    public event Action? Changed;
    public event Action<List<PeekEvent>>? Peek;

    public ProviderSummary Claude { get; private set; } = Empty(Provider.Claude);
    public ProviderSummary Codex { get; private set; } = Empty(Provider.Codex);
    public IReadOnlyList<SessionRowModel> Rows { get; private set; } = [];
    public int HiddenRows { get; private set; }
    public DateTimeOffset? LastUpdate { get; private set; }
    public LampPolicy Policy { get; set; } = LampPolicy.Default;

    private SessionSnapshot _sessions = SessionSnapshot.Empty;
    private UsageSnapshot _usage = UsageSnapshot.Empty;
    private readonly PeekEventDetector _detector = new();
    private Dictionary<string, AgentSession> _byId = [];
    public const int MaxRows = 6;
    public const int MaxUsageRows = 3;

    private static ProviderSummary Empty(Provider p) =>
        new(p, LampTriple.AllOff, new AgentLamps(p), null, UsageLevel.Normal, null, [], null);

    public ProviderSummary Summary(Provider p) => p == Provider.Claude ? Claude : Codex;
    public AgentSession? Session(string id) => _byId.GetValueOrDefault(id);

    public int UsageRowCount => Math.Min(MaxUsageRows, Math.Max(1, Math.Max(Claude.Usage.Count, Codex.Usage.Count)));

    public void Apply(SessionSnapshot s)
    {
        _sessions = s;
        _byId = s.Sessions.ToDictionary(x => x.Id);
        Recompute(DateTimeOffset.UtcNow);
        var events = _detector.Diff(s.Sessions, DateTimeOffset.UtcNow);
        if (events.Count > 0) Peek?.Invoke(events);
    }

    public void Apply(UsageSnapshot u)
    {
        _usage = u;
        Recompute(DateTimeOffset.UtcNow);
        var events = _detector.Diff(u, DateTimeOffset.UtcNow);
        if (events.Count > 0) Peek?.Invoke(events);
    }

    public void Tick() => Recompute(DateTimeOffset.UtcNow);

    private void Recompute(DateTimeOffset now)
    {
        var lamps = Aggregator.Lamps(_sessions.Sessions, now, Policy);
        var claude = MakeSummary(Provider.Claude, lamps[Provider.Claude], now);
        var codex = MakeSummary(Provider.Codex, lamps[Provider.Codex], now);
        var ordered = Aggregator.Ordered(_sessions.Sessions, now, Policy);
        var rows = ordered.Take(MaxRows).Select(s => new SessionRowModel(
            s.Id, s.Provider, LampTriple.Single(s.State, s.IsFresh(now, Policy.FreshWindow)),
            s.Project is { } p && p != s.Title ? s.Title : s.Title, s.Activity, s.StateSince, s.Origin.Badge,
            s.State.Kind == StateKind.NeedsAttention)).ToList();
        var hidden = Math.Max(0, ordered.Count - rows.Count);
        var newest = new[] { _sessions.GeneratedAt, _usage.GeneratedAt }.Where(d => d != DateTimeOffset.MinValue).DefaultIfEmpty().Max();
        bool changed = !claude.SameAs(Claude) || !codex.SameAs(Codex) || !rows.SequenceEqual(Rows) || hidden != HiddenRows;
        Claude = claude;
        Codex = codex;
        Rows = rows;
        HiddenRows = hidden;
        LastUpdate = newest == default ? null : newest;
        if (changed) Changed?.Invoke();
    }

    private ProviderSummary MakeSummary(Provider p, AgentLamps lamps, DateTimeOffset now)
    {
        var u = _usage[p];
        var constrained = u.MostConstrained;
        var rows = u.Windows.Take(MaxUsageRows).Select(w => new UsageRowModel(w.Id, w.Label, Formatters.Percent(w.UsedPercent),
            w.Fraction, Formatters.Level(w.UsedPercent), Formatters.ShortReset(w, now))).ToList();
        string? note = u.Status.Kind switch
        {
            UsageStatusKind.Loading => "Loading usage…",
            UsageStatusKind.Stale => $"As of {Formatters.Elapsed(u.Status.Since ?? now, now)} ago",
            UsageStatusKind.Unavailable => u.Status.Reason,
            _ => null,
        };
        return new ProviderSummary(p, LampTriple.From(lamps), lamps, constrained?.Fraction, Formatters.Level(constrained?.UsedPercent),
            u.Plan, rows, note);
    }
}
