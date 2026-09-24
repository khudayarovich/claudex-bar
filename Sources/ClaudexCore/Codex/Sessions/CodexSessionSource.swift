import Foundation

/// Watches loaded Codex threads and their rollouts, emitting derived sessions and the
/// rate-limit snapshots Codex logs after every model response.
public actor CodexSessionSource {
    public nonisolated let updates: AsyncStream<ProviderSessions>
    private nonisolated let continuation: AsyncStream<ProviderSessions>.Continuation
    public nonisolated let rateLimitUpdates: AsyncStream<CodexRateLimitObservation>
    private nonisolated let rateContinuation: AsyncStream<CodexRateLimitObservation>.Continuation
    private nonisolated let queue = DispatchSerialQueue(label: "dev.claudexbar.codex-sessions", qos: .utility)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public struct Filter: Sendable {
        public var recentWindow: TimeInterval = 12 * 3600
        public var errorWindow: TimeInterval = 24 * 3600
        public init() {}
    }

    private let paths: CodexPaths
    private let fs: FileSystemReading
    private let inspector: ProcessInspector
    private let clock: @Sendable () -> Date
    private let pollInterval: Duration
    private let filter: Filter

    private var detector = LoadedThreadDetector()
    private var loaded: [String: LoadedThread] = [:]
    private var fdListingFailed = false
    private var trackers: [String: RolloutTracker] = [:]
    private var index: [String: CodexThreadInfo] = [:]
    private var indexRefreshedAt: Date = .distantPast
    private var ownerApps: [Int32: String?] = [:]
    private var watcher: FSEventsWatcher?
    private let exitWatcher = ProcessExitWatcher()
    private var tasks: [Task<Void, Never>] = []
    private var scheduled: Task<Void, Never>?
    private var loadedDirty = true
    private var forceEnumerate = true
    private var dirtyThreads: Set<String> = []
    private var lastEmitted: ProviderSessions?
    private var lastRateLimitAt: Date?
    private var started = false

    struct RolloutTracker {
        var path: String
        var tailer: ForwardTailer
        var state: CodexThreadState
    }

    public init(
        paths: CodexPaths = .standard(),
        fs: FileSystemReading = LiveFileSystem(),
        inspector: ProcessInspector = LibprocInspector(),
        pollInterval: Duration = .seconds(20),
        filter: Filter = Filter(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.paths = paths
        self.fs = fs
        self.inspector = inspector
        self.pollInterval = pollInterval
        self.filter = filter
        self.clock = clock
        (updates, continuation) = AsyncStream.makeStream(of: ProviderSessions.self, bufferingPolicy: .bufferingNewest(1))
        (rateLimitUpdates, rateContinuation) = AsyncStream.makeStream(of: CodexRateLimitObservation.self,
                                                                      bufferingPolicy: .bufferingNewest(4))
    }

    public func start() {
        guard !started else { return }
        started = true
        let watchPaths = [paths.sessionsDir, paths.locksDir].filter { fs.stat($0)?.isDirectory == true }
        if !watchPaths.isEmpty {
            let watcher = FSEventsWatcher(paths: watchPaths)
            watcher.start()
            self.watcher = watcher
            tasks.append(Task { [weak self] in
                for await batch in watcher.events { await self?.handle(batch) }
            })
        }
        let exits = exitWatcher.exits
        tasks.append(Task { [weak self] in
            for await _ in exits { await self?.markLoadedDirty(enumerate: true) }
        })
        let interval = pollInterval
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval, tolerance: .seconds(2))
                await self?.pollTick()
            }
        })
        refresh()
    }

    public func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        scheduled?.cancel()
        watcher?.stop()
        exitWatcher.setWatched([])
        continuation.finish()
        rateContinuation.finish()
    }

    public func rescan() {
        loadedDirty = true
        forceEnumerate = true
        dirtyThreads.formUnion(trackers.keys)
        refresh()
    }

    // MARK: - Events

    private func handle(_ batch: [FSEventsWatcher.Event]) {
        let locksPrefix = paths.locksDir
        for event in batch {
            if event.requiresRescan {
                loadedDirty = true
                dirtyThreads.formUnion(trackers.keys)
                continue
            }
            if event.path.hasPrefix(locksPrefix) {
                loadedDirty = true
                forceEnumerate = true
            } else if let id = CodexPaths.threadID(fromRollout: event.path) {
                if trackers[id] != nil {
                    dirtyThreads.insert(id)
                } else {
                    loadedDirty = true   // a new thread's rollout appeared
                }
            }
        }
        scheduleRefresh(after: .milliseconds(150))
    }

    private func markLoadedDirty(enumerate: Bool) {
        loadedDirty = true
        if enumerate { forceEnumerate = true }
        scheduleRefresh(after: .milliseconds(50))
    }

    private func pollTick() {
        loadedDirty = true
        for (id, t) in trackers where fs.stat(t.path)?.size != t.tailer.readOffset { dirtyThreads.insert(id) }
        refresh()
    }

    private func scheduleRefresh(after delay: Duration) {
        guard scheduled == nil else { return }
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: delay, tolerance: .milliseconds(50))
            await self?.runScheduled()
        }
    }

    private func runScheduled() {
        scheduled = nil
        refresh()
    }

    // MARK: - Refresh

    private func refresh() {
        let now = clock()
        if loadedDirty {
            loadedDirty = false
            let result = detector.detect(paths: paths, fs: fs, inspector: inspector, now: now, forceEnumerate: forceEnumerate)
            forceEnumerate = false
            loaded = result.threads
            fdListingFailed = result.fdListingFailed
            if fdListingFailed { addMTimeFallbackThreads(now: now) }
            exitWatcher.setWatched(result.ownerPIDs)
            for pid in ownerApps.keys where !result.ownerPIDs.contains(pid) { ownerApps[pid] = nil }
        }

        let ids = Array(loaded.keys)
        if ids.contains(where: { index[$0] == nil }) || now.timeIntervalSince(indexRefreshedAt) > 300 {
            index = CodexThreadIndex.load(ids: ids, paths: paths, fs: fs)
            indexRefreshedAt = now
        }

        var sessions: [AgentSession] = []
        var newestRate: (CodexRateLimits, Date)?
        for (id, thread) in loaded {
            let info = index[id]
            if info?.archived == true || info?.isSubagent == true { continue }
            guard let path = thread.rolloutPath ?? info?.rolloutPath else { continue }
            updateTracker(id: id, path: path)
            guard let tracker = trackers[id] else { continue }
            let state = tracker.state
            if let rl = state.rateLimits, let at = state.rateLimitsAt, rl.limitID == nil || rl.limitID == "codex",
               at > (newestRate?.1 ?? .distantPast) {
                newestRate = (rl, at)
            }

            let lockBirth = thread.lockPath.flatMap { fs.stat($0)?.created }
            let ownerStart = inspector.startTime(thread.ownerPID)
            let context = CodexThreadContext(ownerPID: thread.ownerPID, ownerStart: ownerStart, lockBirth: lockBirth,
                                             loaded: true, confidence: fdListingFailed ? .inferred : .reported)
            let fallback = lockBirth ?? info?.updatedAt ?? now
            let derived = CodexStateDeriver.derive(state, context: context, fallbackSince: fallback, now: now)
            guard isVisible(state: state, derived: derived, now: now) else { continue }

            let appPath = ownerApp(thread.ownerPID)
            let origin = CodexStateDeriver.origin(meta: state.meta, ownerAppPath: appPath)
            let cwd = info?.cwd ?? state.metaCwd
            let title = info?.title ?? cwd.map(Paths.basename) ?? "Codex thread"
            sessions.append(AgentSession(
                id: "codex:\(id)",
                provider: .codex,
                state: derived.state,
                stateSince: derived.since,
                activity: derived.activity,
                title: TextSanitizer.oneLine(title, maxLength: 60),
                project: cwd.map(Paths.basename),
                cwd: cwd,
                origin: origin,
                pid: thread.ownerPID,
                appBundleID: origin == .desktop ? Provider.codex.desktopBundleID : nil,
                lastEventAt: state.lastEventAt,
                confidence: derived.confidence
            ))
        }
        for id in trackers.keys where loaded[id] == nil { trackers[id] = nil }
        dirtyThreads.removeAll()

        if let (limits, at) = newestRate, at > (lastRateLimitAt ?? .distantPast) {
            lastRateLimitAt = at
            rateContinuation.yield(CodexRateLimitObservation(limits: limits, observedAt: at, source: .codexRollout))
        }

        sessions.sort { $0.id < $1.id }
        let health: SourceHealth
        if fs.stat(paths.home)?.isDirectory != true {
            health = .notInstalled
        } else if fdListingFailed {
            health = .degraded("Could not list Codex's open files; using file times")
        } else {
            health = .ok
        }
        let batch = ProviderSessions(provider: .codex, sessions: sessions, health: health)
        if batch != lastEmitted {
            lastEmitted = batch
            continuation.yield(batch)
        }
    }

    private func isVisible(state: CodexThreadState, derived: DerivedState, now: Date) -> Bool {
        if state.isActive || state.pendingQuestion != nil { return true }
        if case .needsAttention = derived.state { return now.timeIntervalSince(derived.since) < filter.errorWindow }
        let last = max(derived.since, state.lastEventAt ?? .distantPast)
        return now.timeIntervalSince(last) < filter.recentWindow
    }

    private func updateTracker(id: String, path: String) {
        if var tracker = trackers[id], tracker.path == path {
            guard dirtyThreads.contains(id) else { return }
            switch tracker.tailer.poll(fs) {
            case let .lines(lines):
                for line in lines { tracker.state.apply(CodexRecordDecoder.decode(line)) }
                trackers[id] = tracker
            case .unchanged:
                break
            case .missing, .needsBootstrap:
                trackers[id] = bootstrap(path: path)
            }
            return
        }
        trackers[id] = bootstrap(path: path)
    }

    private func bootstrap(path: String) -> RolloutTracker? {
        guard let (state, result) = CodexRolloutScanner.bootstrap(path: path, fs: fs) else { return nil }
        let tailer = ForwardTailer(path: path, identity: result.fileIdentity, offset: result.endOffset,
                                   maxLineBytes: CodexRecordDecoder.maxLineBytes)
        return RolloutTracker(path: path, tailer: tailer, state: state)
    }

    private func ownerApp(_ pid: Int32) -> String? {
        if let cached = ownerApps[pid] { return cached }
        let app = ProcessAncestry.owningAppBundle(pid, inspector: inspector)
        ownerApps[pid] = app
        return app
    }

    /// When libproc can't list files: a lock file plus a recently written rollout.
    private func addMTimeFallbackThreads(now: Date) {
        for name in fs.contentsOfDirectory(paths.locksDir) ?? [] {
            guard let id = CodexPaths.threadID(fromLock: name), loaded[id] == nil else { continue }
            let info = index[id] ?? CodexThreadIndex.load(ids: [id], paths: paths, fs: fs)[id]
            guard let rollout = info?.rolloutPath, let st = fs.stat(rollout),
                  now.timeIntervalSince(st.modified) < 600 else { continue }
            loaded[id] = LoadedThread(threadID: id, rolloutPath: rollout, lockPath: Paths.join(paths.locksDir, name), ownerPID: 0)
        }
    }
}
