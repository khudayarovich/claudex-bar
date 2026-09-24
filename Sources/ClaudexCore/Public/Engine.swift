import Foundation

public struct EngineConfiguration: Sendable {
    public var claudePaths: ClaudePaths
    public var codexPaths: CodexPaths
    public var claudeUsageAPI = true
    public var codexUsageAPI = true
    public var codexAppServerFallback = true

    public init(claudePaths: ClaudePaths = .standard(), codexPaths: CodexPaths = .standard()) {
        self.claudePaths = claudePaths
        self.codexPaths = codexPaths
    }
}

/// A source of session and usage snapshots (the live engine, or the demo driver).
public protocol StatusFeed: Sendable {
    var sessionSnapshots: AsyncStream<SessionSnapshot> { get }
    var usageSnapshots: AsyncStream<UsageSnapshot> { get }
    func start() async
    func stop() async
    /// The island was expanded: rescan now and refresh stale usage.
    func panelDidExpand() async
    func refreshNow() async
    func systemDidWake() async
}

/// Owns all sources and providers and publishes merged, smoothed snapshots.
public actor ClaudexEngine: StatusFeed {
    public nonisolated let sessionSnapshots: AsyncStream<SessionSnapshot>
    public nonisolated let usageSnapshots: AsyncStream<UsageSnapshot>
    private nonisolated let sessionContinuation: AsyncStream<SessionSnapshot>.Continuation
    private nonisolated let usageContinuation: AsyncStream<UsageSnapshot>.Continuation

    private let claudeSessions: ClaudeSessionSource
    private let codexSessions: CodexSessionSource
    private let claudeUsage: ClaudeUsageProvider
    private let codexUsage: CodexUsageProvider

    private var latest: [Provider: ProviderSessions] = [:]
    private var smoother = StateSmoother()
    private var recheck: Task<Void, Never>?
    private var usage = UsageSnapshot.empty
    private var lastPublished: SessionSnapshot?
    private var tasks: [Task<Void, Never>] = []
    private var started = false

    public init(configuration: EngineConfiguration = EngineConfiguration()) {
        let fs = LiveFileSystem()
        let inspector = LibprocInspector()
        let http = URLSessionHTTPClient()
        claudeSessions = ClaudeSessionSource(paths: configuration.claudePaths, fs: fs, inspector: inspector)
        codexSessions = CodexSessionSource(paths: configuration.codexPaths, fs: fs, inspector: inspector)
        var claudeOptions = ClaudeUsageProvider.Options()
        claudeOptions.useAPI = configuration.claudeUsageAPI
        claudeUsage = ClaudeUsageProvider(
            paths: configuration.claudePaths, fs: fs, http: http,
            credentials: ClaudeCredentialReader(claudeHome: configuration.claudePaths.home, fs: fs),
            options: claudeOptions)
        var codexOptions = CodexUsageProvider.Options()
        codexOptions.useAPI = configuration.codexUsageAPI
        codexOptions.useAppServerFallback = configuration.codexAppServerFallback
        codexUsage = CodexUsageProvider(paths: configuration.codexPaths, fs: fs, http: http, inspector: inspector,
                                        options: codexOptions)
        (sessionSnapshots, sessionContinuation) = AsyncStream.makeStream(of: SessionSnapshot.self,
                                                                         bufferingPolicy: .bufferingNewest(1))
        (usageSnapshots, usageContinuation) = AsyncStream.makeStream(of: UsageSnapshot.self,
                                                                     bufferingPolicy: .bufferingNewest(1))
    }

    public func start() async {
        guard !started else { return }
        started = true
        let claudeSessions = claudeSessions, codexSessions = codexSessions
        let claudeUsage = claudeUsage, codexUsage = codexUsage
        tasks.append(Task { [weak self] in
            for await batch in claudeSessions.updates { await self?.ingest(batch) }
        })
        tasks.append(Task { [weak self] in
            for await batch in codexSessions.updates { await self?.ingest(batch) }
        })
        tasks.append(Task {
            for await observation in codexSessions.rateLimitUpdates { await codexUsage.ingest(observation) }
        })
        tasks.append(Task { [weak self] in
            for await u in claudeUsage.updates { await self?.setUsage(u) }
        })
        tasks.append(Task { [weak self] in
            for await u in codexUsage.updates { await self?.setUsage(u) }
        })
        await claudeSessions.start()
        await codexSessions.start()
        await claudeUsage.start()
        await codexUsage.start()
    }

    public func stop() async {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        recheck?.cancel()
        await claudeSessions.stop()
        await codexSessions.stop()
        await claudeUsage.stop()
        await codexUsage.stop()
        sessionContinuation.finish()
        usageContinuation.finish()
    }

    public func panelDidExpand() async {
        await claudeSessions.rescan()
        await codexSessions.rescan()
        await claudeUsage.refresh(force: true)
        await codexUsage.refresh(force: true)
    }

    public func refreshNow() async { await panelDidExpand() }

    public func systemDidWake() async { await panelDidExpand() }

    public func setUsageAPIs(claude: Bool, codex: Bool) async {
        await claudeUsage.setUseAPI(claude)
        await codexUsage.setUseAPI(codex)
    }

    // MARK: - Merging

    private func ingest(_ batch: ProviderSessions) async {
        latest[batch.provider] = batch
        publish()
        await claudeUsage.setActive(!(latest[.claude]?.sessions.isEmpty ?? true))
        await codexUsage.setActive(!(latest[.codex]?.sessions.isEmpty ?? true))
    }

    private func publish() {
        let now = Date()
        let raw = Provider.allCases.flatMap { latest[$0]?.sessions ?? [] }
        let (sessions, recheckAt) = smoother.apply(raw, now: now)
        var health: [SourceID: SourceHealth] = [:]
        if let c = latest[.claude] { health[.claudeSessions] = c.health }
        if let c = latest[.codex] { health[.codexSessions] = c.health }
        let snapshot = SessionSnapshot(generatedAt: now, sessions: sessions, health: health)
        if snapshot.sessions != lastPublished?.sessions || snapshot.health != lastPublished?.health {
            lastPublished = snapshot
            sessionContinuation.yield(snapshot)
        }
        recheck?.cancel()
        recheck = nil
        if let recheckAt {
            let delay = max(0.05, recheckAt.timeIntervalSince(now))
            recheck = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                await self?.publish()
            }
        }
    }

    private func setUsage(_ u: ProviderUsage) {
        switch u.provider {
        case .claude: usage.claude = u
        case .codex: usage.codex = u
        }
        usage.generatedAt = Date()
        usageContinuation.yield(usage)
    }
}
