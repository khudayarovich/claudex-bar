namespace ClaudexBar.Core;

public interface IStatusFeed : IDisposable
{
    event Action<SessionSnapshot>? SessionsChanged;
    event Action<UsageSnapshot>? UsageChanged;
    void Start();
    /// <summary>Rescan now and refresh usage that is older than a minute.</summary>
    void RefreshNow();
}

/// <summary>Coalesces bursts of file events into one callback after a short quiet period.</summary>
internal sealed class Debouncer(TimeSpan delay, Action action) : IDisposable
{
    private readonly Timer _timer = new(_ => action(), null, Timeout.Infinite, Timeout.Infinite);
    public void Poke() => _timer.Change(delay, Timeout.InfiniteTimeSpan);
    public void Dispose() => _timer.Dispose();
}

internal static class Watchers
{
    public static FileSystemWatcher? Create(string dir, string filter, bool recursive, Action<string> changed, Action overflow)
    {
        if (!Directory.Exists(dir)) return null;
        try
        {
            var w = new FileSystemWatcher(dir, filter)
            {
                IncludeSubdirectories = recursive,
                NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.CreationTime,
                InternalBufferSize = 64 * 1024,
            };
            w.Changed += (_, e) => changed(e.FullPath);
            w.Created += (_, e) => changed(e.FullPath);
            w.Deleted += (_, e) => changed(e.FullPath);
            w.Renamed += (_, e) => changed(e.FullPath);
            w.Error += (_, _) => overflow();
            w.EnableRaisingEvents = true;
            return w;
        }
        catch (Exception e) when (e is IOException or ArgumentException or PlatformNotSupportedException) { return null; }
    }
}

// MARK: - Claude sessions

public sealed class ClaudeSessionSource : IDisposable
{
    public event Action<ProviderSessions>? Changed;
    private readonly ClaudePaths _paths;
    private readonly IProcessInspector _inspector;
    private readonly Func<DateTimeOffset> _clock;
    private readonly Lock _gate = new();
    private readonly ClaudeRegistryReader _registry = new();
    private Dictionary<string, ClaudeRegistryReader.Item> _items = [];
    private readonly Dictionary<string, Tracker> _trackers = [];
    private readonly Dictionary<string, DateTimeOffset> _locateAttempts = [];
    private readonly HashSet<string> _dirty = [];
    private bool _registryDirty = true;
    private ProviderSessions? _last;
    private readonly List<FileSystemWatcher> _watchers = [];
    private readonly Debouncer _debounce;
    private Timer? _poll;

    private sealed class Tracker(string path, ForwardTailer tailer, ClaudeTranscriptState state)
    {
        public string Path { get; } = path;
        public ForwardTailer Tailer { get; set; } = tailer;
        public ClaudeTranscriptState State { get; set; } = state;
    }

    public ClaudeSessionSource(ClaudePaths paths, IProcessInspector inspector, Func<DateTimeOffset>? clock = null)
    {
        _paths = paths;
        _inspector = inspector;
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
        _debounce = new Debouncer(TimeSpan.FromMilliseconds(150), Refresh);
    }

    public void Start(TimeSpan? pollInterval = null)
    {
        AttachWatchers();
        var interval = pollInterval ?? TimeSpan.FromSeconds(20);
        _poll = new Timer(_ => PollTick(), null, interval, interval);
        Refresh();
    }

    private void AttachWatchers()
    {
        lock (_gate)
        {
            if (_watchers.Count > 0) return;
            if (Watchers.Create(_paths.SessionsDir, "*.json", false, _ => { lock (_gate) _registryDirty = true; _debounce.Poke(); }, Rescan) is { } a)
                _watchers.Add(a);
            if (Watchers.Create(_paths.ProjectsDir, "*.jsonl", true, OnTranscriptChanged, Rescan) is { } b)
                _watchers.Add(b);
        }
    }

    private void OnTranscriptChanged(string path)
    {
        var sid = Path.GetFileNameWithoutExtension(path);
        lock (_gate)
        {
            if (_trackers.ContainsKey(sid)) _dirty.Add(sid);
            else if (_items.Values.Any(i => i.Entry.SessionId == sid)) { _locateAttempts.Remove(sid); _dirty.Add(sid); }
            else return;
        }
        _debounce.Poke();
    }

    public void Rescan()
    {
        lock (_gate)
        {
            _registryDirty = true;
            foreach (var k in _trackers.Keys) _dirty.Add(k);
        }
        Refresh();
    }

    private void PollTick()
    {
        AttachWatchers();
        lock (_gate)
        {
            _registryDirty = true;
            foreach (var (sid, t) in _trackers)
                if (FileReading.Stat(t.Path)?.Size != t.Tailer.ReadOffset) _dirty.Add(sid);
        }
        Refresh();
    }

    public void Refresh()
    {
        ProviderSessions batch;
        lock (_gate)
        {
            var now = _clock();
            if (_registryDirty)
            {
                _registryDirty = false;
                _items = _registry.Scan(_paths.SessionsDir);
                if (_registry.TornNames.Count > 0) { _registryDirty = true; _debounce.Poke(); }
            }
            var sessions = new List<AgentSession>();
            var live = new HashSet<string>();
            foreach (var item in _items.Values)
            {
                var e = item.Entry;
                if (!e.IsDisplayable || e.Pid is not { } pid || e.SessionId is not { } sid) continue;
                if (!ClaudeLiveness.IsAlive(e, _inspector)) continue;
                live.Add(sid);
                UpdateTracker(sid, e.Cwd, now);
                _trackers.TryGetValue(sid, out var tracker);
                var d = ClaudeStateDeriver.Derive(e, tracker?.State, item.Modified, now);
                sessions.Add(new AgentSession($"claude:{sid}#{pid}", Provider.Claude, d.State, d.Since, d.Activity,
                    ClaudeStateDeriver.Title(e, tracker?.State), e.Cwd is null ? null : PathUtil.BaseName(e.Cwd), e.Cwd, e.Origin, pid,
                    e.Origin.Kind == OriginKind.Desktop ? "Claude" : null, tracker?.State.LastRecordAt, d.Confidence));
            }
            foreach (var gone in _trackers.Keys.Where(k => !live.Contains(k)).ToList()) _trackers.Remove(gone);
            foreach (var gone in _locateAttempts.Keys.Where(k => !live.Contains(k)).ToList()) _locateAttempts.Remove(gone);
            _dirty.Clear();
            sessions.Sort((a, b) => string.CompareOrdinal(a.Id, b.Id));
            batch = new ProviderSessions(Provider.Claude, sessions, Directory.Exists(_paths.Home) ? SourceHealth.Ok : SourceHealth.NotInstalled);
            if (batch.SameAs(_last)) return;
            _last = batch;
        }
        Changed?.Invoke(batch);
    }

    private void UpdateTracker(string sid, string? cwd, DateTimeOffset now)
    {
        if (_trackers.TryGetValue(sid, out var tracker))
        {
            if (!_dirty.Contains(sid)) return;
            var (status, lines) = tracker.Tailer.Poll();
            switch (status)
            {
                case ForwardTailer.Status.Lines:
                    foreach (var line in lines) tracker.State.Apply(ClaudeRecordDecoder.Decode(line));
                    break;
                case ForwardTailer.Status.Missing:
                case ForwardTailer.Status.NeedsBootstrap:
                    if (Bootstrap(tracker.Path) is { } fresh) _trackers[sid] = fresh; else _trackers.Remove(sid);
                    break;
            }
            return;
        }
        if (_locateAttempts.TryGetValue(sid, out var last) && now - last < TimeSpan.FromSeconds(10)) return;
        _locateAttempts[sid] = now;
        if (Locate(sid, cwd) is not { } path) return;
        _locateAttempts.Remove(sid);
        if (Bootstrap(path) is { } t) _trackers[sid] = t;
    }

    private static Tracker? Bootstrap(string path)
    {
        var records = new List<ClaudeRecord>();
        var result = BackwardScanner.Scan(path, 4 << 20, ClaudeRecordDecoder.MaxLineBytes, line =>
        {
            var r = ClaudeRecordDecoder.Decode(line);
            records.Add(r);
            return r.IsTurnStart;
        });
        if (result is null) return null;
        var state = new ClaudeTranscriptState();
        for (int i = records.Count - 1; i >= 0; i--) state.Apply(records[i]);
        return new Tracker(path, new ForwardTailer(path, result.Created, result.EndOffset, ClaudeRecordDecoder.MaxLineBytes), state);
    }

    /// <summary>projects/&lt;cwd with non-alphanumerics → "-"&gt;/&lt;sid&gt;.jsonl, else a search.</summary>
    private string? Locate(string sid, string? cwd)
    {
        var file = sid + ".jsonl";
        if (cwd is not null)
        {
            var encoded = new string(cwd.Select(c => char.IsAsciiLetterOrDigit(c) ? c : '-').ToArray());
            var candidate = Path.Combine(_paths.ProjectsDir, encoded, file);
            if (File.Exists(candidate)) return candidate;
        }
        foreach (var dir in FileReading.List(_paths.ProjectsDir))
        {
            var candidate = Path.Combine(_paths.ProjectsDir, dir, file);
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }

    public void Dispose()
    {
        _poll?.Dispose();
        _debounce.Dispose();
        foreach (var w in _watchers) w.Dispose();
    }
}

// MARK: - Codex sessions

public sealed class CodexSessionSource : IDisposable
{
    public event Action<ProviderSessions>? Changed;
    public event Action<CodexRateLimitObservation>? RateLimitsObserved;
    public TimeSpan RecentWindow { get; init; } = TimeSpan.FromHours(12);
    public TimeSpan ErrorWindow { get; init; } = TimeSpan.FromHours(24);

    private readonly CodexPaths _paths;
    private readonly IProcessInspector _inspector;
    private readonly Func<DateTimeOffset> _clock;
    private readonly Lock _gate = new();
    private readonly Dictionary<string, Tracker> _trackers = [];
    private Dictionary<string, (int Owner, string? Lock)> _loaded = [];
    private Dictionary<string, CodexThreadInfo> _index = [];
    private DateTimeOffset _indexAt = DateTimeOffset.MinValue;
    private readonly Dictionary<string, string?> _rolloutPaths = [];
    private readonly HashSet<string> _dirty = [];
    private bool _loadedDirty = true;
    private bool _inferred;
    private DateTimeOffset? _lastRateAt;
    private ProviderSessions? _last;
    private readonly List<FileSystemWatcher> _watchers = [];
    private readonly Debouncer _debounce;
    private Timer? _poll;

    private sealed class Tracker(string path, ForwardTailer tailer, CodexThreadState state)
    {
        public string Path { get; } = path;
        public ForwardTailer Tailer { get; } = tailer;
        public CodexThreadState State { get; } = state;
    }

    public CodexSessionSource(CodexPaths paths, IProcessInspector inspector, Func<DateTimeOffset>? clock = null)
    {
        _paths = paths;
        _inspector = inspector;
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
        _debounce = new Debouncer(TimeSpan.FromMilliseconds(150), Refresh);
    }

    public void Start(TimeSpan? pollInterval = null)
    {
        AttachWatchers();
        var interval = pollInterval ?? TimeSpan.FromSeconds(20);
        _poll = new Timer(_ => PollTick(), null, interval, interval);
        Refresh();
    }

    private void AttachWatchers()
    {
        lock (_gate)
        {
            if (_watchers.Count > 0) return;
            if (Watchers.Create(_paths.LocksDir, "*.lock", false, _ => { lock (_gate) _loadedDirty = true; _debounce.Poke(); }, Rescan) is { } a)
                _watchers.Add(a);
            if (Watchers.Create(_paths.SessionsDir, "*.jsonl", true, OnRolloutChanged, Rescan) is { } b)
                _watchers.Add(b);
        }
    }

    private void OnRolloutChanged(string path)
    {
        if (CodexPaths.ThreadIdFromRollout(path) is not { } id) return;
        lock (_gate)
        {
            if (_trackers.ContainsKey(id)) _dirty.Add(id); else _loadedDirty = true;
        }
        _debounce.Poke();
    }

    public void Rescan()
    {
        lock (_gate)
        {
            _loadedDirty = true;
            foreach (var k in _trackers.Keys) _dirty.Add(k);
        }
        Refresh();
    }

    private void PollTick()
    {
        AttachWatchers();
        lock (_gate)
        {
            _loadedDirty = true;
            foreach (var (id, t) in _trackers)
                if (FileReading.Stat(t.Path)?.Size != t.Tailer.ReadOffset) _dirty.Add(id);
        }
        Refresh();
    }

    public void Refresh()
    {
        ProviderSessions? batch;
        CodexRateLimitObservation? rate = null;
        lock (_gate)
        {
            var now = _clock();
            if (_loadedDirty)
            {
                _loadedDirty = false;
                DetectLoaded(now);
            }
            var ids = _loaded.Keys.ToList();
            if (ids.Any(id => !_index.ContainsKey(id)) || now - _indexAt > TimeSpan.FromMinutes(5))
            {
                _index = CodexThreadIndex.Load(ids, _paths);
                _indexAt = now;
            }
            var sessions = new List<AgentSession>();
            (CodexRateLimits Limits, DateTimeOffset At)? newestRate = null;
            foreach (var (id, (owner, lockPath)) in _loaded)
            {
                _index.TryGetValue(id, out var info);
                if (info is { Archived: true } or { IsSubagent: true }) continue;
                var path = RolloutPath(id, info);
                if (path is null) continue;
                UpdateTracker(id, path);
                if (!_trackers.TryGetValue(id, out var tracker)) continue;
                var st = tracker.State;
                if (st is { RateLimits: { } rl, RateLimitsAt: { } at } && rl.LimitId is null or "codex" && at > (newestRate?.At ?? DateTimeOffset.MinValue))
                    newestRate = (rl, at);
                var lockBirth = lockPath is null ? null : FileReading.Stat(lockPath)?.Created;
                var context = new CodexThreadContext(owner > 0 ? owner : null, owner > 0 ? _inspector.StartTime(owner) : null, lockBirth,
                    true, _inferred ? Confidence.Inferred : Confidence.Reported);
                var d = CodexStateDeriver.Derive(st, context, lockBirth ?? info?.UpdatedAt ?? now, now);
                if (!IsVisible(st, d, now)) continue;
                var appName = owner > 0 ? OwnerAppName(owner) : null;
                var origin = CodexStateDeriver.Origin(st.Meta, appName);
                var cwd = info?.Cwd ?? st.Cwd;
                var title = info?.Title ?? (cwd is null ? null : PathUtil.BaseName(cwd)) ?? "Codex thread";
                sessions.Add(new AgentSession($"codex:{id}", Provider.Codex, d.State, d.Since, d.Activity, TextSanitizer.OneLine(title, 60),
                    cwd is null ? null : PathUtil.BaseName(cwd), cwd, origin, owner > 0 ? owner : null, appName, st.LastEventAt, d.Confidence));
            }
            foreach (var gone in _trackers.Keys.Where(k => !_loaded.ContainsKey(k)).ToList()) _trackers.Remove(gone);
            _dirty.Clear();
            if (newestRate is { } nr && nr.At > (_lastRateAt ?? DateTimeOffset.MinValue))
            {
                _lastRateAt = nr.At;
                rate = new CodexRateLimitObservation(nr.Limits, nr.At, UsageSource.CodexRollout);
            }
            sessions.Sort((a, b) => string.CompareOrdinal(a.Id, b.Id));
            var health = !Directory.Exists(_paths.Home) ? SourceHealth.NotInstalled : _inferred ? SourceHealth.Degraded : SourceHealth.Ok;
            batch = new ProviderSessions(Provider.Codex, sessions, health);
            if (batch.SameAs(_last)) batch = null;
            else _last = batch;
        }
        if (rate is not null) RateLimitsObserved?.Invoke(rate);
        if (batch is not null) Changed?.Invoke(batch);
    }

    private bool IsVisible(CodexThreadState st, DerivedState d, DateTimeOffset now)
    {
        if (st.IsActive || st.PendingQuestion is not null) return true;
        if (d.State.Kind == StateKind.NeedsAttention) return now - d.Since < ErrorWindow;
        var last = st.LastEventAt is { } l && l > d.Since ? l : d.Since;
        return now - last < RecentWindow;
    }

    /// <summary>Threads whose writer lock (or rollout) a live codex process holds open.</summary>
    private void DetectLoaded(DateTimeOffset now)
    {
        var loaded = new Dictionary<string, (int, string?)>();
        _inferred = !OperatingSystem.IsWindows();
        foreach (var name in FileReading.List(_paths.LocksDir))
        {
            if (CodexPaths.ThreadIdFromLock(name) is not { } id) continue;
            var lockPath = Path.Combine(_paths.LocksDir, name);
            if (OperatingSystem.IsWindows())
            {
                var holders = _inspector.FileHolders(lockPath)
                    .Where(pid => _inspector.ProcessName(pid)?.StartsWith("codex", StringComparison.OrdinalIgnoreCase) == true).ToList();
                if (holders.Count > 0) loaded[id] = (holders[0], lockPath);
            }
            else
            {
                // No Restart Manager: a lock plus a recently written rollout counts as loaded.
                _index.TryGetValue(id, out var info);
                if (RolloutPath(id, info) is { } rp && FileReading.Stat(rp) is { } st && now - st.Modified < TimeSpan.FromMinutes(10))
                    loaded[id] = (0, lockPath);
            }
        }
        _loaded = loaded;
    }

    private string? RolloutPath(string id, CodexThreadInfo? info)
    {
        if (info?.RolloutPath is { } p && File.Exists(p)) return p;
        if (_rolloutPaths.TryGetValue(id, out var cached) && (cached is null || File.Exists(cached))) return cached;
        string? found = null;
        IEnumerable<string> Sorted(string dir) => FileReading.List(dir).Where(n => int.TryParse(n, out _)).OrderDescending();
        int days = 0;
        foreach (var y in Sorted(_paths.SessionsDir))
        foreach (var m in Sorted(Path.Combine(_paths.SessionsDir, y)))
        foreach (var d in Sorted(Path.Combine(_paths.SessionsDir, y, m)))
        {
            if (++days > 90 || found is not null) break;
            var dir = Path.Combine(_paths.SessionsDir, y, m, d);
            found = FileReading.List(dir).Where(n => n.EndsWith($"-{id}.jsonl", StringComparison.Ordinal))
                .Select(n => Path.Combine(dir, n)).FirstOrDefault();
        }
        _rolloutPaths[id] = found;
        return found;
    }

    private string? OwnerAppName(int pid)
    {
        foreach (var p in ProcessAncestry.Chain(pid, _inspector).Skip(1))
        {
            var name = _inspector.ProcessName(p);
            if (name is null) continue;
            var lower = name.ToLowerInvariant();
            if (lower is "codex" or "chatgpt" or "code" or "cursor" or "windsurf" or "windowsterminal") return name;
        }
        return null;
    }

    private void UpdateTracker(string id, string path)
    {
        if (_trackers.TryGetValue(id, out var tracker) && tracker.Path == path)
        {
            if (!_dirty.Contains(id)) return;
            var (status, lines) = tracker.Tailer.Poll();
            if (status == ForwardTailer.Status.Lines)
                foreach (var line in lines) tracker.State.Apply(CodexRecordDecoder.Decode(line));
            else if (status is ForwardTailer.Status.Missing or ForwardTailer.Status.NeedsBootstrap)
            {
                if (Bootstrap(path) is { } fresh) _trackers[id] = fresh; else _trackers.Remove(id);
            }
            return;
        }
        if (Bootstrap(path) is { } t) _trackers[id] = t;
    }

    private static Tracker? Bootstrap(string path)
    {
        if (CodexRolloutScanner.Bootstrap(path) is not { } b) return null;
        return new Tracker(path, new ForwardTailer(path, b.Result.Created, b.Result.EndOffset, CodexRecordDecoder.MaxLineBytes), b.State);
    }

    public void Dispose()
    {
        _poll?.Dispose();
        _debounce.Dispose();
        foreach (var w in _watchers) w.Dispose();
    }
}

// MARK: - Usage providers

public sealed class ClaudeUsageProvider : IDisposable
{
    public event Action<ProviderUsage>? Changed;
    public bool UseApi { get; set; } = true;
    public bool Active { get; set; } = true;
    private readonly ClaudePaths _paths;
    private readonly IHttp _http;
    private readonly Func<DateTimeOffset> _clock;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private ClaudeUsageReading? _api, _cache;
    private FileStat? _cacheStat, _accountStat, _credStat;
    private ClaudeCredential? _credential;
    private string? _organization, _plan, _problem, _cachePath;
    private readonly BackoffPolicy _backoff = new();
    private DateTimeOffset _nextAttempt = DateTimeOffset.MinValue, _lastAttempt = DateTimeOffset.MinValue;
    private int? _parkedFingerprint;
    private ProviderUsage? _last;
    private Timer? _timer;

    public ClaudeUsageProvider(ClaudePaths paths, IHttp http, Func<DateTimeOffset>? clock = null)
    {
        _paths = paths;
        _http = http;
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
    }

    public void Start()
    {
        _ = TickAsync(false);
        _timer = new Timer(_ => _ = TickAsync(false), null, TimeSpan.FromSeconds(60), TimeSpan.FromSeconds(60));
    }

    public Task RefreshAsync(bool force) => TickAsync(force);

    public async Task TickAsync(bool force)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            ReadCache();
            var now = _clock();
            var interval = force ? TimeSpan.FromSeconds(60) : Active ? TimeSpan.FromSeconds(180) : TimeSpan.FromSeconds(600);
            if (UseApi && now >= _nextAttempt && now - _lastAttempt >= interval) await FetchApiAsync(now).ConfigureAwait(false);
            Emit();
        }
        finally { _gate.Release(); }
    }

    private void ReadCache()
    {
        if (FileReading.Stat(_paths.AccountFile) is { } ast && ast != _accountStat)
        {
            _accountStat = ast;
            var acct = FileReading.ReadAll(_paths.AccountFile, 16 << 20) is { } bytes ? Json.Parse(bytes).Get("oauthAccount") : null;
            _organization = acct.Str("organizationUuid");
            _plan ??= ClaudeUsageParser.PlanLabel(acct.Str("organizationType"), acct.Str("organizationRateLimitTier"));
        }
        var path = _paths.FindPlanUsageHistory();
        var st = path is null ? null : FileReading.Stat(path);
        if (st is null) { _cache = null; _cacheStat = null; _cachePath = null; return; }
        if (st == _cacheStat && path == _cachePath) return;
        (_cacheStat, _cachePath) = (st, path);
        _cache = FileReading.ReadAll(path!, 4 << 20) is { } data ? ClaudeUsageParser.ParseDesktopCache(data, _organization) : null;
    }

    private async Task FetchApiAsync(DateTimeOffset now)
    {
        _lastAttempt = now;
        // Windows keeps Claude Code's login in ~/.claude/.credentials.json (read-only here).
        var cst = FileReading.Stat(_paths.CredentialsFile);
        if (cst != _credStat)
        {
            _credStat = cst;
            _credential = FileReading.ReadAll(_paths.CredentialsFile, 64 * 1024) is { } raw ? ClaudeCredential.Parse(raw) : null;
            _parkedFingerprint = null;
        }
        if (_credential is null)
        {
            // Claude Code inside the Claude app signs in through the app and keeps no login file.
            _problem = _paths.DesktopAppPresent ? "Waiting for the Claude app's usage numbers" : "Claude Code login not found";
            return;
        }
        if (_parkedFingerprint == _credential.Token.Fingerprint) return;
        if (!_credential.IsUsable(now)) { _problem = "Claude Code login expired — using the Claude app's numbers"; return; }
        if (ClaudeUsageParser.PlanLabel(_credential.SubscriptionType, _credential.RateLimitTier) is { } p) _plan = p;
        var headers = _credential.Token.WithValue(token => new Dictionary<string, string>
        {
            ["Authorization"] = $"Bearer {token}",
            ["anthropic-beta"] = "oauth-2025-04-20",
            ["User-Agent"] = "claude-code/2.1.281",
            ["Accept"] = "application/json",
        });
        var result = await _http.GetAsync(new Uri("https://api.anthropic.com/api/oauth/usage"), headers, TimeSpan.FromSeconds(15)).ConfigureAwait(false);
        double jitter = Random.Shared.NextDouble();
        switch (result?.Status)
        {
            case 200:
                if (ClaudeUsageParser.ParseOAuth(result.Body, _clock()) is { } reading) { _api = reading; _problem = null; _backoff.Succeeded(); }
                else { _problem = "Unexpected usage response"; _nextAttempt = now.AddMinutes(30); }
                break;
            case 401 or 403:
                _parkedFingerprint = _credential.Token.Fingerprint;
                _problem = "Claude Code login rejected";
                break;
            case 429:
                result!.Headers.TryGetValue("retry-after", out var ra);
                _nextAttempt = now + _backoff.RateLimited(RetryAfter.Parse(ra, now), jitter);
                _problem = "Rate limited";
                break;
            case null:
                _nextAttempt = now + _backoff.Failed(jitter);
                _problem = "Offline";
                break;
            default:
                _nextAttempt = now + _backoff.Failed(jitter);
                _problem = "Usage service error";
                break;
        }
    }

    private void Emit()
    {
        var now = _clock();
        var windows = ClaudeUsageParser.Merge(UseApi ? _api : null, _cache, now);
        var newest = new[] { _api?.ObservedAt, _cache?.ObservedAt }.Where(d => d is not null).Max();
        UsageStatus status;
        if (windows.Count == 0) status = new UsageStatus(UsageStatusKind.Unavailable, Reason: _problem ?? "No usage data yet");
        else if (newest is { } n)
        {
            var staleAfter = n == _api?.ObservedAt ? TimeSpan.FromMinutes(6) : TimeSpan.FromMinutes(45);
            status = now - n > staleAfter ? new UsageStatus(UsageStatusKind.Stale, n) : UsageStatus.Ok;
        }
        else status = UsageStatus.Ok;
        var usage = new ProviderUsage(Provider.Claude, _plan, windows, windows.Any(w => (w.UsedPercent ?? 0) >= 100), status, newest);
        if (usage.SameAs(_last)) return;
        _last = usage;
        Changed?.Invoke(usage);
    }

    public void Dispose() => _timer?.Dispose();
}

public sealed class CodexUsageProvider : IDisposable
{
    public event Action<ProviderUsage>? Changed;
    public bool UseApi { get; set; } = true;
    public bool Active { get; set; } = true;
    private readonly CodexPaths _paths;
    private readonly IHttp _http;
    private readonly Func<DateTimeOffset> _clock;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly Dictionary<UsageSource, CodexRateLimitObservation> _observations = [];
    private readonly BackoffPolicy _backoff = new();
    private DateTimeOffset _nextAttempt = DateTimeOffset.MinValue, _lastAttempt = DateTimeOffset.MinValue;
    private DateTimeOffset? _rejectedAuthStamp;
    private string? _problem;
    private ProviderUsage? _last;
    private Timer? _timer;

    public CodexUsageProvider(CodexPaths paths, IHttp http, Func<DateTimeOffset>? clock = null)
    {
        _paths = paths;
        _http = http;
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
    }

    public void Start()
    {
        if (CodexRolloutScanner.LatestRateLimits(_paths) is { } r) lock (_observations) _observations[UsageSource.CodexRollout] = r;
        _timer = new Timer(_ => _ = TickAsync(false), null, TimeSpan.FromMilliseconds(300), TimeSpan.FromSeconds(60));
    }

    public void Ingest(CodexRateLimitObservation o)
    {
        lock (_observations)
        {
            if (_observations.TryGetValue(o.Source, out var cur) && cur.ObservedAt >= o.ObservedAt) return;
            _observations[o.Source] = o;
        }
        Emit();
    }

    public Task RefreshAsync(bool force) => TickAsync(force);

    public async Task TickAsync(bool force)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            var now = _clock();
            var interval = force ? TimeSpan.FromSeconds(60) : Active ? TimeSpan.FromSeconds(300) : TimeSpan.FromSeconds(900);
            if (UseApi && now >= _nextAttempt && now - _lastAttempt >= interval) await FetchAsync(now).ConfigureAwait(false);
            Emit();
        }
        finally { _gate.Release(); }
    }

    private async Task FetchAsync(DateTimeOffset now)
    {
        _lastAttempt = now;
        var auth = CodexAuth.Load(_paths.AuthFile);
        var stamp = FileReading.Stat(_paths.AuthFile)?.Modified;
        if (auth is not { UsesChatGpt: true, AccessToken: { IsEmpty: false } token } || (auth.ExpiresAt is { } exp && exp <= now.AddSeconds(60))
            || (_rejectedAuthStamp is not null && _rejectedAuthStamp == stamp))
        {
            _problem ??= "Codex login not available";
            return;
        }
        var headers = token.WithValue(t => new Dictionary<string, string>
        {
            ["Authorization"] = $"Bearer {t}",
            ["Accept"] = "application/json",
            ["User-Agent"] = "ClaudexBar/0.1",
        });
        if (auth.AccountId is { } acct) headers["ChatGPT-Account-Id"] = acct;
        var result = await _http.GetAsync(new Uri("https://chatgpt.com/backend-api/wham/usage"), headers, TimeSpan.FromSeconds(15)).ConfigureAwait(false);
        double jitter = Random.Shared.NextDouble();
        switch (result?.Status)
        {
            case 200:
                if (CodexUsageParser.ParseWham(result.Body, _clock()) is { } obs)
                {
                    lock (_observations) _observations[UsageSource.CodexWham] = obs;
                    _backoff.Succeeded();
                    _problem = null;
                }
                else { _problem = "Unexpected usage response"; _nextAttempt = now.AddMinutes(30); }
                break;
            case 401 or 403:
                _rejectedAuthStamp = stamp;
                _problem = "Codex login rejected";
                break;
            case 429:
                result!.Headers.TryGetValue("retry-after", out var ra);
                _nextAttempt = now + _backoff.RateLimited(RetryAfter.Parse(ra, now), jitter);
                _problem = "Rate limited";
                break;
            default:
                _nextAttempt = now + _backoff.Failed(jitter);
                _problem = result is null ? "Offline" : "Usage service error";
                break;
        }
    }

    private void Emit()
    {
        var now = _clock();
        List<CodexRateLimitObservation> all;
        lock (_observations) all = _observations.Values.ToList();
        var (windows, plan, reached, newest) = CodexUsageParser.Merge(all, now);
        UsageStatus status;
        if (windows.Count == 0) status = new UsageStatus(UsageStatusKind.Unavailable, Reason: _problem ?? "No usage data yet");
        else if (newest is { } n)
        {
            bool fresh = all.Any(o => o.Source != UsageSource.CodexRollout && o.ObservedAt == n);
            status = now - n > (fresh ? TimeSpan.FromMinutes(15) : TimeSpan.FromMinutes(30)) ? new UsageStatus(UsageStatusKind.Stale, n) : UsageStatus.Ok;
        }
        else status = UsageStatus.Ok;
        var usage = new ProviderUsage(Provider.Codex, plan, windows, reached, status, newest);
        lock (_observations)
        {
            if (usage.SameAs(_last)) return;
            _last = usage;
        }
        Changed?.Invoke(usage);
    }

    public void Dispose() => _timer?.Dispose();
}

// MARK: - Engine

public sealed class ClaudexEngine : IStatusFeed
{
    public event Action<SessionSnapshot>? SessionsChanged;
    public event Action<UsageSnapshot>? UsageChanged;

    private readonly ClaudeSessionSource _claude;
    private readonly CodexSessionSource _codex;
    private readonly ClaudeUsageProvider _claudeUsage;
    private readonly CodexUsageProvider _codexUsage;
    private readonly Lock _gate = new();
    private readonly Dictionary<Provider, ProviderSessions> _latest = [];
    private readonly StateSmoother _smoother = new();
    private IReadOnlyList<AgentSession>? _published;
    private UsageSnapshot _usage = UsageSnapshot.Empty;
    private Timer? _recheck;

    public ClaudexEngine(bool claudeUsageApi = true, bool codexUsageApi = true)
    {
        var inspector = new LiveProcessInspector();
        var http = new LiveHttp();
        _claude = new ClaudeSessionSource(ClaudePaths.Standard(), inspector);
        _codex = new CodexSessionSource(CodexPaths.Standard(), inspector);
        _claudeUsage = new ClaudeUsageProvider(ClaudePaths.Standard(), http) { UseApi = claudeUsageApi };
        _codexUsage = new CodexUsageProvider(CodexPaths.Standard(), http) { UseApi = codexUsageApi };
        _claude.Changed += Ingest;
        _codex.Changed += Ingest;
        _codex.RateLimitsObserved += _codexUsage.Ingest;
        _claudeUsage.Changed += SetUsage;
        _codexUsage.Changed += SetUsage;
    }

    public void SetUsageApis(bool claude, bool codex)
    {
        _claudeUsage.UseApi = claude;
        _codexUsage.UseApi = codex;
        RefreshNow();
    }

    public void Start()
    {
        Task.Run(() =>
        {
            _claude.Start();
            _codex.Start();
            _claudeUsage.Start();
            _codexUsage.Start();
        });
    }

    public void RefreshNow()
    {
        Task.Run(async () =>
        {
            _claude.Rescan();
            _codex.Rescan();
            await _claudeUsage.RefreshAsync(true).ConfigureAwait(false);
            await _codexUsage.RefreshAsync(true).ConfigureAwait(false);
        });
    }

    private void Ingest(ProviderSessions batch)
    {
        bool claudeActive, codexActive;
        lock (_gate)
        {
            _latest[batch.Provider] = batch;
            claudeActive = _latest.TryGetValue(Provider.Claude, out var c) && c.Sessions.Count > 0;
            codexActive = _latest.TryGetValue(Provider.Codex, out var x) && x.Sessions.Count > 0;
        }
        _claudeUsage.Active = claudeActive;
        _codexUsage.Active = codexActive;
        Publish();
    }

    private void Publish()
    {
        SessionSnapshot? snapshot = null;
        lock (_gate)
        {
            var now = DateTimeOffset.UtcNow;
            var raw = ProviderInfo.All.SelectMany(p => _latest.TryGetValue(p, out var b) ? b.Sessions : []).ToList();
            var (sessions, recheckAt) = _smoother.Apply(raw, now);
            if (_published is null || !_published.SequenceEqual(sessions))
            {
                _published = sessions;
                snapshot = new SessionSnapshot(now, sessions);
            }
            _recheck?.Dispose();
            _recheck = recheckAt is { } at
                ? new Timer(_ => Publish(), null, TimeSpan.FromMilliseconds(Math.Max(50, (at - now).TotalMilliseconds)), Timeout.InfiniteTimeSpan)
                : null;
        }
        if (snapshot is not null) SessionsChanged?.Invoke(snapshot);
    }

    private void SetUsage(ProviderUsage u)
    {
        UsageSnapshot snapshot;
        lock (_gate)
        {
            _usage = u.Provider == Provider.Claude
                ? _usage with { Claude = u, GeneratedAt = DateTimeOffset.UtcNow }
                : _usage with { Codex = u, GeneratedAt = DateTimeOffset.UtcNow };
            snapshot = _usage;
        }
        UsageChanged?.Invoke(snapshot);
    }

    public void Dispose()
    {
        _recheck?.Dispose();
        _claude.Dispose();
        _codex.Dispose();
        _claudeUsage.Dispose();
        _codexUsage.Dispose();
    }
}
