namespace ClaudexBar.Core;

public enum Provider { Claude, Codex }

public static class ProviderInfo
{
    public static readonly Provider[] All = [Provider.Claude, Provider.Codex];

    public static string DisplayName(this Provider p) => p == Provider.Claude ? "Claude" : "Codex";
}

public enum OriginKind { Desktop, Terminal, Ide, Background, Sdk, Other }

public readonly record struct SessionOrigin(OriginKind Kind, string? Raw = null)
{
    public static readonly SessionOrigin Desktop = new(OriginKind.Desktop);
    public static readonly SessionOrigin Terminal = new(OriginKind.Terminal);
    public static readonly SessionOrigin Ide = new(OriginKind.Ide);
    public static readonly SessionOrigin Background = new(OriginKind.Background);
    public static readonly SessionOrigin Sdk = new(OriginKind.Sdk);

    public string Badge => Kind switch
    {
        OriginKind.Desktop => "Desktop",
        OriginKind.Terminal => "Terminal",
        OriginKind.Ide => "IDE",
        OriginKind.Background => "Background",
        OriginKind.Sdk => "SDK",
        _ => string.IsNullOrEmpty(Raw) ? "Other" : Raw!,
    };
}

public enum AttentionKind { Approval, Question, Input, Error, UsageLimit }

/// <summary>Why a session is red. Lower <see cref="Rank"/> is more urgent.</summary>
public sealed record AttentionReason(AttentionKind Kind, string? Tool = null, string? Detail = null)
{
    public static AttentionReason Approval(string? tool, string? detail) => new(AttentionKind.Approval, tool, detail);
    public static AttentionReason Question(string? header) => new(AttentionKind.Question, Detail: header);
    public static AttentionReason Input(string? text) => new(AttentionKind.Input, Detail: text);
    public static AttentionReason Error(string? text) => new(AttentionKind.Error, Detail: text);
    public static readonly AttentionReason UsageLimit = new(AttentionKind.UsageLimit);

    public int Rank => (int)Kind;
}

public enum LampColor { Red, Yellow, Green }

public enum StateKind { Working, WaitingForUser, NeedsAttention }

public sealed record SessionState(StateKind Kind, AttentionReason? Reason = null)
{
    public static readonly SessionState Working = new(StateKind.Working);
    public static readonly SessionState WaitingForUser = new(StateKind.WaitingForUser);
    public static SessionState Attention(AttentionReason reason) => new(StateKind.NeedsAttention, reason);

    public LampColor Lamp => Kind switch
    {
        StateKind.Working => LampColor.Green,
        StateKind.WaitingForUser => LampColor.Yellow,
        _ => LampColor.Red,
    };
}

public enum Confidence { Reported, Inferred }

public sealed record AgentSession(
    string Id,
    Provider Provider,
    SessionState State,
    DateTimeOffset StateSince,
    string Activity,
    string Title,
    string? Project,
    string? Cwd,
    SessionOrigin Origin,
    int? Pid,
    /// <summary>Process name of the desktop app to bring forward (e.g. "Claude"), when known.</summary>
    string? AppHint,
    DateTimeOffset? LastEventAt,
    Confidence Confidence)
{
    public bool IsFresh(DateTimeOffset now, TimeSpan window) =>
        State.Kind == StateKind.WaitingForUser && now - StateSince < window;
}

public enum SourceHealth { Ok, NotInstalled, Degraded }

public sealed record ProviderSessions(Provider Provider, IReadOnlyList<AgentSession> Sessions, SourceHealth Health)
{
    public bool SameAs(ProviderSessions? other) =>
        other is not null && other.Provider == Provider && other.Health == Health && other.Sessions.SequenceEqual(Sessions);
}

public sealed record SessionSnapshot(DateTimeOffset GeneratedAt, IReadOnlyList<AgentSession> Sessions)
{
    public static readonly SessionSnapshot Empty = new(DateTimeOffset.MinValue, []);
}

// MARK: - Usage

public enum UsageSource { ClaudeOAuthApi, ClaudeDesktopCache, CodexWham, CodexRollout, Demo }

public static class UsageSourceInfo
{
    public static string DisplayName(this UsageSource s) => s switch
    {
        UsageSource.ClaudeOAuthApi => "Anthropic API",
        UsageSource.ClaudeDesktopCache => "Claude app",
        UsageSource.CodexWham => "ChatGPT API",
        UsageSource.CodexRollout => "Codex logs",
        _ => "Demo",
    };
}

public enum WindowKindTag { Session5h, Weekly, WeeklyScoped, Other }

public readonly record struct WindowKind(WindowKindTag Tag, string? Name = null)
{
    public static readonly WindowKind Session5h = new(WindowKindTag.Session5h);
    public static readonly WindowKind Weekly = new(WindowKindTag.Weekly);
    public static WindowKind Scoped(string name) => new(WindowKindTag.WeeklyScoped, name);
    public static WindowKind Other(string name) => new(WindowKindTag.Other, name);
}

public sealed record UsageWindow(
    string Id,
    WindowKind Kind,
    string Label,
    double? UsedPercent,
    DateTimeOffset? ResetsAt,
    TimeSpan? WindowDuration,
    UsageSource Source,
    DateTimeOffset FetchedAt,
    bool IsReset = false,
    bool ResetIsEstimate = false)
{
    /// <summary>If the window has reset since the value was observed, report 0 %.</summary>
    public UsageWindow Resolved(DateTimeOffset now)
    {
        if (ResetsAt is { } r && r <= now && FetchedAt < r)
            return this with { UsedPercent = 0, IsReset = true, ResetsAt = null, ResetIsEstimate = false };
        return this;
    }

    public double? Fraction => UsedPercent is { } v ? Math.Clamp(v / 100, 0, 1) : null;
}

public enum UsageStatusKind { Loading, Ok, Stale, Unavailable }

public sealed record UsageStatus(UsageStatusKind Kind, DateTimeOffset? Since = null, string? Reason = null)
{
    public static readonly UsageStatus Loading = new(UsageStatusKind.Loading);
    public static readonly UsageStatus Ok = new(UsageStatusKind.Ok);
}

public sealed record ProviderUsage(
    Provider Provider,
    string? Plan,
    IReadOnlyList<UsageWindow> Windows,
    bool LimitReached,
    UsageStatus Status,
    DateTimeOffset? LastSuccessAt)
{
    public static ProviderUsage Empty(Provider p) => new(p, null, [], false, UsageStatus.Loading, null);

    public UsageWindow? MostConstrained =>
        Windows.Where(w => w.UsedPercent.HasValue).OrderByDescending(w => w.UsedPercent!.Value).FirstOrDefault();

    public bool SameAs(ProviderUsage? o) =>
        o is not null && o.Provider == Provider && o.Plan == Plan && o.LimitReached == LimitReached &&
        o.Status == Status && o.LastSuccessAt == LastSuccessAt && o.Windows.SequenceEqual(Windows);
}

public sealed record UsageSnapshot(ProviderUsage Claude, ProviderUsage Codex, DateTimeOffset GeneratedAt)
{
    public static readonly UsageSnapshot Empty =
        new(ProviderUsage.Empty(Provider.Claude), ProviderUsage.Empty(Provider.Codex), DateTimeOffset.MinValue);

    public ProviderUsage this[Provider p] => p == Provider.Claude ? Claude : Codex;
}

public static class WindowLabeler
{
    public static WindowKind Kind(double minutes) =>
        Math.Abs(minutes - 300) < 1 ? WindowKind.Session5h
        : Math.Abs(minutes - 10_080) < 1 ? WindowKind.Weekly
        : WindowKind.Other(Label(minutes));

    public static string Label(double minutes)
    {
        if (Math.Abs(minutes - 300) < 1) return "5h";
        if (Math.Abs(minutes - 10_080) < 1) return "Weekly";
        if (Math.Abs(minutes - 1440) < 1) return "Daily";
        if (minutes >= 1440 && minutes % 1440 < 1) return $"{(int)(minutes / 1440)}d";
        if (minutes >= 60) return $"{(int)Math.Round(minutes / 60)}h";
        return $"{(int)minutes}m";
    }

    public static int Order(WindowKind k) => k.Tag switch
    {
        WindowKindTag.Session5h => 0,
        WindowKindTag.Weekly => 1,
        WindowKindTag.WeeklyScoped => 2,
        _ => 3,
    };
}
