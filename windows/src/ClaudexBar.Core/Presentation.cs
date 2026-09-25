namespace ClaudexBar.Core;

public enum LampMode { Off, Dim, Steady, Breathing, Blinking }

public readonly record struct LampTriple(LampMode Red, LampMode Yellow, LampMode Green)
{
    public static readonly LampTriple AllOff = new(LampMode.Off, LampMode.Off, LampMode.Off);

    public static LampTriple From(AgentLamps l) => new(
        l.Red ? LampMode.Blinking : LampMode.Off,
        l.Yellow == YellowLamp.Fresh ? LampMode.Steady : l.Yellow == YellowLamp.Parked ? LampMode.Dim : LampMode.Off,
        l.Green ? LampMode.Breathing : LampMode.Off);

    public static LampTriple Single(SessionState state, bool fresh) => state.Kind switch
    {
        StateKind.NeedsAttention => new(LampMode.Blinking, LampMode.Off, LampMode.Off),
        StateKind.WaitingForUser => new(LampMode.Off, fresh ? LampMode.Steady : LampMode.Dim, LampMode.Off),
        _ => new(LampMode.Off, LampMode.Off, LampMode.Breathing),
    };

    public bool IsAllOff => Red == LampMode.Off && Yellow == LampMode.Off && Green == LampMode.Off;
}

public enum UsageLevel { Normal, Elevated, High, Critical }

public static class Formatters
{
    public static UsageLevel Level(double? percent) =>
        (percent ?? 0) >= 100 ? UsageLevel.Critical : (percent ?? 0) >= 80 ? UsageLevel.High
        : (percent ?? 0) >= 50 ? UsageLevel.Elevated : UsageLevel.Normal;

    public static string Elapsed(DateTimeOffset since, DateTimeOffset now) =>
        now - since < TimeSpan.FromSeconds(5) ? "now" : Durations.Short(now - since);

    public static string Countdown(TimeSpan interval)
    {
        long s = Math.Max(0, (long)interval.TotalSeconds);
        if (s < 60) return "<1m";
        long d = s / 86_400, h = s % 86_400 / 3600, m = s % 3600 / 60;
        if (d > 0) return h > 0 ? $"{d}d {h}h" : $"{d}d";
        if (h > 0) return m > 0 ? $"{h}h {m}m" : $"{h}h";
        return $"{m}m";
    }

    public static string? Reset(UsageWindow w, DateTimeOffset now)
    {
        if (w.IsReset) return "reset";
        if (w.ResetsAt is not { } r || r <= now) return null;
        return (w.ResetIsEstimate ? "≈ " : "") + "resets in " + Countdown(r - now);
    }

    public static string? ShortReset(UsageWindow w, DateTimeOffset now)
    {
        if (w.IsReset) return "reset";
        if (w.ResetsAt is not { } r || r <= now) return null;
        return (w.ResetIsEstimate ? "≈" : "") + "↻ " + Countdown(r - now);
    }

    public static string Percent(double? v) => v is { } p ? $"{(int)Math.Round(p)}%" : "—";
}

public enum PeekKind { Attention = 3, Usage = 2, Finished = 1 }

public sealed record PeekEvent(string Key, PeekKind Kind, Provider Provider, LampColor Lamp, string Title, string Detail,
    string? SessionId, DateTimeOffset CreatedAt)
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public int Priority => (int)Kind;
    public TimeSpan Duration => Kind switch
    {
        PeekKind.Attention => TimeSpan.FromSeconds(5),
        PeekKind.Usage => TimeSpan.FromSeconds(4),
        _ => TimeSpan.FromSeconds(3),
    };
}

/// <summary>Turns snapshot changes into peek events. The first snapshot never peeks.</summary>
public sealed class PeekEventDetector
{
    public TimeSpan FinishedMinimumTurn { get; init; } = TimeSpan.FromSeconds(20);
    private Dictionary<string, AgentSession> _previous = [];
    private bool _sessionsInitialized;
    private readonly Dictionary<string, double> _usageSeen = [];
    private bool _usageInitialized;

    public List<PeekEvent> Diff(IReadOnlyList<AgentSession> sessions, DateTimeOffset now)
    {
        var events = new List<PeekEvent>();
        if (_sessionsInitialized)
        {
            foreach (var s in sessions)
            {
                _previous.TryGetValue(s.Id, out var prev);
                var name = $"{s.Provider.DisplayName()} · {s.Project ?? s.Title}";
                if (s.State.Kind == StateKind.NeedsAttention && prev?.State != s.State)
                    events.Add(new PeekEvent($"attn:{s.Id}", PeekKind.Attention, s.Provider, LampColor.Red, name,
                        AttentionDetail(s.State.Reason!, s.Activity), s.Id, now));
                else if (s.State.Kind == StateKind.WaitingForUser && prev is { State.Kind: StateKind.Working }
                         && now - prev.StateSince >= FinishedMinimumTurn)
                    events.Add(new PeekEvent($"done:{s.Id}", PeekKind.Finished, s.Provider, LampColor.Yellow,
                        $"Done · {s.Project ?? s.Title}", s.Provider.DisplayName(), s.Id, now));
            }
        }
        _previous = sessions.ToDictionary(s => s.Id);
        _sessionsInitialized = true;
        return events;
    }

    private static string AttentionDetail(AttentionReason r, string activity) => r.Kind switch
    {
        AttentionKind.Approval => "needs approval" + (r.Tool is null ? "" : $" — {r.Tool}"),
        AttentionKind.Question => "has a question" + (r.Detail is null ? "" : $" — {r.Detail}"),
        AttentionKind.UsageLimit => "hit the usage limit",
        _ => activity,
    };

    public List<PeekEvent> Diff(UsageSnapshot usage, DateTimeOffset now)
    {
        var events = new List<PeekEvent>();
        foreach (var p in ProviderInfo.All)
            foreach (var w in usage[p].Windows)
            {
                if (w.UsedPercent is not { } v) continue;
                var key = $"{p}:{w.Id}";
                bool had = _usageSeen.TryGetValue(key, out var old);
                _usageSeen[key] = v;
                if (!_usageInitialized || !had) continue;
                foreach (var t in new double[] { 80, 100 })
                {
                    if (!(old < t && v >= t)) continue;
                    var reset = Formatters.Reset(w, now) is { } r ? $" · {r}" : "";
                    events.Add(new PeekEvent($"usage:{key}", PeekKind.Usage, p, t >= 100 ? LampColor.Red : LampColor.Yellow,
                        $"{p.DisplayName()} {w.Label} at {(int)t}%", (t >= 100 ? "limit reached" : "usage is high") + reset, null, now));
                }
            }
        if (usage.Claude.Windows.Count > 0 || usage.Codex.Windows.Count > 0) _usageInitialized = true;
        return events;
    }
}

/// <summary>Priority queue of peeks with coalescing, preemption and hover-hold.</summary>
public sealed class PeekQueue
{
    public enum EffectKind { None, Show, Hide }

    public readonly record struct Effect(EffectKind Kind, PeekEvent? Event = null)
    {
        public static readonly Effect Nothing = new(EffectKind.None);
        public static readonly Effect HideIsland = new(EffectKind.Hide);
    }

    public PeekEvent? Current { get; private set; }
    public DateTimeOffset? ShownAt { get; private set; }
    public DateTimeOffset? Deadline { get; private set; }
    public List<PeekEvent> Queued { get; } = [];
    public bool IsHeld { get; private set; }
    private TimeSpan? _heldRemaining;

    public Effect Enqueue(PeekEvent e, DateTimeOffset now)
    {
        if (Current is { } cur && cur.Key == e.Key)
        {
            Current = cur with { Title = e.Title, Detail = e.Detail };
            if (!IsHeld) Deadline = Max(Deadline ?? now, now.AddSeconds(2));
            return new Effect(EffectKind.Show, Current);
        }
        Queued.RemoveAll(q => q.Key == e.Key);
        if (Current is null) return Show(e, now);
        bool canPreempt = !IsHeld && now - (ShownAt ?? now) >= TimeSpan.FromSeconds(1.2);
        if (e.Priority > Current.Priority && canPreempt)
        {
            if (Current.Kind != PeekKind.Finished) Insert(Current);
            return Show(e, now);
        }
        Insert(e);
        return Effect.Nothing;
    }

    public Effect Expire(DateTimeOffset now)
    {
        if (IsHeld || Deadline is not { } d || now < d.AddMilliseconds(-50)) return Effect.Nothing;
        Current = null;
        ShownAt = null;
        Deadline = null;
        while (Queued.Count > 0)
        {
            var next = Queued[0];
            Queued.RemoveAt(0);
            if (now - next.CreatedAt <= TimeSpan.FromSeconds(30)) return Show(next, now);
        }
        return Effect.HideIsland;
    }

    public void Hold(DateTimeOffset now)
    {
        if (IsHeld || Current is null) return;
        IsHeld = true;
        _heldRemaining = Deadline is { } d ? Max(d, now) - now : null;
        Deadline = null;
    }

    public void Release(DateTimeOffset now)
    {
        if (!IsHeld) return;
        IsHeld = false;
        if (Current is not null) Deadline = now + TimeSpan.FromSeconds(Math.Max(1.5, _heldRemaining?.TotalSeconds ?? 1.5));
        _heldRemaining = null;
    }

    public void Clear()
    {
        Current = null;
        ShownAt = null;
        Deadline = null;
        Queued.Clear();
        IsHeld = false;
        _heldRemaining = null;
    }

    private Effect Show(PeekEvent e, DateTimeOffset now)
    {
        Current = e;
        ShownAt = now;
        Deadline = now + e.Duration;
        return new Effect(EffectKind.Show, e);
    }

    private void Insert(PeekEvent e)
    {
        Queued.Add(e);
        Queued.Sort((a, b) => a.Priority != b.Priority ? b.Priority.CompareTo(a.Priority) : a.CreatedAt.CompareTo(b.CreatedAt));
        if (Queued.Count > 5) Queued.RemoveRange(5, Queued.Count - 5);
    }

    private static DateTimeOffset Max(DateTimeOffset a, DateTimeOffset b) => a > b ? a : b;
}
