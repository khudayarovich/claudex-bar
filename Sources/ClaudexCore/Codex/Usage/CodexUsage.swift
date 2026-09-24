import Darwin
import Foundation

// MARK: - Auth

public struct CodexAuth: Sendable, Equatable {
    public var mode: String?
    public var accessToken: SecretToken?
    public var accountID: String?
    public var expiresAt: Date?

    /// Reads `~/.codex/auth.json` (read-only; never refreshed or written).
    public static func load(path: String, fs: FileSystemReading) -> CodexAuth? {
        guard let data = fs.readAll(path, maxBytes: 64 * 1024),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        let token = root["tokens"]?["access_token"]?.string
        return CodexAuth(
            mode: root["auth_mode"]?.string,
            accessToken: token.map(SecretToken.init),
            accountID: root["tokens"]?["account_id"]?.string,
            expiresAt: token.flatMap(jwtExpiry)
        )
    }

    /// `exp` of a JWT, decoded without verification.
    public static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let payload = try? JSONDecoder().decode(JSONValue.self, from: data),
              let exp = payload["exp"]?.double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    public var usesChatGPT: Bool { (mode ?? "chatgpt").lowercased() == "chatgpt" }
}

// MARK: - Parsing

public enum CodexUsageParser {
    /// `GET /backend-api/wham/usage`.
    public static func parseWham(_ data: Data, observedAt: Date) -> CodexRateLimitObservation? {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              let rl = root["rate_limit"], rl.object != nil else { return nil }
        func window(_ w: JSONValue?) -> RateWindowObservation? {
            guard let w, w.object != nil else { return nil }
            let seconds = w["limit_window_seconds"]?.double
            let resets = TimeParsing.flexible(w["reset_at"])
                ?? w["reset_after_seconds"]?.double.map { observedAt.addingTimeInterval($0) }
            return RateWindowObservation(minutes: seconds.map { $0 / 60 }, usedPercent: w["used_percent"]?.double, resetsAt: resets)
        }
        let windows = [window(rl["primary_window"]), window(rl["secondary_window"])].compactMap { $0 }
        var reached = root["rate_limit_reached_type"]?.string ?? root["rate_limit_reached_type"]?["type"]?.string
        if reached == nil, rl["limit_reached"]?.bool == true { reached = "limit_reached" }
        let limits = CodexRateLimits(limitID: "codex", planType: root["plan_type"]?.string, windows: windows, reachedType: reached)
        return CodexRateLimitObservation(limits: limits, observedAt: observedAt, source: .codexWham)
    }

    /// `account/rateLimits/read` result: prefers `rateLimitsByLimitId.codex`.
    public static func parseAppServer(result: JSONValue, observedAt: Date) -> CodexRateLimitObservation? {
        let snapshot: JSONValue?
        if let byID = result["rateLimitsByLimitId"]?["codex"], byID.object != nil {
            snapshot = byID
        } else if let single = result["rateLimits"], single.object != nil {
            let id = single["limitId"]?.string
            snapshot = (id == nil || id == "codex") ? single : nil
        } else {
            snapshot = nil
        }
        guard let snapshot, var limits = CodexRecordDecoder.rateLimits(snapshot) else { return nil }
        if limits.reachedType == nil { limits.reachedType = snapshot["rateLimitReachedType"]?.string }
        return CodexRateLimitObservation(limits: limits, observedAt: observedAt, source: .codexAppServer)
    }

    public static func planLabel(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "prolite", "pro_lite": return "Pro Lite"
        case "pro": return "Pro"
        case "plus": return "Plus"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "edu": return "Edu"
        case "free": return "Free"
        default: return raw.capitalized
        }
    }

    /// Merges observations by window duration. A fresh authoritative reading (API or
    /// app-server) is complete on its own; otherwise the newest value per duration wins
    /// and durations not seen for 8 days are dropped (the plan changed).
    public static func merge(_ observations: [CodexRateLimitObservation], now: Date)
        -> (windows: [UsageWindow], plan: String?, limitReached: Bool, newest: Date?) {
        let codex = observations.filter { $0.limits.limitID == nil || $0.limits.limitID == "codex" }
            .sorted { $0.observedAt > $1.observedAt }
        guard let newest = codex.first else { return ([], nil, false, nil) }

        let authoritative = codex.first { $0.source != .codexRollout }
        let pool: [CodexRateLimitObservation]
        if let a = authoritative, now.timeIntervalSince(a.observedAt) < 3600 {
            pool = [a]
        } else {
            pool = codex
        }
        var byDuration: [Int: (RateWindowObservation, CodexRateLimitObservation)] = [:]
        for obs in pool {
            for w in obs.limits.windows where w.usedPercent != nil {
                guard let minutes = w.minutes else { continue }
                let key = Int(minutes.rounded())
                if byDuration[key] == nil { byDuration[key] = (w, obs) }
            }
        }
        var windows: [UsageWindow] = []
        for (minutes, (w, obs)) in byDuration {
            if now.timeIntervalSince(obs.observedAt) > 8 * 86_400 { continue }
            let m = Double(minutes)
            windows.append(UsageWindow(
                id: "codex.\(minutes)", kind: WindowLabeler.kind(minutes: m), label: WindowLabeler.label(minutes: m),
                usedPercent: w.usedPercent, resetsAt: w.resetsAt, windowDuration: m * 60,
                source: obs.source, fetchedAt: obs.observedAt
            ).resolved(now: now))
        }
        windows.sort { ($0.windowDuration ?? 0) < ($1.windowDuration ?? 0) }
        let plan = planLabel(codex.lazy.compactMap(\.limits.planType).first)
        let fresh = now.timeIntervalSince(newest.observedAt) < 3600
        let reached = fresh && newest.limits.reachedType != nil
        return (windows, plan, reached || windows.contains { ($0.usedPercent ?? 0) >= 100 }, newest.observedAt)
    }
}

// MARK: - App-server fallback

/// Spawns `codex -s read-only -a never app-server` and asks it for the account's rate
/// limits over stdio JSON-RPC. Codex refreshes its own login here, which is why this runs
/// only when no other codex process is alive (avoids refresh-token races).
public enum CodexAppServerClient {
    public enum Failure: Error, Sendable, Equatable {
        case spawn(String), timeout, protocolError(String), exited
    }

    public static func readRateLimits(binary: String, codexHome: String?, timeout: TimeInterval = 25)
        async -> Result<CodexRateLimitObservation, Failure> {
        await withCheckedContinuation { (cont: CheckedContinuation<Result<CodexRateLimitObservation, Failure>, Never>) in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: run(binary: binary, codexHome: codexHome, timeout: timeout))
            }
        }
    }

    static func run(binary: String, codexHome: String?, timeout: TimeInterval) -> Result<CodexRateLimitObservation, Failure> {
        let tmp = NSTemporaryDirectory() + "claudexbar-codex-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        var toChild: [Int32] = [0, 0]
        var fromChild: [Int32] = [0, 0]
        guard pipe(&toChild) == 0, pipe(&fromChild) == 0 else { return .failure(.spawn("pipe")) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, toChild[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, fromChild[1], STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addchdir_np(&actions, tmp)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)

        let env = ProcessInfo.processInfo.environment
        var environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=en_US.UTF-8", "RUST_LOG=error"]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR"] { if let v = env[key] { environment.append("\(key)=\(v)") } }
        if let codexHome { environment.append("CODEX_HOME=\(codexHome)") }
        let args = [binary, "-s", "read-only", "-a", "never", "app-server"]

        var pid: pid_t = 0
        let argv = args.map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        let rc = posix_spawn(&pid, binary, &actions, &attr, argv, envp)
        argv.forEach { free($0) }
        envp.forEach { free($0) }
        close(toChild[0])
        close(fromChild[1])
        guard rc == 0 else {
            close(toChild[1])
            close(fromChild[0])
            return .failure(.spawn(String(cString: strerror(rc))))
        }
        defer {
            close(toChild[1])
            close(fromChild[0])
            terminate(group: pid)
        }

        let deadline = Date().addingTimeInterval(timeout)
        var framer = LineFramer(maxLineBytes: 4 << 20)
        func send(_ object: [String: Any]) -> Bool {
            guard var data = try? JSONSerialization.data(withJSONObject: object) else { return false }
            data.append(0x0A)
            return data.withUnsafeBytes { raw in write(toChild[1], raw.baseAddress, raw.count) == raw.count }
        }
        func awaitResponse(id: Int) -> Result<JSONValue, Failure> {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { return .failure(.timeout) }
                var pfd = pollfd(fd: fromChild[0], events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, Int32(min(remaining, 5) * 1000))
                if ready < 0 { if errno == EINTR { continue }; return .failure(.protocolError("poll")) }
                if ready == 0 { continue }
                let n = read(fromChild[0], &buffer, buffer.count)
                if n <= 0 { return .failure(.exited) }
                for line in framer.push(Data(buffer[0..<n])) {
                    guard case let .complete(bytes) = line,
                          let message = try? JSONDecoder().decode(JSONValue.self, from: bytes) else { continue }
                    let messageID = message["id"]?.int
                    if message["method"] != nil {
                        // Server → client request: decline so the server never waits on us.
                        if let rid = message["id"] {
                            var reply: [String: Any] = ["error": ["code": -32601, "message": "unsupported"]]
                            reply["id"] = rid.int.map { $0 as Any } ?? (rid.string as Any)
                            _ = send(reply)
                        }
                        continue
                    }
                    guard messageID == id else { continue }
                    if let error = message["error"] {
                        return .failure(.protocolError(error["message"]?.string ?? "error"))
                    }
                    return .success(message["result"] ?? .null)
                }
            }
        }

        let initParams: [String: Any] = [
            "clientInfo": ["name": "claudexbar", "title": "ClaudexBar", "version": "0.1.0"],
            "capabilities": NSNull(),
        ]
        guard send(["id": 1, "method": "initialize", "params": initParams]) else { return .failure(.exited) }
        if case let .failure(f) = awaitResponse(id: 1) { return .failure(f) }
        guard send(["method": "initialized"]),
              send(["id": 2, "method": "account/rateLimits/read", "params": ["excludeResetCreditDetails": true]])
        else { return .failure(.exited) }
        switch awaitResponse(id: 2) {
        case let .success(result):
            guard let obs = CodexUsageParser.parseAppServer(result: result, observedAt: Date()) else {
                return .failure(.protocolError("no codex limits"))
            }
            return .success(obs)
        case let .failure(f):
            return .failure(f)
        }
    }

    /// SIGTERM the whole process group, then SIGKILL, and always reap.
    static func terminate(group pid: pid_t) {
        guard pid > 0 else { return }
        kill(-pid, SIGTERM)
        var status: Int32 = 0
        for _ in 0..<20 {
            if waitpid(pid, &status, WNOHANG) == pid { kill(-pid, SIGKILL); return }
            usleep(100_000)
        }
        kill(-pid, SIGKILL)
        waitpid(pid, &status, 0)
    }
}

public enum CodexBinaryLocator {
    public static func find(fs: FileSystemReading = LiveFileSystem()) -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            Paths.join(home, ".local/bin/codex"),
        ]
        for c in candidates {
            let real = fs.realpath(c)
            guard let st = fs.stat(real), st.isRegular, access(real, X_OK) == 0 else { continue }
            // Skip shell/JS shims: require a Mach-O binary.
            guard let head = fs.read(real, offset: 0, length: 4), head.count == 4 else { continue }
            let magic = head.withUnsafeBytes { $0.load(as: UInt32.self) }
            if [0xFEEDFACF, 0xCFFAEDFE, 0xCAFEBABE, 0xBEBAFECA].contains(magic) { return real }
        }
        return nil
    }
}

// MARK: - Provider

public actor CodexUsageProvider {
    public nonisolated let updates: AsyncStream<ProviderUsage>
    private nonisolated let continuation: AsyncStream<ProviderUsage>.Continuation

    public struct Options: Sendable {
        public var useAPI = true
        public var useAppServerFallback = true
        public var activeInterval: TimeInterval = 300
        public var idleInterval: TimeInterval = 900
        public var minimumInterval: TimeInterval = 60
        public var userAgent = "ClaudexBar/0.1"
        public init() {}
    }

    private let paths: CodexPaths
    private let fs: FileSystemReading
    private let http: HTTPClient
    private let inspector: ProcessInspector
    private let clock: @Sendable () -> Date
    private var options: Options

    private var observations: [UsageSource: CodexRateLimitObservation] = [:]
    private var backoff = BackoffPolicy()
    private var nextAttempt: Date = .distantPast
    private var lastAttempt: Date = .distantPast
    private var rejectedAuthStamp: Date?
    private var appServerLastAttempt: Date = .distantPast
    private var appServerFailures = 0
    private var appServerDisabledUntil: Date = .distantPast
    private var problem: String?
    private var active = true
    private var loop: Task<Void, Never>?
    private var lastEmitted: ProviderUsage?

    public init(paths: CodexPaths = .standard(), fs: FileSystemReading = LiveFileSystem(),
                http: HTTPClient = URLSessionHTTPClient(), inspector: ProcessInspector = LibprocInspector(),
                options: Options = Options(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.paths = paths
        self.fs = fs
        self.http = http
        self.inspector = inspector
        self.options = options
        self.clock = clock
        (updates, continuation) = AsyncStream.makeStream(of: ProviderUsage.self, bufferingPolicy: .bufferingNewest(1))
    }

    public func start() {
        guard loop == nil else { return }
        if let rollout = CodexRolloutScanner.latestRateLimits(paths: paths, fs: fs) { observations[.codexRollout] = rollout }
        // The first emit happens after the first API attempt, so a stale log value never flashes.
        loop = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            while !Task.isCancelled {
                await self?.tick(force: false)
                try? await Task.sleep(for: .seconds(60), tolerance: .seconds(5))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        continuation.finish()
    }

    public func setActive(_ value: Bool) { active = value }
    public func setUseAPI(_ value: Bool) {
        options.useAPI = value
        if !value { observations[.codexWham] = nil; observations[.codexAppServer] = nil }
    }

    /// Rate limits Codex logged in a rollout (arrives instantly while a turn runs).
    public func ingest(_ observation: CodexRateLimitObservation) {
        let current = observations[observation.source]
        if current == nil || observation.observedAt > current!.observedAt {
            observations[observation.source] = observation
            emit()
        }
    }

    public func refresh(force: Bool) async { await tick(force: force) }

    private func tick(force: Bool) async {
        let now = clock()
        let interval = active ? options.activeInterval : options.idleInterval
        let due = now >= nextAttempt && now.timeIntervalSince(lastAttempt) >= (force ? options.minimumInterval : interval)
        if options.useAPI, due { await fetch(now: now) }
        emit()
    }

    private func fetch(now: Date) async {
        lastAttempt = now
        let auth = CodexAuth.load(path: paths.authFile, fs: fs)
        let authStamp = fs.stat(paths.authFile)?.modified
        var whamUsable = false
        if let auth, auth.usesChatGPT, let token = auth.accessToken, !token.isEmpty,
           (auth.expiresAt.map { $0 > now.addingTimeInterval(60) } ?? true),
           rejectedAuthStamp == nil || rejectedAuthStamp != authStamp {
            whamUsable = true
            var headers = token.withValue { ["Authorization": "Bearer \($0)"] }
            headers["Accept"] = "application/json"
            headers["User-Agent"] = options.userAgent
            if let id = auth.accountID { headers["ChatGPT-Account-Id"] = id }
            let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
            let result = await http.get(url, headers: headers, timeout: 15)
            let jitter = Double.random(in: 0...1)
            switch result {
            case let .success(r) where r.status == 200:
                if let obs = CodexUsageParser.parseWham(r.body, observedAt: clock()) {
                    observations[.codexWham] = obs
                    backoff.succeeded()
                    problem = nil
                    return
                }
                problem = "Unexpected usage response"
                nextAttempt = now.addingTimeInterval(1800)
            case let .success(r) where r.status == 401 || r.status == 403:
                rejectedAuthStamp = authStamp
                whamUsable = false
                problem = "Codex login rejected"
            case let .success(r) where r.status == 429:
                nextAttempt = now.addingTimeInterval(backoff.rateLimited(
                    retryAfter: RetryAfter.parse(r.headers["retry-after"], now: now), jitter: jitter))
                problem = "Rate limited"
                return
            case .success:
                nextAttempt = now.addingTimeInterval(backoff.failed(jitter: jitter))
                problem = "Usage service error"
                return
            case .failure:
                nextAttempt = now.addingTimeInterval(backoff.failed(jitter: jitter))
                problem = "Offline"
                return
            }
        }
        if !whamUsable { await appServerFallback(now: now) }
    }

    /// Guarded: only when no other codex process is alive, at most every 30 min,
    /// disabled for 24 h after 3 consecutive failures.
    private func appServerFallback(now: Date) async {
        guard options.useAppServerFallback, now >= appServerDisabledUntil,
              now.timeIntervalSince(appServerLastAttempt) >= 1800 else { return }
        let codexRunning = inspector.allPIDs().contains { pid in
            inspector.executablePath(pid).map(LoadedThreadDetector.isCodexExecutable) ?? false
        }
        guard !codexRunning, let binary = CodexBinaryLocator.find(fs: fs) else { return }
        appServerLastAttempt = now
        switch await CodexAppServerClient.readRateLimits(binary: binary, codexHome: nil) {
        case let .success(obs):
            observations[.codexAppServer] = obs
            appServerFailures = 0
            problem = nil
        case .failure:
            appServerFailures += 1
            if appServerFailures >= 3 {
                appServerDisabledUntil = now.addingTimeInterval(86_400)
                appServerFailures = 0
            }
        }
    }

    private func emit() {
        let now = clock()
        let merged = CodexUsageParser.merge(Array(observations.values), now: now)
        let status: UsageStatus
        if merged.windows.isEmpty {
            status = .unavailable(problem ?? "No usage data yet")
        } else if let newest = merged.newest {
            let freshSource = observations.values.contains { $0.source != .codexRollout && $0.observedAt == newest }
            status = now.timeIntervalSince(newest) > (freshSource ? 15 * 60 : 30 * 60) ? .stale(since: newest) : .ok
        } else {
            status = .ok
        }
        let usage = ProviderUsage(provider: .codex, plan: merged.plan, windows: merged.windows,
                                  limitReached: merged.limitReached, status: status, lastSuccessAt: merged.newest)
        if usage != lastEmitted {
            lastEmitted = usage
            continuation.yield(usage)
        }
    }
}
