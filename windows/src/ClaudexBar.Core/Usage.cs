using System.Globalization;
using System.Net;
using System.Text.Json.Nodes;

namespace ClaudexBar.Core;

public sealed record HttpResult(int Status, Dictionary<string, string> Headers, byte[] Body);

public interface IHttp
{
    Task<HttpResult?> GetAsync(Uri url, IReadOnlyDictionary<string, string> headers, TimeSpan timeout, CancellationToken ct = default);
}

/// <summary>No cookies, no cache, redirects refused (an Authorization header never follows a redirect).</summary>
public sealed class LiveHttp : IHttp
{
    private readonly HttpClient _client = new(new SocketsHttpHandler
    {
        AllowAutoRedirect = false,
        UseCookies = false,
        AutomaticDecompression = DecompressionMethods.All,
    });

    public async Task<HttpResult?> GetAsync(Uri url, IReadOnlyDictionary<string, string> headers, TimeSpan timeout, CancellationToken ct = default)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(timeout);
        using var req = new HttpRequestMessage(HttpMethod.Get, url);
        foreach (var (k, v) in headers) req.Headers.TryAddWithoutValidation(k, v);
        try
        {
            using var resp = await _client.SendAsync(req, cts.Token).ConfigureAwait(false);
            var body = await resp.Content.ReadAsByteArrayAsync(cts.Token).ConfigureAwait(false);
            var h = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var (k, v) in resp.Headers) h[k.ToLowerInvariant()] = string.Join(",", v);
            return new HttpResult((int)resp.StatusCode, h, body);
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or OperationCanceledException) { return null; }
    }
}

public static class RetryAfter
{
    public static TimeSpan? Parse(string? value, DateTimeOffset now)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        if (double.TryParse(value.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var s) && s >= 0) return TimeSpan.FromSeconds(s);
        if (DateTimeOffset.TryParseExact(value.Trim(), "r", CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var d))
            return d > now ? d - now : TimeSpan.Zero;
        return null;
    }
}

public sealed class BackoffPolicy
{
    public int ConsecutiveFailures { get; private set; }
    public void Succeeded() => ConsecutiveFailures = 0;

    public TimeSpan RateLimited(TimeSpan? retryAfter, double jitter)
    {
        ConsecutiveFailures++;
        double b = retryAfter is { } r ? Math.Max(r.TotalSeconds, 60) : Math.Min(300 * Math.Pow(2, ConsecutiveFailures - 1), 3600);
        return TimeSpan.FromSeconds(b * (1 + 0.2 * jitter));
    }

    public TimeSpan Failed(double jitter)
    {
        ConsecutiveFailures++;
        return TimeSpan.FromSeconds(Math.Min(30 * Math.Pow(2, ConsecutiveFailures - 1), 1800) * (1 + 0.2 * jitter));
    }
}

// MARK: - Claude usage

public sealed record ClaudeCredential(SecretToken Token, DateTimeOffset? ExpiresAt, List<string> Scopes, string? SubscriptionType, string? RateLimitTier)
{
    public bool IsUsable(DateTimeOffset now) =>
        !Token.IsEmpty && !(ExpiresAt is { } e && e <= now.AddSeconds(60)) && (Scopes.Count == 0 || Scopes.Contains("user:profile"));

    /// <summary>`{"claudeAiOauth":{accessToken, expiresAt, scopes, …}}`, possibly hex-encoded.</summary>
    public static ClaudeCredential? Parse(byte[] raw)
    {
        var text = System.Text.Encoding.UTF8.GetString(raw).Trim();
        if (!text.StartsWith('{') && text.Length % 2 == 0 && text.All(Uri.IsHexDigit))
        {
            try { text = System.Text.Encoding.UTF8.GetString(Convert.FromHexString(text)); }
            catch (FormatException) { return null; }
        }
        var oauth = Json.Parse(text).Get("claudeAiOauth");
        if (oauth is not JsonObject) return null;
        var expires = oauth.Num("expiresAt") is { } ms ? (ms > 0 ? TimeParsing.Epoch(ms) : DateTimeOffset.MinValue) : null;
        var scopes = oauth.Arr("scopes")?.Select(s => s.AsStr()).OfType<string>().ToList()
                     ?? oauth.Str("scopes")?.Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList() ?? [];
        return new ClaudeCredential(new SecretToken(oauth.Str("accessToken") ?? ""), expires, scopes,
            oauth.Str("subscriptionType"), oauth.Str("rateLimitTier"));
    }
}

public sealed record ClaudeUsageReading(List<UsageWindow> Windows, DateTimeOffset ObservedAt, UsageSource Source);

public static class ClaudeUsageParser
{
    public static ClaudeUsageReading? ParseOAuth(byte[] data, DateTimeOffset observedAt)
    {
        if (Json.Parse(data) is not JsonObject root) return null;
        var windows = new List<UsageWindow>();
        UsageWindow W(string id, WindowKind kind, string label, double pct, DateTimeOffset? resets, TimeSpan? duration) =>
            new(id, kind, label, pct, resets, duration, UsageSource.ClaudeOAuthApi, observedAt);
        foreach (var row in root.Arr("limits") ?? [])
        {
            if ((row.Num("percent") ?? row.Num("utilization")) is not { } pct) continue;
            var resets = TimeParsing.Flexible(row.Get("resets_at"));
            var kind = row.Str("kind") ?? "";
            var model = row.Get("scope").Get("model").Str("display_name") ?? row.Get("scope").Get("surface").Str("display_name");
            switch (kind)
            {
                case "session": windows.Add(W("claude.five_hour", WindowKind.Session5h, "5h", pct, resets, TimeSpan.FromHours(5))); break;
                case "weekly_all": windows.Add(W("claude.seven_day", WindowKind.Weekly, "Weekly", pct, resets, TimeSpan.FromDays(7))); break;
                case "weekly_scoped":
                    var name = model ?? "Scoped";
                    windows.Add(W($"claude.weekly.{name.ToLowerInvariant()}", WindowKind.Scoped(name), $"Weekly · {name}", pct, resets, TimeSpan.FromDays(7)));
                    break;
                default:
                    var group = row.Str("group") ?? kind;
                    if (group.Length == 0) break;
                    windows.Add(W($"claude.{(kind.Length == 0 ? group : kind)}", WindowKind.Other(group),
                        CultureInfo.InvariantCulture.TextInfo.ToTitleCase(group), pct, resets, null));
                    break;
            }
        }
        if (windows.Count == 0)
        {
            (string Key, WindowKind Kind, string Label, TimeSpan Dur)[] legacy =
            [
                ("five_hour", WindowKind.Session5h, "5h", TimeSpan.FromHours(5)),
                ("seven_day", WindowKind.Weekly, "Weekly", TimeSpan.FromDays(7)),
                ("seven_day_opus", WindowKind.Scoped("Opus"), "Weekly · Opus", TimeSpan.FromDays(7)),
                ("seven_day_sonnet", WindowKind.Scoped("Sonnet"), "Weekly · Sonnet", TimeSpan.FromDays(7)),
            ];
            foreach (var (key, kind, label, dur) in legacy)
            {
                if (root.Get(key).Num("utilization") is not { } u) continue;
                var id = kind.Tag == WindowKindTag.WeeklyScoped ? $"claude.weekly.{kind.Name!.ToLowerInvariant()}" : $"claude.{key}";
                windows.Add(W(id, kind, label, u, TimeParsing.Flexible(root.Get(key).Get("resets_at")), dur));
            }
        }
        return new ClaudeUsageReading(windows, observedAt, UsageSource.ClaudeOAuthApi);
    }

    /// <summary>Claude desktop's plan-usage-history.json (percentages only, with reset estimates).</summary>
    public static ClaudeUsageReading? ParseDesktopCache(byte[] data, string? organization)
    {
        var samples = Json.Parse(data).Arr("samples");
        if (samples is null || samples.Count == 0) return null;
        double T(JsonNode? s) => s.Num("t") ?? 0;
        var matching = organization is null ? [] : samples.Where(s => s.Str("org") == organization).ToList();
        var pool = (matching.Count > 0 ? matching : samples.ToList()).OrderBy(T).ToList();
        var sample = pool[^1];
        if (TimeParsing.Epoch(T(sample)) is not { } at) return null;
        var values = sample.Get("u") ?? sample;
        (string Key, string Id, WindowKind Kind, string Label, TimeSpan Dur)[] keys =
        [
            ("fh", "claude.five_hour", WindowKind.Session5h, "5h", TimeSpan.FromHours(5)),
            ("sd", "claude.seven_day", WindowKind.Weekly, "Weekly", TimeSpan.FromDays(7)),
            ("so", "claude.weekly.opus", WindowKind.Scoped("Opus"), "Weekly · Opus", TimeSpan.FromDays(7)),
            ("sn", "claude.weekly.sonnet", WindowKind.Scoped("Sonnet"), "Weekly · Sonnet", TimeSpan.FromDays(7)),
        ];
        var windows = new List<UsageWindow>();
        foreach (var (key, id, kind, label, dur) in keys)
        {
            if (values.Num(key) is not { } v) continue;
            var series = pool.Select(s => (T: TimeParsing.Epoch(T(s)), V: (s.Get("u") ?? s).Num(key)))
                .Where(x => x.T is not null && x.V is not null).Select(x => new ResetEstimator.Sample(x.T!.Value, x.V!.Value)).ToList();
            DateTimeOffset? estimate = kind.Tag switch
            {
                WindowKindTag.Session5h => ResetEstimator.SessionReset(series, at),
                WindowKindTag.Weekly => ResetEstimator.WeeklyReset(series, at),
                _ => null,
            };
            windows.Add(new UsageWindow(id, kind, label, v, estimate, dur, UsageSource.ClaudeDesktopCache, at, ResetIsEstimate: estimate is not null));
        }
        return windows.Count == 0 ? null : new ClaudeUsageReading(windows, at, UsageSource.ClaudeDesktopCache);
    }

    public static List<UsageWindow> Merge(ClaudeUsageReading? api, ClaudeUsageReading? cache, DateTimeOffset now)
    {
        var ids = new List<string>();
        foreach (var w in (api?.Windows ?? []).Concat(cache?.Windows ?? []))
            if (!ids.Contains(w.Id)) ids.Add(w.Id);
        var output = new List<UsageWindow>();
        foreach (var id in ids)
        {
            var a = api?.Windows.FirstOrDefault(w => w.Id == id);
            var c = cache?.Windows.FirstOrDefault(w => w.Id == id);
            UsageWindow pick;
            if (a is not null && c is not null)
            {
                if ((c.FetchedAt - a.FetchedAt).TotalSeconds > 1)
                {
                    pick = c;
                    if (a.ResetsAt is { } r && r > c.FetchedAt) pick = pick with { ResetsAt = r, ResetIsEstimate = false };
                }
                else pick = a;
            }
            else pick = (a ?? c)!;
            output.Add(pick.Resolved(now));
        }
        return output.OrderBy(w => WindowLabeler.Order(w.Kind)).ToList();
    }

    public static string? PlanLabel(string? subscriptionType, string? tier)
    {
        var t = (tier ?? "").ToLowerInvariant();
        var s = (subscriptionType ?? "").ToLowerInvariant();
        if (t.Contains("20x")) return "Max 20×";
        if (t.Contains("5x")) return "Max 5×";
        if (s.Contains("max")) return "Max";
        if (s.Contains("pro")) return "Pro";
        if (s.Contains("team")) return "Team";
        if (s.Contains("enterprise")) return "Enterprise";
        return subscriptionType is null ? null : CultureInfo.InvariantCulture.TextInfo.ToTitleCase(subscriptionType);
    }
}

/// <summary>Estimates reset times from sampled history; only when the sampling gap is small.</summary>
public static class ResetEstimator
{
    public readonly record struct Sample(DateTimeOffset T, double V);

    private static readonly TimeSpan FiveHours = TimeSpan.FromHours(5);
    private static readonly TimeSpan Week = TimeSpan.FromDays(7);

    public static DateTimeOffset? SessionReset(List<Sample> s, DateTimeOffset observedAt, TimeSpan? maxUncertainty = null)
    {
        var max = maxUncertainty ?? TimeSpan.FromMinutes(30);
        if (s.Count == 0 || s[^1].V <= 0) return null;
        int k = s.Count - 1;
        while (k > 0)
        {
            var prev = s[k - 1];
            var cur = s[k];
            if (prev.V <= 0 || cur.V < prev.V - 1 || cur.T - prev.T >= FiveHours) break;
            k--;
        }
        var hi = s[k].T;
        var lo = k > 0 ? s[k - 1].T : hi - FiveHours;
        if (lo < observedAt - FiveHours) lo = observedAt - FiveHours;
        if (hi < lo || hi - lo > max) return null;
        var reset = lo + (hi - lo) / 2 + FiveHours;
        return reset > observedAt ? reset : null;
    }

    public static DateTimeOffset? WeeklyReset(List<Sample> s, DateTimeOffset observedAt, TimeSpan? maxUncertainty = null)
    {
        var max = maxUncertainty ?? TimeSpan.FromHours(2);
        for (int j = s.Count - 1; j >= 1; j--)
        {
            if (!(s[j].V < s[j - 1].V - 5)) continue;
            var width = s[j].T - s[j - 1].T;
            if (width > max) return null;
            var reset = s[j - 1].T + width / 2 + Week;
            return reset > observedAt ? reset : null;
        }
        return null;
    }
}

// MARK: - Codex usage

public sealed record CodexAuth(string? Mode, SecretToken? AccessToken, string? AccountId, DateTimeOffset? ExpiresAt)
{
    public bool UsesChatGpt => (Mode ?? "chatgpt").Equals("chatgpt", StringComparison.OrdinalIgnoreCase);

    public static CodexAuth? Load(string path)
    {
        var data = FileReading.ReadAll(path, 64 * 1024);
        if (data is null || Json.Parse(data) is not JsonObject root) return null;
        var token = root.Get("tokens").Str("access_token");
        return new CodexAuth(root.Str("auth_mode"), token is null ? null : new SecretToken(token),
            root.Get("tokens").Str("account_id"), token is null ? null : JwtExpiry(token));
    }

    public static DateTimeOffset? JwtExpiry(string token)
    {
        var parts = token.Split('.');
        if (parts.Length < 2) return null;
        var b64 = parts[1].Replace('-', '+').Replace('_', '/');
        while (b64.Length % 4 != 0) b64 += "=";
        try
        {
            var exp = Json.Parse(Convert.FromBase64String(b64)).Num("exp");
            return exp is { } e ? DateTimeOffset.FromUnixTimeSeconds((long)e) : null;
        }
        catch (FormatException) { return null; }
    }
}

public static class CodexUsageParser
{
    public static CodexRateLimitObservation? ParseWham(byte[] data, DateTimeOffset observedAt)
    {
        var root = Json.Parse(data);
        var rl = root.Get("rate_limit");
        if (rl is not JsonObject) return null;
        RateWindowObservation? Window(JsonNode? w)
        {
            if (w is not JsonObject) return null;
            var seconds = w.Num("limit_window_seconds");
            var resets = TimeParsing.Flexible(w.Get("reset_at"))
                         ?? (w.Num("reset_after_seconds") is { } after ? observedAt.AddSeconds(after) : null);
            return new RateWindowObservation(seconds / 60, w.Num("used_percent"), resets);
        }
        var windows = new[] { Window(rl.Get("primary_window")), Window(rl.Get("secondary_window")) }.OfType<RateWindowObservation>().ToList();
        var reached = root.Str("rate_limit_reached_type") ?? root.Get("rate_limit_reached_type").Str("type");
        if (reached is null && rl.Bool("limit_reached") == true) reached = "limit_reached";
        return new CodexRateLimitObservation(new CodexRateLimits("codex", root.Str("plan_type"), windows, reached), observedAt,
            UsageSource.CodexWham);
    }

    public static string? PlanLabel(string? raw) => raw?.ToLowerInvariant() switch
    {
        null or "" => null,
        "prolite" or "pro_lite" => "Pro Lite",
        "pro" => "Pro",
        "plus" => "Plus",
        "team" => "Team",
        "business" => "Business",
        "enterprise" => "Enterprise",
        "edu" => "Edu",
        "free" => "Free",
        _ => CultureInfo.InvariantCulture.TextInfo.ToTitleCase(raw),
    };

    public static (List<UsageWindow> Windows, string? Plan, bool LimitReached, DateTimeOffset? Newest) Merge(
        IEnumerable<CodexRateLimitObservation> observations, DateTimeOffset now)
    {
        var codex = observations.Where(o => o.Limits.LimitId is null or "codex").OrderByDescending(o => o.ObservedAt).ToList();
        if (codex.Count == 0) return ([], null, false, null);
        var newest = codex[0];
        var authoritative = codex.FirstOrDefault(o => o.Source != UsageSource.CodexRollout);
        var pool = authoritative is not null && now - authoritative.ObservedAt < TimeSpan.FromHours(1) ? [authoritative] : codex;
        var byDuration = new Dictionary<int, (RateWindowObservation W, CodexRateLimitObservation Obs)>();
        foreach (var obs in pool)
            foreach (var w in obs.Limits.Windows.Where(w => w.UsedPercent is not null && w.Minutes is not null))
            {
                int key = (int)Math.Round(w.Minutes!.Value);
                byDuration.TryAdd(key, (w, obs));
            }
        var windows = new List<UsageWindow>();
        foreach (var (minutes, (w, obs)) in byDuration)
        {
            if (now - obs.ObservedAt > TimeSpan.FromDays(8)) continue;
            windows.Add(new UsageWindow($"codex.{minutes}", WindowLabeler.Kind(minutes), WindowLabeler.Label(minutes), w.UsedPercent,
                w.ResetsAt, TimeSpan.FromMinutes(minutes), obs.Source, obs.ObservedAt).Resolved(now));
        }
        windows.Sort((a, b) => (a.WindowDuration ?? TimeSpan.Zero).CompareTo(b.WindowDuration ?? TimeSpan.Zero));
        var plan = PlanLabel(codex.Select(o => o.Limits.PlanType).FirstOrDefault(p => p is not null));
        bool reached = now - newest.ObservedAt < TimeSpan.FromHours(1) && newest.Limits.ReachedType is not null;
        return (windows, plan, reached || windows.Any(w => (w.UsedPercent ?? 0) >= 100), newest.ObservedAt);
    }
}
