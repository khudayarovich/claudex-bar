import Foundation

// MARK: - Credentials

public struct ClaudeCredential: Sendable, Equatable {
    public var token: SecretToken
    public var expiresAt: Date?
    public var scopes: [String]
    public var subscriptionType: String?
    public var rateLimitTier: String?

    /// Non-empty, not about to expire, and allowed to read the usage endpoint.
    public func isUsable(now: Date) -> Bool {
        guard !token.isEmpty else { return false }
        if let e = expiresAt, e <= now.addingTimeInterval(60) { return false }
        if !scopes.isEmpty, !scopes.contains("user:profile") { return false }
        return true
    }
}

public enum ClaudeCredentialParser {
    /// Parses `security … -w` output (JSON, or hex-encoded JSON) or `.credentials.json`.
    public static func parse(_ raw: Data) -> ClaudeCredential? {
        var text = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.hasPrefix("{"), text.count % 2 == 0, text.allSatisfy(\.isHexDigit) {
            var bytes = [UInt8]()
            bytes.reserveCapacity(text.count / 2)
            var i = text.startIndex
            while i < text.endIndex {
                let j = text.index(i, offsetBy: 2)
                guard let b = UInt8(text[i..<j], radix: 16) else { return nil }
                bytes.append(b)
                i = j
            }
            text = String(decoding: bytes, as: UTF8.self)
        }
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
              let oauth = root["claudeAiOauth"] else { return nil }
        let token = oauth["accessToken"]?.string ?? ""
        let expires = oauth["expiresAt"]?.double.flatMap { $0 > 0 ? TimeParsing.epoch($0) : Date.distantPast }
        let scopes: [String]
        if let arr = oauth["scopes"]?.array {
            scopes = arr.compactMap(\.string)
        } else if let s = oauth["scopes"]?.string {
            scopes = s.split(separator: " ").map(String.init)
        } else {
            scopes = []
        }
        return ClaudeCredential(
            token: SecretToken(token), expiresAt: expires, scopes: scopes,
            subscriptionType: oauth["subscriptionType"]?.string, rateLimitTier: oauth["rateLimitTier"]?.string
        )
    }

    /// Extracts the raw `"mdat"` attribute from `security find-generic-password` output.
    public static func modificationStamp(_ attributes: String) -> String? {
        for line in attributes.split(separator: "\n") where line.contains("\"mdat\"") {
            return String(line).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

/// Reads Claude Code's OAuth credential without ever writing it. The secret is only
/// re-read when the Keychain item's modification stamp changes.
public actor ClaudeCredentialReader {
    public let service: String
    public let account: String
    private let credentialsFile: String
    private var lastStamp: String?
    private var cached: ClaudeCredential?
    private let fs: FileSystemReading

    public init(service: String = "Claude Code-credentials", account: String = NSUserName(),
                claudeHome: String = Paths.join(NSHomeDirectory(), ".claude"), fs: FileSystemReading = LiveFileSystem()) {
        self.service = service
        self.account = account
        self.credentialsFile = Paths.join(claudeHome, ".credentials.json")
        self.fs = fs
    }

    /// Returns the current credential and whether it changed since the last call.
    public func current() async -> (credential: ClaudeCredential?, changed: Bool) {
        let attrs = await CommandRunner.run("/usr/bin/security", ["find-generic-password", "-s", service, "-a", account])
        if let attrs, attrs.status == 0 {
            let stamp = ClaudeCredentialParser.modificationStamp(String(decoding: attrs.stdout, as: UTF8.self))
            // Unchanged item: reuse the last result (even "no usable token") without reading the secret.
            if let stamp, stamp == lastStamp { return (cached, false) }
            let secret = await CommandRunner.run("/usr/bin/security",
                                                 ["find-generic-password", "-s", service, "-a", account, "-w"])
            let parsed = secret.flatMap { $0.status == 0 ? ClaudeCredentialParser.parse($0.stdout) : nil }
            let changed = parsed != cached
            lastStamp = stamp
            cached = parsed
            return (parsed, changed)
        }
        // No Keychain item: some setups keep a plaintext credentials file.
        let parsed = fs.readAll(credentialsFile, maxBytes: 64 * 1024).flatMap(ClaudeCredentialParser.parse)
        let changed = parsed != cached
        cached = parsed
        return (parsed, changed)
    }
}

// MARK: - Usage parsing

public struct ClaudeUsageReading: Sendable, Equatable {
    public var windows: [UsageWindow]
    public var observedAt: Date
    public var source: UsageSource
}

public enum ClaudeUsageParser {
    /// `GET /api/oauth/usage`. Prefers the newer `limits[]` array, falls back to the
    /// legacy `five_hour` / `seven_day[_model]` keys.
    public static func parseOAuth(_ data: Data, observedAt: Date) -> ClaudeUsageReading? {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data), root.object != nil else { return nil }
        var windows: [UsageWindow] = []
        for row in root["limits"]?.array ?? [] {
            guard let percent = row["percent"]?.double ?? row["utilization"]?.double else { continue }
            let resets = TimeParsing.flexible(row["resets_at"])
            let kind = row["kind"]?.string ?? ""
            let model = row["scope"]?["model"]?["display_name"]?.string
                ?? row["scope"]?["surface"]?["display_name"]?.string
            switch kind {
            case "session":
                windows.append(window("claude.five_hour", .session5h, "5h", percent, resets, 5 * 3600, observedAt))
            case "weekly_all":
                windows.append(window("claude.seven_day", .weekly, "Weekly", percent, resets, 7 * 86_400, observedAt))
            case "weekly_scoped":
                let name = model ?? "Scoped"
                windows.append(window("claude.weekly.\(name.lowercased())", .weeklyScoped(name), "Weekly · \(name)",
                                      percent, resets, 7 * 86_400, observedAt))
            default:
                let group = row["group"]?.string ?? kind
                guard !group.isEmpty else { continue }
                windows.append(window("claude.\(kind.isEmpty ? group : kind)", .other(group), group.capitalized,
                                      percent, resets, nil, observedAt))
            }
        }
        if windows.isEmpty {
            let legacy: [(String, WindowKind, String, TimeInterval)] = [
                ("five_hour", .session5h, "5h", 5 * 3600),
                ("seven_day", .weekly, "Weekly", 7 * 86_400),
                ("seven_day_opus", .weeklyScoped("Opus"), "Weekly · Opus", 7 * 86_400),
                ("seven_day_sonnet", .weeklyScoped("Sonnet"), "Weekly · Sonnet", 7 * 86_400),
            ]
            for (key, kind, label, duration) in legacy {
                guard let w = root[key], let u = w["utilization"]?.double else { continue }
                let id: String
                switch kind {
                case .weeklyScoped(let name): id = "claude.weekly.\(name.lowercased())"
                default: id = "claude.\(key)"
                }
                windows.append(window(id, kind, label, u, TimeParsing.flexible(w["resets_at"]), duration, observedAt))
            }
        }
        return ClaudeUsageReading(windows: windows, observedAt: observedAt, source: .claudeOAuthAPI)
    }

    private static func window(_ id: String, _ kind: WindowKind, _ label: String, _ percent: Double, _ resets: Date?,
                               _ duration: TimeInterval?, _ at: Date) -> UsageWindow {
        UsageWindow(id: id, kind: kind, label: label, usedPercent: percent, resetsAt: resets,
                    windowDuration: duration, source: .claudeOAuthAPI, fetchedAt: at)
    }

    /// Claude desktop's `plan-usage-history.json`: `{version, samples:[{t, org, u:{fh,sd,so,sn,…}}]}`
    /// (v1: `{t, fh, sd}`). Percentages only; reset times are not recorded.
    public static func parseDesktopCache(_ data: Data, organization: String?) -> ClaudeUsageReading? {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              let samples = root["samples"]?.array, !samples.isEmpty else { return nil }
        func time(_ s: JSONValue) -> Double { s["t"]?.double ?? 0 }
        let matching = organization.map { org in samples.filter { $0["org"]?.string == org } } ?? []
        guard let sample = (matching.isEmpty ? samples : matching).max(by: { time($0) < time($1) }),
              let at = TimeParsing.epoch(time(sample)) else { return nil }
        let values = sample["u"] ?? sample
        let keys: [(String, String, WindowKind, String, TimeInterval)] = [
            ("fh", "claude.five_hour", .session5h, "5h", 5 * 3600),
            ("sd", "claude.seven_day", .weekly, "Weekly", 7 * 86_400),
            ("so", "claude.weekly.opus", .weeklyScoped("Opus"), "Weekly · Opus", 7 * 86_400),
            ("sn", "claude.weekly.sonnet", .weeklyScoped("Sonnet"), "Weekly · Sonnet", 7 * 86_400),
        ]
        let pool = (matching.isEmpty ? samples : matching).sorted { time($0) < time($1) }
        var windows: [UsageWindow] = []
        for (key, id, kind, label, duration) in keys {
            guard let v = values[key]?.double else { continue }
            let series = pool.compactMap { s -> ClaudeResetEstimator.Sample? in
                guard let t = TimeParsing.epoch(time(s)), let v = (s["u"] ?? s)[key]?.double else { return nil }
                return .init(t: t, v: v)
            }
            var estimate: Date?
            switch kind {
            case .session5h: estimate = ClaudeResetEstimator.sessionReset(series, observedAt: at)
            case .weekly: estimate = ClaudeResetEstimator.weeklyReset(series, observedAt: at)
            default: estimate = nil
            }
            windows.append(UsageWindow(id: id, kind: kind, label: label, usedPercent: v, resetsAt: estimate,
                                       windowDuration: duration, source: .claudeDesktopCache, fetchedAt: at,
                                       resetIsEstimate: estimate != nil))
        }
        return windows.isEmpty ? nil : ClaudeUsageReading(windows: windows, observedAt: at, source: .claudeDesktopCache)
    }

    /// Merges the API reading and the desktop cache by freshness. When the cache is newer,
    /// a reset time from the API is kept only if it is still after the cache sample.
    public static func merge(api: ClaudeUsageReading?, cache: ClaudeUsageReading?, now: Date) -> [UsageWindow] {
        var byID: [String: UsageWindow] = [:]
        var order: [String] = []
        for w in (api?.windows ?? []) + (cache?.windows ?? []) where byID[w.id] == nil {
            order.append(w.id)
            byID[w.id] = w
        }
        var out: [UsageWindow] = []
        for id in order {
            let a = api?.windows.first { $0.id == id }
            let c = cache?.windows.first { $0.id == id }
            var pick: UsageWindow
            if let c, let a {
                if c.fetchedAt.timeIntervalSince(a.fetchedAt) > 1 {
                    pick = c
                    if let r = a.resetsAt, r > c.fetchedAt {
                        pick.resetsAt = r
                        pick.resetIsEstimate = false
                    }
                } else {
                    pick = a
                }
            } else {
                pick = (a ?? c)!
            }
            out.append(pick.resolved(now: now))
        }
        return out.sorted { WindowLabeler.order($0.kind) < WindowLabeler.order($1.kind) }
    }

    public static func planLabel(subscriptionType: String?, tier: String?) -> String? {
        let t = (tier ?? "").lowercased()
        let s = (subscriptionType ?? "").lowercased()
        if t.contains("20x") { return "Max 20×" }
        if t.contains("5x") { return "Max 5×" }
        if s.contains("max") { return "Max" }
        if s.contains("pro") { return "Pro" }
        if s.contains("team") { return "Team" }
        if s.contains("enterprise") { return "Enterprise" }
        return subscriptionType.map { $0.capitalized }
    }
}

// MARK: - Provider

public actor ClaudeUsageProvider {
    public nonisolated let updates: AsyncStream<ProviderUsage>
    private nonisolated let continuation: AsyncStream<ProviderUsage>.Continuation

    public struct Options: Sendable {
        public var useAPI = true
        public var activeInterval: TimeInterval = 180
        public var idleInterval: TimeInterval = 600
        public var cacheCheckInterval: TimeInterval = 60
        public var minimumInterval: TimeInterval = 60
        public init() {}
    }

    private let paths: ClaudePaths
    private let fs: FileSystemReading
    private let http: HTTPClient
    private let credentials: ClaudeCredentialReader
    private let clock: @Sendable () -> Date
    private var options: Options

    private var apiReading: ClaudeUsageReading?
    private var cacheReading: ClaudeUsageReading?
    private var cacheStat: FileStat?
    private var accountStat: FileStat?
    private var organization: String?
    private var plan: String?
    private var backoff = BackoffPolicy()
    private var nextAPIAttempt: Date = .distantPast
    private var lastAPIAttempt: Date = .distantPast
    private var parkedFingerprint: Int?
    private var apiProblem: String?
    private var userAgentVersion = "2.1.280"
    private var active = true
    private var loop: Task<Void, Never>?
    private var lastEmitted: ProviderUsage?

    public init(paths: ClaudePaths = .standard(), fs: FileSystemReading = LiveFileSystem(),
                http: HTTPClient = URLSessionHTTPClient(), credentials: ClaudeCredentialReader = ClaudeCredentialReader(),
                options: Options = Options(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.paths = paths
        self.fs = fs
        self.http = http
        self.credentials = credentials
        self.options = options
        self.clock = clock
        (updates, continuation) = AsyncStream.makeStream(of: ProviderUsage.self, bufferingPolicy: .bufferingNewest(1))
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            while !Task.isCancelled {
                await self?.tick(forceAPI: false)
                let wait = await self?.options.cacheCheckInterval ?? 60
                try? await Task.sleep(for: .seconds(wait), tolerance: .seconds(5))
            }
        }
        // Emit passive data immediately.
        readCache()
        emit()
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        continuation.finish()
    }

    public func setActive(_ value: Bool) { active = value }
    public func setUserAgentVersion(_ v: String) { userAgentVersion = v }
    public func setUseAPI(_ value: Bool) {
        options.useAPI = value
        if !value { apiReading = nil }
    }

    /// Refresh now (e.g. the island was expanded), respecting backoff and the minimum interval.
    public func refresh(force: Bool) async {
        await tick(forceAPI: force)
    }

    private func tick(forceAPI: Bool) async {
        readCache()
        let now = clock()
        let interval = active ? options.activeInterval : options.idleInterval
        let due = now >= nextAPIAttempt && now.timeIntervalSince(lastAPIAttempt) >= (forceAPI ? options.minimumInterval : interval)
        if options.useAPI, due { await fetchAPI(now: now) }
        emit()
    }

    private func readCache() {
        if let st = fs.stat(paths.accountFile), st != accountStat {
            accountStat = st
            if let data = fs.readAll(paths.accountFile, maxBytes: 16 << 20),
               let root = try? JSONDecoder().decode(JSONValue.self, from: data) {
                organization = root["oauthAccount"]?["organizationUuid"]?.string
                plan = plan ?? ClaudeUsageParser.planLabel(
                    subscriptionType: root["oauthAccount"]?["organizationType"]?.string,
                    tier: root["oauthAccount"]?["organizationRateLimitTier"]?.string)
            }
        }
        guard let st = fs.stat(paths.planUsageHistory) else {
            cacheReading = nil
            cacheStat = nil
            return
        }
        guard st != cacheStat else { return }
        cacheStat = st
        cacheReading = fs.readAll(paths.planUsageHistory, maxBytes: 4 << 20)
            .flatMap { ClaudeUsageParser.parseDesktopCache($0, organization: organization) }
    }

    private func fetchAPI(now: Date) async {
        lastAPIAttempt = now
        let (credential, changed) = await credentials.current()
        guard let credential else {
            // Claude Code inside the Claude app signs in through the app and keeps no login of its own.
            apiProblem = fs.stat(paths.desktopSupport)?.isDirectory == true
                ? "Waiting for the Claude app's usage numbers"
                : "Claude Code login not found"
            return
        }
        if changed { parkedFingerprint = nil }
        if let parked = parkedFingerprint, parked == credential.token.fingerprint { return }
        guard credential.isUsable(now: now) else {
            apiProblem = "Claude Code login expired — using the Claude app's numbers"
            return
        }
        if let p = ClaudeUsageParser.planLabel(subscriptionType: credential.subscriptionType, tier: credential.rateLimitTier) {
            plan = p
        }
        let headers = credential.token.withValue { token in
            [
                "Authorization": "Bearer \(token)",
                "anthropic-beta": "oauth-2025-04-20",
                "User-Agent": "claude-code/\(userAgentVersion)",
                "Accept": "application/json",
            ]
        }
        let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        let result = await http.get(url, headers: headers, timeout: 15)
        let jitter = Double.random(in: 0...1)
        switch result {
        case let .success(response) where response.status == 200:
            if let reading = ClaudeUsageParser.parseOAuth(response.body, observedAt: clock()) {
                apiReading = reading
                apiProblem = nil
                backoff.succeeded()
            } else {
                apiProblem = "Unexpected usage response"
                nextAPIAttempt = now.addingTimeInterval(1800)
            }
        case let .success(response) where response.status == 401 || response.status == 403:
            parkedFingerprint = credential.token.fingerprint
            apiProblem = "Claude Code login rejected"
        case let .success(response) where response.status == 429:
            let delay = backoff.rateLimited(retryAfter: RetryAfter.parse(response.headers["retry-after"], now: now), jitter: jitter)
            nextAPIAttempt = now.addingTimeInterval(delay)
            apiProblem = "Rate limited"
        case .success:
            nextAPIAttempt = now.addingTimeInterval(backoff.failed(jitter: jitter))
            apiProblem = "Usage service error"
        case .failure:
            nextAPIAttempt = now.addingTimeInterval(backoff.failed(jitter: jitter))
            apiProblem = "Offline"
        }
    }

    private func emit() {
        let now = clock()
        let windows = ClaudeUsageParser.merge(api: options.useAPI ? apiReading : nil, cache: cacheReading, now: now)
        let newest = [apiReading?.observedAt, cacheReading?.observedAt].compactMap { $0 }.max()
        let status: UsageStatus
        if windows.isEmpty {
            status = .unavailable(apiProblem ?? "No usage data yet")
        } else if let newest {
            let staleAfter: TimeInterval = newest == apiReading?.observedAt ? 6 * 60 : 45 * 60
            status = now.timeIntervalSince(newest) > staleAfter ? .stale(since: newest) : .ok
        } else {
            status = .ok
        }
        let usage = ProviderUsage(provider: .claude, plan: plan, windows: windows,
                                  limitReached: windows.contains { ($0.usedPercent ?? 0) >= 100 },
                                  status: status, lastSuccessAt: newest)
        if usage != lastEmitted {
            lastEmitted = usage
            continuation.yield(usage)
        }
    }
}

/// Estimates reset times from the Claude app's sampled usage history (which records
/// percentages but not reset times). Only returns a value when the sampling gap around
/// the window start is small; otherwise the reset time stays unknown.
public enum ClaudeResetEstimator {
    public struct Sample: Sendable, Equatable {
        public var t: Date
        public var v: Double
        public init(t: Date, v: Double) { self.t = t; self.v = v }
    }

    static let fiveHours: TimeInterval = 5 * 3600
    static let week: TimeInterval = 7 * 86_400

    /// The 5-hour window resets 5 h after its first message. The first message happened
    /// between the last sample of the previous window (or an idle 0 %) and the first sample
    /// of the current window.
    public static func sessionReset(_ samples: [Sample], observedAt: Date, maxUncertainty: TimeInterval = 30 * 60) -> Date? {
        guard let last = samples.last, last.v > 0 else { return nil }
        var k = samples.count - 1
        while k > 0 {
            let prev = samples[k - 1], cur = samples[k]
            if prev.v <= 0 || cur.v < prev.v - 1 || cur.t.timeIntervalSince(prev.t) >= fiveHours { break }
            k -= 1
        }
        let hi = samples[k].t
        var lo = k > 0 ? samples[k - 1].t : hi.addingTimeInterval(-fiveHours)
        // Still inside the window at `observedAt`, so it can't have started more than 5 h before.
        lo = max(lo, observedAt.addingTimeInterval(-fiveHours))
        guard hi >= lo, hi.timeIntervalSince(lo) <= maxUncertainty else { return nil }
        let reset = lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2 + fiveHours)
        return reset > observedAt ? reset : nil
    }

    /// Weekly: 7 days after the most recent sharp drop, if that drop was sampled tightly.
    public static func weeklyReset(_ samples: [Sample], observedAt: Date, maxUncertainty: TimeInterval = 2 * 3600) -> Date? {
        guard samples.count >= 2 else { return nil }
        for j in stride(from: samples.count - 1, through: 1, by: -1) {
            let prev = samples[j - 1], cur = samples[j]
            guard cur.v < prev.v - 5 else { continue }
            let width = cur.t.timeIntervalSince(prev.t)
            guard width <= maxUncertainty else { return nil }
            let reset = prev.t.addingTimeInterval(width / 2 + week)
            return reset > observedAt ? reset : nil
        }
        return nil
    }
}
