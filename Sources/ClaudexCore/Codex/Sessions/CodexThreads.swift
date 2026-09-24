import Foundation

public struct LoadedThread: Sendable, Equatable {
    public var threadID: String
    public var rolloutPath: String?
    public var lockPath: String?
    public var ownerPID: Int32
}

/// Finds Codex threads that a live `codex` process (desktop app-server, TUI, exec) has open,
/// by listing each codex process's open files through libproc.
public struct LoadedThreadDetector: Sendable {
    public struct Result: Sendable, Equatable {
        public var threads: [String: LoadedThread]
        public var ownerPIDs: Set<Int32>
        /// libproc could not list a codex process's files (use the mtime fallback).
        public var fdListingFailed: Bool
    }

    private var codexPIDs: [Int32] = []
    private var lastEnumeration: Date = .distantPast

    public init() {}

    public static func isCodexExecutable(_ path: String) -> Bool {
        let name = Paths.basename(path)
        return name == "codex" || (name.hasPrefix("codex-") && name.hasSuffix("-apple-darwin"))
    }

    public mutating func detect(paths: CodexPaths, fs: FileSystemReading, inspector: ProcessInspector,
                                now: Date, forceEnumerate: Bool) -> Result {
        if forceEnumerate || now.timeIntervalSince(lastEnumeration) > 60 || codexPIDs.contains(where: { !inspector.isAlive($0) }) {
            let me = getpid()
            codexPIDs = inspector.allPIDs().filter { pid in
                pid != me && (inspector.executablePath(pid).map(Self.isCodexExecutable) ?? false)
            }
            lastEnumeration = now
        }
        let sessionsPrefix = fs.realpath(paths.sessionsDir) + "/"
        let locksPrefix = fs.realpath(paths.locksDir) + "/"
        var threads: [String: LoadedThread] = [:]
        var owners = Set<Int32>()
        var failed = false
        for pid in codexPIDs {
            guard let files = inspector.openVnodePaths(pid) else {
                if inspector.isAlive(pid) { failed = true }
                continue
            }
            for path in files {
                if path.hasPrefix(sessionsPrefix), let id = CodexPaths.threadID(fromRollout: path) {
                    threads[id, default: LoadedThread(threadID: id, ownerPID: pid)].rolloutPath = path
                    owners.insert(pid)
                } else if path.hasPrefix(locksPrefix), let id = CodexPaths.threadID(fromLock: path) {
                    threads[id, default: LoadedThread(threadID: id, ownerPID: pid)].lockPath = path
                    owners.insert(pid)
                }
            }
        }
        return Result(threads: threads, ownerPIDs: owners, fdListingFailed: failed)
    }
}

public struct CodexThreadInfo: Sendable, Equatable {
    public var id: String
    public var title: String?
    public var cwd: String?
    public var archived: Bool
    public var isSubagent: Bool
    public var rolloutPath: String?
    public var createdAt: Date?
    public var updatedAt: Date?
}

/// Thread metadata from Codex's own state database (read-only, no side files) with a
/// fallback to `session_index.jsonl` for names.
public enum CodexThreadIndex {
    public static func load(ids: [String], paths: CodexPaths, fs: FileSystemReading) -> [String: CodexThreadInfo] {
        guard !ids.isEmpty else { return [:] }
        var out: [String: CodexThreadInfo] = [:]
        if let dbPath = paths.stateDatabase(fs: fs), let db = SQLiteReadOnly.open(dbPath, fs: fs), db.tableExists("threads") {
            let cols = db.columns(of: "threads")
            let wanted = ["id", "name", "title", "cwd", "archived", "agent_role", "rollout_path", "created_at_ms",
                          "updated_at_ms", "created_at", "updated_at"].filter(cols.contains)
            if wanted.contains("id") {
                let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
                let sql = "SELECT \(wanted.joined(separator: ",")) FROM threads WHERE id IN (\(placeholders))"
                let spawned = db.tableExists("thread_spawn_edges") ? spawnedChildren(db, ids) : []
                for row in db.query(sql, ids.map { .text($0) }) ?? [] {
                    guard let id = row["id"]?.string else { continue }
                    let name = row["name"]?.string.flatMap { $0.isEmpty ? nil : $0 }
                    let title = row["title"]?.string.flatMap { $0.isEmpty ? nil : $0 }
                    func date(_ ms: String, _ s: String) -> Date? {
                        if let v = row[ms]?.int64 { return TimeParsing.epoch(Double(v)) }
                        if let v = row[s]?.int64 { return TimeParsing.epoch(Double(v)) }
                        return nil
                    }
                    out[id] = CodexThreadInfo(
                        id: id,
                        title: name ?? title,
                        cwd: row["cwd"]?.string,
                        archived: row["archived"]?.bool ?? false,
                        isSubagent: (row["agent_role"]?.string.map { !$0.isEmpty } ?? false) || spawned.contains(id),
                        rolloutPath: row["rollout_path"]?.string,
                        createdAt: date("created_at_ms", "created_at"),
                        updatedAt: date("updated_at_ms", "updated_at")
                    )
                }
            }
        }
        let missing = ids.filter { out[$0]?.title == nil }
        if !missing.isEmpty {
            let names = sessionIndexNames(paths: paths, fs: fs)
            for id in missing {
                guard let name = names[id] else { continue }
                if out[id] == nil {
                    out[id] = CodexThreadInfo(id: id, title: name, cwd: nil, archived: false, isSubagent: false,
                                              rolloutPath: nil, createdAt: nil, updatedAt: nil)
                } else {
                    out[id]?.title = name
                }
            }
        }
        return out
    }

    private static func spawnedChildren(_ db: SQLiteReadOnly, _ ids: [String]) -> Set<String> {
        let cols = db.columns(of: "thread_spawn_edges")
        guard cols.contains("child_thread_id") else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let rows = db.query("SELECT child_thread_id FROM thread_spawn_edges WHERE child_thread_id IN (\(placeholders))",
                            ids.map { .text($0) }) ?? []
        return Set(rows.compactMap { $0["child_thread_id"]?.string })
    }

    /// `{"id":…,"thread_name":…}` lines; only the last 256 KiB are read.
    static func sessionIndexNames(paths: CodexPaths, fs: FileSystemReading) -> [String: String] {
        guard let st = fs.stat(paths.sessionIndex), st.isRegular else { return [:] }
        let length = Int(min(st.size, 256 * 1024))
        guard let data = fs.read(paths.sessionIndex, offset: st.size - Int64(length), length: length) else { return [:] }
        var names: [String: String] = [:]
        for line in data.split(separator: 0x0A) {
            guard let v = try? JSONDecoder().decode(JSONValue.self, from: Data(line)),
                  let id = v["id"]?.string, let name = v["thread_name"]?.string, !name.isEmpty else { continue }
            names[id] = name
        }
        return names
    }
}

/// A rate-limit reading from any Codex source.
public struct CodexRateLimitObservation: Sendable, Equatable {
    public var limits: CodexRateLimits
    public var observedAt: Date
    public var source: UsageSource

    public init(limits: CodexRateLimits, observedAt: Date, source: UsageSource) {
        self.limits = limits
        self.observedAt = observedAt
        self.source = source
    }
}

public enum CodexRolloutScanner {
    /// Bootstraps a thread's state from the tail of its rollout (bounded read).
    public static func bootstrap(path: String, fs: FileSystemReading, budget: Int = 8 << 20)
        -> (state: CodexThreadState, result: BackwardScanner.Result)? {
        let box = CodexRecordBox()
        guard let result = BackwardScanner.scan(
            fs, path: path, budget: budget, maxLineBytes: CodexRecordDecoder.maxLineBytes,
            stop: { line in
                let r = CodexRecordDecoder.decode(line)
                box.records.append(r)
                return r.isTaskStarted
            }
        ) else { return nil }
        var state = CodexThreadState()
        let oldestFirst = box.records.reversed()
        if result.exhausted, !box.records.contains(where: \.isTaskStarted) {
            // A turn longer than the budget: it is (or was) running from before the window.
            let earliest = oldestFirst.lazy.compactMap(\.timestamp).first
            state.turn = .active(id: nil, startedAt: earliest)
        }
        for r in oldestFirst { state.apply(r) }
        return (state, result)
    }

    /// The newest rollout files (by directory date, then mtime), newest first.
    public static func newestRollouts(paths: CodexPaths, fs: FileSystemReading, limit: Int = 3) -> [String] {
        func sortedDirs(_ path: String) -> [String] {
            (fs.contentsOfDirectory(path) ?? []).filter { Int($0) != nil }.sorted(by: >)
        }
        var files: [(String, Date)] = []
        outer: for y in sortedDirs(paths.sessionsDir) {
            for m in sortedDirs(Paths.join(paths.sessionsDir, y)) {
                for d in sortedDirs(Paths.join(paths.sessionsDir, y, m)) {
                    let dir = Paths.join(paths.sessionsDir, y, m, d)
                    for name in fs.contentsOfDirectory(dir) ?? [] where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
                        let p = Paths.join(dir, name)
                        if let st = fs.stat(p) { files.append((p, st.modified)) }
                    }
                    if files.count >= limit { break outer }
                }
            }
        }
        return files.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Last `token_count.rate_limits` for the `codex` limit in the newest rollout.
    public static func latestRateLimits(paths: CodexPaths, fs: FileSystemReading) -> CodexRateLimitObservation? {
        for path in newestRollouts(paths: paths, fs: fs) {
            var found: CodexRateLimitObservation?
            _ = BackwardScanner.scan(fs, path: path, budget: 2 << 20, maxLineBytes: CodexRecordDecoder.maxLineBytes) { line in
                if case let .tokenCount(limits?, at) = CodexRecordDecoder.decode(line),
                   limits.limitID == nil || limits.limitID == "codex" {
                    found = CodexRateLimitObservation(limits: limits, observedAt: at ?? .distantPast, source: .codexRollout)
                    return true
                }
                return false
            }
            if let found { return found }
        }
        return nil
    }
}

final class CodexRecordBox: @unchecked Sendable {
    var records: [CodexRecord] = []
}
