namespace ClaudexBar.Core;

public enum YellowLamp { Off, Parked, Fresh }

/// <summary>Which lamps of one agent's traffic light are lit, aggregated over its sessions.</summary>
public sealed record AgentLamps(Provider Provider)
{
    public bool Green { get; init; }
    public YellowLamp Yellow { get; init; }
    public bool Red { get; init; }
    public int Working { get; init; }
    public int WaitingFresh { get; init; }
    public int WaitingParked { get; init; }
    public int Attention { get; init; }
    public int Total => Working + WaitingFresh + WaitingParked + Attention;
}

public sealed record LampPolicy(TimeSpan FreshWindow)
{
    public static readonly LampPolicy Default = new(TimeSpan.FromMinutes(30));
}

public static class Aggregator
{
    public static Dictionary<Provider, AgentLamps> Lamps(IEnumerable<AgentSession> sessions, DateTimeOffset now, LampPolicy? policy = null)
    {
        policy ??= LampPolicy.Default;
        var result = new Dictionary<Provider, AgentLamps>();
        foreach (var p in ProviderInfo.All)
        {
            var mine = sessions.Where(s => s.Provider == p).ToList();
            int working = mine.Count(s => s.State.Kind == StateKind.Working);
            int attention = mine.Count(s => s.State.Kind == StateKind.NeedsAttention);
            int fresh = mine.Count(s => s.State.Kind == StateKind.WaitingForUser && now - s.StateSince < policy.FreshWindow);
            int parked = mine.Count(s => s.State.Kind == StateKind.WaitingForUser) - fresh;
            result[p] = new AgentLamps(p)
            {
                Green = working > 0,
                Red = attention > 0,
                Yellow = fresh > 0 ? YellowLamp.Fresh : parked > 0 ? YellowLamp.Parked : YellowLamp.Off,
                Working = working,
                WaitingFresh = fresh,
                WaitingParked = parked,
                Attention = attention,
            };
        }
        return result;
    }

    /// <summary>
    /// Driver order: red (by reason, longest waiting first), fresh yellow (newest first),
    /// green (most recent change first), parked yellow (newest first).
    /// </summary>
    public static List<AgentSession> Ordered(IEnumerable<AgentSession> sessions, DateTimeOffset now, LampPolicy? policy = null)
    {
        policy ??= LampPolicy.Default;
        int Bucket(AgentSession s) => s.State.Kind switch
        {
            StateKind.NeedsAttention => 0,
            StateKind.WaitingForUser => now - s.StateSince < policy.FreshWindow ? 1 : 3,
            _ => 2,
        };
        var list = sessions.ToList();
        list.Sort((a, b) =>
        {
            int ba = Bucket(a), bb = Bucket(b);
            if (ba != bb) return ba.CompareTo(bb);
            if (a.State.Reason is { } ra && b.State.Reason is { } rb && ra.Rank != rb.Rank) return ra.Rank.CompareTo(rb.Rank);
            if (a.StateSince != b.StateSince)
                return ba == 0 ? a.StateSince.CompareTo(b.StateSince) : b.StateSince.CompareTo(a.StateSince);
            if (a.Provider != b.Provider) return a.Provider.CompareTo(b.Provider);
            int t = string.CompareOrdinal(a.Title, b.Title);
            return t != 0 ? t : string.CompareOrdinal(a.Id, b.Id);
        });
        return list;
    }
}

/// <summary>
/// Holds transitions into yellow for a short grace period so busy→idle→busy flaps don't
/// flash the lamp. Red and green publish immediately.
/// </summary>
public sealed class StateSmoother(TimeSpan? hold = null)
{
    private readonly TimeSpan _hold = hold ?? TimeSpan.FromSeconds(1.5);
    private readonly Dictionary<string, AgentSession> _published = [];
    private readonly Dictionary<string, DateTimeOffset> _pendingSince = [];

    public (List<AgentSession> Sessions, DateTimeOffset? RecheckAt) Apply(IEnumerable<AgentSession> raw, DateTimeOffset now)
    {
        var output = new List<AgentSession>();
        DateTimeOffset? next = null;
        var seen = new HashSet<string>();
        foreach (var s in raw)
        {
            seen.Add(s.Id);
            _published.TryGetValue(s.Id, out var previous);
            bool enteringYellow = s.State.Kind == StateKind.WaitingForUser && previous is not null
                                  && previous.State.Kind != StateKind.WaitingForUser;
            if (enteringYellow)
            {
                var since = _pendingSince.TryGetValue(s.Id, out var p) ? p : now;
                _pendingSince[s.Id] = since;
                if (now - since < _hold)
                {
                    output.Add(previous!);
                    var due = since + _hold;
                    next = next is null || due < next ? due : next;
                    continue;
                }
            }
            _pendingSince.Remove(s.Id);
            _published[s.Id] = s;
            output.Add(s);
        }
        foreach (var id in _published.Keys.Where(k => !seen.Contains(k)).ToList())
        {
            _published.Remove(id);
            _pendingSince.Remove(id);
        }
        return (output, next);
    }
}
