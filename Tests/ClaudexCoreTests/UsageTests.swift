import Foundation
import Testing
@testable import ClaudexCore

@Suite("Claude usage")
struct ClaudeUsageTests {
    let now = TimeParsing.iso8601("2026-09-24T23:00:00Z")!

    @Test func oauthLimitsArrayPreferred() throws {
        let r = try #require(ClaudeUsageParser.parseOAuth(Fixture.data("claude/usage/oauth-limits.json"), observedAt: now))
        #expect(r.windows.map(\.label) == ["5h", "Weekly", "Weekly · Opus", "Monthly"])
        #expect(r.windows[0].usedPercent == 12)
        #expect(r.windows[0].resetsAt == TimeParsing.iso8601("2026-09-25T04:09:59Z"))
        #expect(r.windows[2].kind == .weeklyScoped("Opus"))
        #expect(r.windows[3].kind == .other("monthly"))
    }

    @Test func oauthLegacyKeys() throws {
        let r = try #require(ClaudeUsageParser.parseOAuth(Fixture.data("claude/usage/oauth-legacy.json"), observedAt: now))
        #expect(r.windows.map(\.label) == ["5h", "Weekly", "Weekly · Sonnet"])
        #expect(r.windows[1].resetsAt == TimeParsing.iso8601("2026-09-30T00:00:00Z"))
    }

    @Test func desktopCachePicksTheAccountsOrganization() throws {
        let data = Fixture.data("claude/usage/plan-usage-history-v2.json")
        let a = try #require(ClaudeUsageParser.parseDesktopCache(data, organization: "org-A"))
        #expect(a.windows.map(\.usedPercent) == [10, 16, 1])
        #expect(a.observedAt == TimeParsing.epoch(1_790_287_814_378))
        let fallback = try #require(ClaudeUsageParser.parseDesktopCache(data, organization: nil))
        #expect(fallback.windows.first?.usedPercent == 99)   // newest sample overall
        let v1 = try #require(ClaudeUsageParser.parseDesktopCache(Fixture.data("claude/usage/plan-usage-history-v1.json"), organization: nil))
        #expect(v1.windows.map(\.label) == ["5h", "Weekly"])
    }

    @Test func mergeKeepsFutureAPIResetWhenCacheIsNewer() {
        let apiAt = now.addingTimeInterval(-600)
        let reset = now.addingTimeInterval(3600)
        let api = ClaudeUsageReading(windows: [UsageWindow(id: "claude.five_hour", kind: .session5h, label: "5h", usedPercent: 40,
                                                           resetsAt: reset, windowDuration: 18_000, source: .claudeOAuthAPI,
                                                           fetchedAt: apiAt)], observedAt: apiAt, source: .claudeOAuthAPI)
        let cache = ClaudeUsageReading(windows: [UsageWindow(id: "claude.five_hour", kind: .session5h, label: "5h", usedPercent: 45,
                                                             resetsAt: nil, windowDuration: 18_000, source: .claudeDesktopCache,
                                                             fetchedAt: now)], observedAt: now, source: .claudeDesktopCache)
        let merged = ClaudeUsageParser.merge(api: api, cache: cache, now: now)
        #expect(merged.count == 1)
        #expect(merged[0].usedPercent == 45)
        #expect(merged[0].source == .claudeDesktopCache)
        #expect(merged[0].resetsAt == reset)
        // Once the reset time passes, the window reads 0 % "reset".
        let later = ClaudeUsageParser.merge(api: api, cache: cache, now: reset.addingTimeInterval(1))
        #expect(later[0].usedPercent == 0)
        #expect(later[0].isReset)
    }

    @Test func credentialParsing() throws {
        let c = try #require(ClaudeCredentialParser.parse(Fixture.data("claude/usage/keychain.json")))
        #expect(c.isUsable(now: now))
        #expect(c.subscriptionType == "max")
        #expect(ClaudeUsageParser.planLabel(subscriptionType: c.subscriptionType, tier: c.rateLimitTier) == "Max 20×")
        #expect(!c.isUsable(now: TimeParsing.epoch(1_790_300_000_000)!))   // expired

        let hex = try #require(ClaudeCredentialParser.parse(Fixture.data("claude/usage/keychain.hex.txt")))
        #expect(hex.isUsable(now: now))
        let empty = try #require(ClaudeCredentialParser.parse(Fixture.data("claude/usage/keychain-empty-token.json")))
        #expect(!empty.isUsable(now: now))
        let noScope = try #require(ClaudeCredentialParser.parse(Fixture.data("claude/usage/keychain-no-profile-scope.json")))
        #expect(!noScope.isUsable(now: now))
        #expect(ClaudeCredentialParser.parse(Data(#"{"mcpOAuth":{}}"#.utf8)) == nil)
        #expect(!String(describing: c).contains("FAKE"))
    }

    @Test func modificationStampFromSecurityOutput() {
        let attrs = """
        keychain: "/Users/test/Library/Keychains/login.keychain-db"
            "acct"<blob>="test"
            "mdat"<timedate>=0x32303236303932313136343833335A00  "20260921164833Z\\000"
        """
        #expect(ClaudeCredentialParser.modificationStamp(attrs)?.contains("20260921164833Z") == true)
    }
}

@Suite("Claude reset estimator")
struct ClaudeResetEstimatorTests {
    typealias S = ClaudeResetEstimator.Sample
    let base = TimeParsing.iso8601("2026-09-21T16:00:00Z")!
    func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }

    @Test func sessionResetFromATightlySampledDrop() throws {
        let samples = [S(t: at(0), v: 37), S(t: at(15), v: 2), S(t: at(30), v: 3), S(t: at(45), v: 5)]
        let r = try #require(ClaudeResetEstimator.sessionReset(samples, observedAt: at(45)))
        // Window started between +0 and +15 min → reset ≈ +7.5 min + 5 h.
        #expect(abs(r.timeIntervalSince(at(7.5 + 300))) < 1)
    }

    @Test func sessionResetUnknownWhenTheGapIsWide() {
        let samples = [S(t: at(0), v: 0), S(t: at(180), v: 3), S(t: at(200), v: 7)]
        #expect(ClaudeResetEstimator.sessionReset(samples, observedAt: at(200)) == nil)
    }

    @Test func sessionResetNilWhenIdle() {
        #expect(ClaudeResetEstimator.sessionReset([S(t: at(0), v: 5), S(t: at(15), v: 0)], observedAt: at(15)) == nil)
    }

    @Test func weeklyResetSevenDaysAfterATightDrop() throws {
        let samples = [S(t: at(0), v: 82), S(t: at(60), v: 3), S(t: at(120), v: 5)]
        let r = try #require(ClaudeResetEstimator.weeklyReset(samples, observedAt: at(120)))
        #expect(abs(r.timeIntervalSince(at(30 + 7 * 1440))) < 1)
        let wide = [S(t: at(0), v: 82), S(t: at(2600), v: 14)]
        #expect(ClaudeResetEstimator.weeklyReset(wide, observedAt: at(2600)) == nil)
    }
}

@Suite("Codex usage")
struct CodexUsageTests {
    let now = TimeParsing.iso8601("2026-09-24T23:00:00Z")!

    @Test func whamWeeklyOnly() throws {
        let obs = try #require(CodexUsageParser.parseWham(Fixture.data("codex/usage/wham-weekly-only.json"), observedAt: now))
        #expect(obs.limits.planType == "prolite")
        #expect(obs.limits.windows.count == 1)
        #expect(obs.limits.windows[0].minutes == 10_080)
        #expect(obs.limits.windows[0].usedPercent == 62)
        #expect(obs.limits.windows[0].resetsAt == TimeParsing.epoch(1_790_431_976))
        let merged = CodexUsageParser.merge([obs], now: now)
        #expect(merged.windows.map(\.label) == ["Weekly"])
        #expect(merged.plan == "Pro Lite")
        #expect(!merged.limitReached)
    }

    @Test func whamFiveHourReachedWithResetAfterSeconds() throws {
        let obs = try #require(CodexUsageParser.parseWham(Fixture.data("codex/usage/wham-5h-weekly-reached.json"), observedAt: now))
        #expect(obs.limits.reachedType == "primary")
        #expect(obs.limits.windows[0].resetsAt == now.addingTimeInterval(1200))
        let merged = CodexUsageParser.merge([obs], now: now)
        #expect(merged.windows.map(\.label) == ["5h", "Weekly"])
        #expect(merged.limitReached)
    }

    @Test func appServerPrefersCodexBucket() throws {
        let root = try JSONDecoder().decode(JSONValue.self, from: Fixture.data("codex/usage/app-server-ratelimits.json"))
        let obs = try #require(CodexUsageParser.parseAppServer(result: root["result"]!, observedAt: now))
        #expect(obs.limits.windows.first?.usedPercent == 63)
        #expect(obs.limits.windows.first?.minutes == 10_080)
        #expect(obs.source == .codexAppServer)
    }

    @Test func freshAuthoritativeReadingIsCompleteOnItsOwn() throws {
        let wham = try #require(CodexUsageParser.parseWham(Fixture.data("codex/usage/wham-weekly-only.json"), observedAt: now))
        let oldRollout = CodexRateLimitObservation(
            limits: CodexRateLimits(limitID: "codex", planType: "plus",
                                    windows: [RateWindowObservation(minutes: 300, usedPercent: 50, resetsAt: now.addingTimeInterval(600))],
                                    reachedType: nil),
            observedAt: now.addingTimeInterval(-7200), source: .codexRollout)
        #expect(CodexUsageParser.merge([wham, oldRollout], now: now).windows.map(\.label) == ["Weekly"])
        // Without a fresh API reading, rollout windows merge by duration.
        let merged = CodexUsageParser.merge([oldRollout], now: now)
        #expect(merged.windows.map(\.label) == ["5h"])
        // Rollout windows older than 8 days are dropped (the plan changed).
        let ancient = CodexRateLimitObservation(limits: oldRollout.limits, observedAt: now.addingTimeInterval(-9 * 86_400), source: .codexRollout)
        #expect(CodexUsageParser.merge([ancient], now: now).windows.isEmpty)
    }

    @Test func otherLimitIDsAreIgnored() {
        let other = CodexRateLimitObservation(
            limits: CodexRateLimits(limitID: "codex_bengalfox", planType: nil,
                                    windows: [RateWindowObservation(minutes: 10_080, usedPercent: 3, resetsAt: nil)], reachedType: nil),
            observedAt: now, source: .codexRollout)
        #expect(CodexUsageParser.merge([other], now: now).windows.isEmpty)
    }

    @Test func authAndJWTExpiry() throws {
        let auth = try #require(CodexAuth.load(path: Fixture.url("codex/usage/auth-chatgpt.json").path, fs: LiveFileSystem()))
        #expect(auth.usesChatGPT)
        #expect(auth.accountID == "acct-FAKE")
        #expect(auth.expiresAt == Date(timeIntervalSince1970: 1_790_800_000))
        #expect(!String(describing: auth).contains("rt-FAKE"))
        let apikey = try #require(CodexAuth.load(path: Fixture.url("codex/usage/auth-apikey.json").path, fs: LiveFileSystem()))
        #expect(!apikey.usesChatGPT)
    }

    @Test func retryAfterParsing() {
        #expect(RetryAfter.parse("120", now: now) == 120)
        #expect(RetryAfter.parse("Thu, 24 Sep 2026 23:05:00 GMT", now: now) == 300)
        #expect(RetryAfter.parse("soon", now: now) == nil)
        var b = BackoffPolicy()
        #expect(b.rateLimited(retryAfter: 10, jitter: 0) == 60)
        #expect(b.failed(jitter: 0) == 60)   // second failure doubles from 30
        b.succeeded()
        #expect(b.failed(jitter: 0) == 30)
    }

    @Test func windowLabels() {
        #expect(WindowLabeler.label(minutes: 300) == "5h")
        #expect(WindowLabeler.label(minutes: 10_080) == "Weekly")
        #expect(WindowLabeler.label(minutes: 1440) == "Daily")
        #expect(WindowLabeler.label(minutes: 43_200) == "30d")
        #expect(WindowLabeler.label(minutes: 120) == "2h")
    }
}

/// Records requests; returns canned responses.
final class FakeHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    var responses: [Result<HTTPResponse, HTTPFailure>]
    private(set) var requests: [(URL, [String: String])] = []

    init(_ responses: [Result<HTTPResponse, HTTPFailure>]) { self.responses = responses }

    func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async -> Result<HTTPResponse, HTTPFailure> {
        lock.withLock {
            requests.append((url, headers))
            return responses.isEmpty ? .failure(.transport("no response")) : responses.removeFirst()
        }
    }
}

@Suite("Usage providers")
struct UsageProviderTests {
    @Test func codexProviderSendsExpectedHeadersAndParses() async throws {
        let dir = TempDir()
        dir.write("auth.json", Fixture.text("codex/usage/auth-chatgpt.json"))
        let http = FakeHTTPClient([.success(HTTPResponse(status: 200, body: Fixture.data("codex/usage/wham-weekly-only.json")))])
        var options = CodexUsageProvider.Options()
        options.useAppServerFallback = false
        let fixedNow = TimeParsing.iso8601("2026-09-24T23:00:00Z")!
        let provider = CodexUsageProvider(paths: CodexPaths(home: dir.path), http: http, inspector: FakeProcessInspector(),
                                          options: options, clock: { fixedNow })
        await provider.start()
        await provider.refresh(force: true)
        var it = provider.updates.makeAsyncIterator()
        var usage = await it.next()
        if usage?.windows.isEmpty == true { usage = await it.next() }
        #expect(usage?.windows.first?.usedPercent == 62)
        #expect(usage?.plan == "Pro Lite")
        let (url, headers) = try #require(http.requests.first)
        #expect(url.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
        #expect(headers["ChatGPT-Account-Id"] == "acct-FAKE")
        #expect(headers["Authorization"]?.hasPrefix("Bearer ") == true)
        await provider.stop()
    }

    @Test func codexProviderParksAfter401UntilAuthChanges() async {
        let dir = TempDir()
        dir.write("auth.json", Fixture.text("codex/usage/auth-chatgpt.json"))
        let http = FakeHTTPClient([.success(HTTPResponse(status: 401)), .success(HTTPResponse(status: 200, body: Data()))])
        var options = CodexUsageProvider.Options()
        options.useAppServerFallback = false
        options.minimumInterval = 0
        let fixedNow = TimeParsing.iso8601("2026-09-24T23:00:00Z")!
        let provider = CodexUsageProvider(paths: CodexPaths(home: dir.path), http: http, inspector: FakeProcessInspector(),
                                          options: options, clock: { fixedNow })
        await provider.refresh(force: true)
        await provider.refresh(force: true)
        #expect(http.requests.count == 1)
        await provider.stop()
    }
}
