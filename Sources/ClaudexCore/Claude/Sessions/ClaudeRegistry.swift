import Foundation

/// One `~/.claude/sessions/<pid>.json` entry, decoded leniently (every field optional,
/// wrong types become nil, unknown enum values are preserved).
public struct ClaudeRegistryEntry: Sendable, Equatable, Decodable {
    public enum Status: Sendable, Equatable {
        case busy, shell, idle, waiting
        case unknown(String)

        init(_ raw: String) {
            switch raw {
            case "busy": self = .busy
            case "shell": self = .shell
            case "idle": self = .idle
            case "waiting": self = .waiting
            default: self = .unknown(raw)
            }
        }
    }

    public enum Kind: Sendable, Equatable {
        case interactive, bg, daemon, daemonWorker
        case unknown(String)

        init(_ raw: String) {
            switch raw {
            case "interactive": self = .interactive
            case "bg", "background": self = .bg
            case "daemon": self = .daemon
            case "daemon-worker": self = .daemonWorker
            default: self = .unknown(raw)
            }
        }
    }

    public var pid: Int32?
    public var sessionId: String?
    public var cwd: String?
    public var startedAt: Double?
    public var procStart: String?
    public var version: String?
    public var kind: Kind?
    public var entrypoint: String?
    public var name: String?
    public var status: Status?
    public var waitingFor: String?
    public var updatedAt: Double?
    public var statusUpdatedAt: Double?
    public var pidDomain: String?
    public var spare: Bool?
    // Background-job extras.
    public var state: String?
    public var detail: String?
    public var tempo: String?
    public var needs: String?

    enum CodingKeys: String, CodingKey {
        case pid, sessionId, cwd, startedAt, procStart, version, kind, entrypoint, name, status, waitingFor
        case updatedAt, statusUpdatedAt, pidDomain, spare, state, detail, tempo, needs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let p = c.lenient(Int64.self, .pid), p > 0, p <= Int64(Int32.max) { pid = Int32(p) }
        sessionId = c.lenient(String.self, .sessionId)
        cwd = c.lenient(String.self, .cwd)
        startedAt = Self.timestamp(c.lenient(Double.self, .startedAt))
        procStart = c.lenient(String.self, .procStart)
        version = c.lenient(String.self, .version)
        kind = c.lenient(String.self, .kind).map(Kind.init)
        entrypoint = c.lenient(String.self, .entrypoint)
        name = c.lenient(String.self, .name)
        status = c.lenient(String.self, .status).map(Status.init)
        waitingFor = c.lenient(String.self, .waitingFor)
        updatedAt = Self.timestamp(c.lenient(Double.self, .updatedAt))
        statusUpdatedAt = Self.timestamp(c.lenient(Double.self, .statusUpdatedAt))
        pidDomain = c.lenient(String.self, .pidDomain)
        spare = c.lenient(Bool.self, .spare)
        state = c.lenient(String.self, .state)
        detail = c.lenient(String.self, .detail)
        tempo = c.lenient(String.self, .tempo)
        needs = c.lenient(String.self, .needs)
    }

    /// Timestamps are epoch milliseconds; reject non-finite or absurd values.
    static func timestamp(_ v: Double?) -> Double? {
        guard let v, v.isFinite, v > 0, v < 4e15 else { return nil }
        return v
    }

    public static func date(ms: Double?) -> Date? {
        ms.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    /// Which entries appear in the widget.
    public var isDisplayable: Bool {
        if spare == true { return false }
        if let pidDomain, pidDomain != "darwin" { return false }
        switch kind {
        case .daemon?, .daemonWorker?, .unknown?: return false
        case .interactive?, .bg?, nil: break
        }
        if let e = entrypoint, e.hasPrefix("sdk-") { return false }
        return true
    }

    public var origin: SessionOrigin {
        if kind == .bg { return .background }
        switch entrypoint {
        case "claude-desktop"?, "local-agent"?: return .desktop
        case let e? where e.hasPrefix("claude-coworker"):
            return e.hasSuffix("-terminal") ? .terminal : .desktop
        case "cli"?, nil: return .terminal
        case "claude-vscode"?: return .ide
        case let e? where e.hasPrefix("sdk-"): return .sdk
        case let e?: return .other(e)
        }
    }
}

/// Reads the registry directory with caching and torn-write tolerance.
public struct ClaudeRegistryReader: Sendable {
    public static let maxFileBytes = 262_144

    struct CacheEntry: Sendable {
        var stat: FileStat
        var entry: ClaudeRegistryEntry
    }

    private var cache: [String: CacheEntry] = [:]
    /// Names whose last read was unparseable (likely a torn write) — re-read soon.
    public private(set) var tornNames: Set<String> = []

    public init() {}

    /// `^[1-9][0-9]*\.json$` and canonical (no leading zeros, fits in Int32).
    public static func isRegistryName(_ name: String) -> Bool {
        guard name.hasSuffix(".json") else { return false }
        let stem = name.dropLast(5)
        guard !stem.isEmpty, stem.first != "0", stem.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int32(stem) else { return false }
        return String(value) == stem
    }

    public struct Item: Sendable, Equatable {
        public var entry: ClaudeRegistryEntry
        public var modified: Date
    }

    /// Returns all parseable entries keyed by file name. Never opens `*.key` files.
    public mutating func scan(dir: String, fs: FileSystemReading) -> [String: Item] {
        guard let names = fs.contentsOfDirectory(dir) else {
            cache.removeAll()
            return [:]
        }
        var result: [String: Item] = [:]
        var live = Set<String>()
        tornNames.removeAll()
        for name in names where Self.isRegistryName(name) {
            live.insert(name)
            let path = Paths.join(dir, name)
            guard let st = fs.stat(path), st.isRegular else { continue }
            guard st.size <= Int64(Self.maxFileBytes) else { continue }
            if let cached = cache[name], cached.stat == st {
                result[name] = Item(entry: cached.entry, modified: st.modified)
                continue
            }
            if let data = fs.readAll(path, maxBytes: Self.maxFileBytes),
               let entry = try? JSONDecoder().decode(ClaudeRegistryEntry.self, from: data) {
                cache[name] = CacheEntry(stat: st, entry: entry)
                result[name] = Item(entry: entry, modified: st.modified)
            } else {
                tornNames.insert(name)
                if let previous = cache[name] { result[name] = Item(entry: previous.entry, modified: previous.stat.modified) }
            }
        }
        for name in cache.keys where !live.contains(name) { cache[name] = nil }
        return result
    }
}

public enum ClaudeLiveness {
    /// Alive and not a recycled PID: `procStart` (UTC `ps -o lstart`) must match the
    /// kernel's start time within a second; otherwise fall back to `startedAt`.
    public static func isAlive(_ e: ClaudeRegistryEntry, inspector: ProcessInspector) -> Bool {
        guard let pid = e.pid, inspector.isAlive(pid) else { return false }
        let kernelStart = inspector.startTime(pid)
        if let ps = e.procStart, let parsed = TimeParsing.procStart(ps) {
            guard let kernelStart else { return true }
            return abs(floor(kernelStart.timeIntervalSince1970) - parsed.timeIntervalSince1970) <= 1
        }
        if let started = ClaudeRegistryEntry.date(ms: e.startedAt), let kernelStart {
            // The CLI records startedAt ~1 s after the process starts.
            return kernelStart <= started.addingTimeInterval(2) && started.timeIntervalSince(kernelStart) < 120
        }
        return true
    }
}
