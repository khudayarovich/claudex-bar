import Foundation

/// Watches Claude Code's live session registry and transcripts, emitting derived sessions.
public actor ClaudeSessionSource {
    public nonisolated let updates: AsyncStream<ProviderSessions>
    private nonisolated let continuation: AsyncStream<ProviderSessions>.Continuation
    private nonisolated let queue = DispatchSerialQueue(label: "dev.claudexbar.claude-sessions", qos: .utility)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let paths: ClaudePaths
    private let fs: FileSystemReading
    private let inspector: ProcessInspector
    private let clock: @Sendable () -> Date
    private let pollInterval: Duration

    private var registry = ClaudeRegistryReader()
    private var items: [String: ClaudeRegistryReader.Item] = [:]
    private var trackers: [String: TranscriptTracker] = [:]        // by sessionId
    private var locateAttempts: [String: Date] = [:]
    private var watcher: FSEventsWatcher?
    private let exitWatcher = ProcessExitWatcher()
    private var tasks: [Task<Void, Never>] = []
    private var scheduled: Task<Void, Never>?
    private var registryDirty = true
    private var dirtySessions: Set<String> = []
    private var lastEmitted: ProviderSessions?
    private var started = false

    struct TranscriptTracker {
        var path: String
        var tailer: ForwardTailer
        var state: ClaudeTranscriptState
    }

    public init(
        paths: ClaudePaths = .standard(),
        fs: FileSystemReading = LiveFileSystem(),
        inspector: ProcessInspector = LibprocInspector(),
        pollInterval: Duration = .seconds(20),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.paths = paths
        self.fs = fs
        self.inspector = inspector
        self.pollInterval = pollInterval
        self.clock = clock
        (updates, continuation) = AsyncStream.makeStream(of: ProviderSessions.self, bufferingPolicy: .bufferingNewest(1))
    }

    public func start() {
        guard !started else { return }
        started = true
        let watchPaths = [paths.sessionsDir, paths.projectsDir].filter { fs.stat($0)?.isDirectory == true }
        let watcher = FSEventsWatcher(paths: watchPaths.isEmpty ? [paths.home] : watchPaths)
        if fs.stat(paths.home) != nil { watcher.start() }
        self.watcher = watcher

        tasks.append(Task { [weak self] in
            for await batch in watcher.events { await self?.handle(batch) }
        })
        let exits = exitWatcher.exits
        tasks.append(Task { [weak self] in
            for await _ in exits { await self?.markRegistryDirty() }
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
    }

    /// Full rescan (panel expanded, system woke, …).
    public func rescan() {
        registryDirty = true
        dirtySessions.formUnion(trackers.keys)
        refresh()
    }

    // MARK: - Event handling

    private func handle(_ batch: [FSEventsWatcher.Event]) {
        let sessionsPrefix = paths.sessionsDir + "/"
        for event in batch {
            if event.requiresRescan {
                registryDirty = true
                dirtySessions.formUnion(trackers.keys)
                continue
            }
            let path = event.path
            if path.hasPrefix(sessionsPrefix) || path == paths.sessionsDir {
                if path.hasSuffix(".json") || path == paths.sessionsDir { registryDirty = true }
                continue
            }
            if path.hasSuffix(".jsonl") {
                let sid = String(Paths.basename(path).dropLast(6))
                if trackers[sid] != nil {
                    dirtySessions.insert(sid)
                } else if items.values.contains(where: { $0.entry.sessionId == sid }) {
                    locateAttempts[sid] = nil   // transcript appeared: retry locating now
                    dirtySessions.insert(sid)
                }
            }
        }
        scheduleRefresh(after: .milliseconds(150))
    }

    private func markRegistryDirty() {
        registryDirty = true
        scheduleRefresh(after: .milliseconds(50))
    }

    private func pollTick() {
        // Safety net for missed events + time-based derivation rules.
        registryDirty = true
        for (sid, tracker) in trackers where fs.stat(tracker.path)?.size != tracker.tailer.readOffset {
            dirtySessions.insert(sid)
        }
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
        if registryDirty {
            registryDirty = false
            items = registry.scan(dir: paths.sessionsDir, fs: fs)
            if !registry.tornNames.isEmpty {
                registryDirty = true
                scheduleRefresh(after: .milliseconds(300))
            }
        }

        var sessions: [AgentSession] = []
        var liveSessionIDs = Set<String>()
        var watchedPIDs = Set<Int32>()
        for item in items.values {
            let entry = item.entry
            guard entry.isDisplayable, let pid = entry.pid, let sid = entry.sessionId else { continue }
            guard ClaudeLiveness.isAlive(entry, inspector: inspector) else { continue }
            liveSessionIDs.insert(sid)
            watchedPIDs.insert(pid)
            updateTracker(sessionID: sid, cwd: entry.cwd, now: now)
            let tracker = trackers[sid]
            let derived = ClaudeStateDeriver.derive(entry, transcript: tracker?.state, registryModified: item.modified, now: now)
            sessions.append(AgentSession(
                id: "claude:\(sid)#\(pid)",
                provider: .claude,
                state: derived.state,
                stateSince: derived.since,
                activity: derived.activity,
                title: ClaudeStateDeriver.title(entry, transcript: tracker?.state),
                project: entry.cwd.map(Paths.basename),
                cwd: entry.cwd,
                origin: entry.origin,
                pid: pid,
                appBundleID: entry.origin == .desktop ? Provider.claude.desktopBundleID : nil,
                lastEventAt: tracker?.state.lastRecordAt,
                confidence: derived.confidence
            ))
        }
        for sid in trackers.keys where !liveSessionIDs.contains(sid) { trackers[sid] = nil }
        for sid in locateAttempts.keys where !liveSessionIDs.contains(sid) { locateAttempts[sid] = nil }
        dirtySessions.removeAll()
        exitWatcher.setWatched(watchedPIDs)

        sessions.sort { $0.id < $1.id }
        let health: SourceHealth = fs.stat(paths.home)?.isDirectory == true ? .ok : .notInstalled
        let batch = ProviderSessions(provider: .claude, sessions: sessions, health: health)
        if batch != lastEmitted {
            lastEmitted = batch
            continuation.yield(batch)
        }
    }

    private func updateTracker(sessionID sid: String, cwd: String?, now: Date) {
        if var tracker = trackers[sid] {
            guard dirtySessions.contains(sid) else { return }
            switch tracker.tailer.poll(fs) {
            case let .lines(lines):
                for line in lines { tracker.state.apply(ClaudeRecordDecoder.decode(line)) }
                trackers[sid] = tracker
            case .unchanged:
                break
            case .missing, .needsBootstrap:
                trackers[sid] = bootstrap(path: tracker.path)
            }
            return
        }
        if let last = locateAttempts[sid], now.timeIntervalSince(last) < 10 { return }
        locateAttempts[sid] = now
        guard let path = locateTranscript(sessionID: sid, cwd: cwd) else { return }
        locateAttempts[sid] = nil
        trackers[sid] = bootstrap(path: path)
    }

    private func bootstrap(path: String) -> TranscriptTracker? {
        let box = RecordBox()
        guard let result = BackwardScanner.scan(
            fs, path: path, budget: 4 << 20, maxLineBytes: ClaudeRecordDecoder.maxLineBytes,
            stop: { line in
                let record = ClaudeRecordDecoder.decode(line)
                box.records.append(record)
                return record.isTurnStart
            }
        ) else { return nil }
        var state = ClaudeTranscriptState()
        for record in box.records.reversed() { state.apply(record) }
        let tailer = ForwardTailer(path: path, identity: result.fileIdentity, offset: result.endOffset,
                                   maxLineBytes: ClaudeRecordDecoder.maxLineBytes)
        return TranscriptTracker(path: path, tailer: tailer, state: state)
    }

    /// `~/.claude/projects/<cwd with non-alphanumerics → "-">/<sessionId>.jsonl`, else a search.
    private func locateTranscript(sessionID sid: String, cwd: String?) -> String? {
        let file = sid + ".jsonl"
        if let cwd {
            let encoded = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
            let candidate = Paths.join(paths.projectsDir, encoded, file)
            if fs.stat(candidate)?.isRegular == true { return candidate }
        }
        for dir in fs.contentsOfDirectory(paths.projectsDir) ?? [] {
            let candidate = Paths.join(paths.projectsDir, dir, file)
            if fs.stat(candidate)?.isRegular == true { return candidate }
        }
        return nil
    }
}

/// Collects decoded records inside the (synchronous) backward-scan predicate.
final class RecordBox: @unchecked Sendable {
    var records: [ClaudeRecord] = []
}
