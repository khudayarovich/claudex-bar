import Foundation
import Testing
@testable import ClaudexCore

struct FakeProcessInspector: ProcessInspector {
    var alive: Set<Int32> = []
    var starts: [Int32: Date] = [:]
    var parents: [Int32: Int32] = [:]
    var paths: [Int32: String] = [:]
    var openFiles: [Int32: [String]] = [:]

    func isAlive(_ pid: Int32) -> Bool { alive.contains(pid) }
    func startTime(_ pid: Int32) -> Date? { starts[pid] }
    func parent(_ pid: Int32) -> Int32? { parents[pid] }
    func executablePath(_ pid: Int32) -> String? { paths[pid] }
    func allPIDs() -> [Int32] { Array(alive) }
    func openVnodePaths(_ pid: Int32) -> [String]? { openFiles[pid] }
}

enum ClaudeFixtures {
    static func entry(_ name: String) throws -> ClaudeRegistryEntry {
        try JSONDecoder().decode(ClaudeRegistryEntry.self, from: Fixture.data("claude/registry/\(name)"))
    }

    static func transcript(_ name: String) -> ClaudeTranscriptState {
        var framer = LineFramer(maxLineBytes: ClaudeRecordDecoder.maxLineBytes)
        var state = ClaudeTranscriptState()
        for line in framer.push(Fixture.data("claude/transcripts/\(name)")) {
            state.apply(ClaudeRecordDecoder.decode(line))
        }
        return state
    }

    static func date(_ s: String) -> Date { TimeParsing.iso8601(s)! }
}

@Suite("Claude registry")
struct ClaudeRegistryTests {
    @Test func decodesDesktopEntry() throws {
        let e = try ClaudeFixtures.entry("desktop-busy.json")
        #expect(e.pid == 41001)
        #expect(e.status == .busy)
        #expect(e.kind == .interactive)
        #expect(e.origin == .desktop)
        #expect(e.name == "Demo")
        #expect(e.isDisplayable)
        #expect(e.statusUpdatedAt == 1_790_103_784_413)
    }

    @Test func unknownValuesAndWrongTypesAreTolerated() throws {
        let future = try ClaudeFixtures.entry("future-fields.json")
        #expect(future.status == .unknown("compacting"))
        let wrong = try ClaudeFixtures.entry("wrong-types.json")
        #expect(wrong.pid == nil)
        #expect(wrong.sessionId == nil)
        #expect(wrong.cwd == nil)
        #expect(wrong.status == nil)
        #expect(wrong.startedAt == nil)
        #expect(wrong.statusUpdatedAt == nil)   // 1e30 is out of range
    }

    @Test(arguments: ["daemon.json", "spare.json", "sdk-ts.json", "foreign-pid-domain.json"])
    func hiddenEntries(name: String) throws {
        #expect(try !ClaudeFixtures.entry(name).isDisplayable)
    }

    @Test func registryNames() {
        #expect(ClaudeRegistryReader.isRegistryName("41001.json"))
        #expect(!ClaudeRegistryReader.isRegistryName("0123.json"))
        #expect(!ClaudeRegistryReader.isRegistryName("41001.00ff00ff.key"))
        #expect(!ClaudeRegistryReader.isRegistryName("abc.json"))
        #expect(!ClaudeRegistryReader.isRegistryName("99999999999.json"))
    }

    @Test func scanNeverOpensKeyFilesAndKeepsLastGoodEntryOnTornWrite() throws {
        let dir = TempDir()
        dir.write("41001.json", Fixture.text("claude/registry/desktop-busy.json"))
        dir.write("41001.abcdef.key", "DO-NOT-READ")
        dir.write("0123.json", "{}")
        let fs = CountingFileSystem()
        var reader = ClaudeRegistryReader()
        let first = reader.scan(dir: dir.path, fs: fs)
        #expect(first.keys.sorted() == ["41001.json"])

        // Torn write: keep the previous good entry and flag it for a re-read.
        dir.write("41001.json", Fixture.text("claude/registry/torn.json"))
        let second = reader.scan(dir: dir.path, fs: fs)
        #expect(second["41001.json"]?.entry.pid == 41001)
        #expect(reader.tornNames == ["41001.json"])
        #expect(!fs.openedPaths.contains { $0.hasSuffix(".key") })
        #expect(!fs.openedPaths.contains { $0.hasSuffix("0123.json") })
    }

    @Test func livenessChecksProcStartToDetectPIDReuse() throws {
        let e = try ClaudeFixtures.entry("desktop-busy.json")
        let start = TimeParsing.procStart("Tue Sep 22 19:03:03 2026")!
        var inspector = FakeProcessInspector(alive: [41001], starts: [41001: start.addingTimeInterval(0.4)])
        #expect(ClaudeLiveness.isAlive(e, inspector: inspector))
        inspector.starts[41001] = start.addingTimeInterval(3600)   // PID reused by another process
        #expect(!ClaudeLiveness.isAlive(e, inspector: inspector))
        inspector.alive = []
        #expect(!ClaudeLiveness.isAlive(e, inspector: inspector))
    }

    @Test func livenessFallsBackToStartedAt() throws {
        var e = try ClaudeFixtures.entry("desktop-busy.json")
        e.procStart = nil
        let started = ClaudeRegistryEntry.date(ms: e.startedAt)!
        let inspector = FakeProcessInspector(alive: [41001], starts: [41001: started.addingTimeInterval(-1.1)])
        #expect(ClaudeLiveness.isAlive(e, inspector: inspector))
        let reused = FakeProcessInspector(alive: [41001], starts: [41001: started.addingTimeInterval(-3600)])
        #expect(!ClaudeLiveness.isAlive(e, inspector: reused))
    }
}

@Suite("Claude transcript reducer")
struct ClaudeTranscriptTests {
    @Test func pendingBashFromSplitMessage() {
        let t = ClaudeFixtures.transcript("running-bash.jsonl")
        #expect(t.sawTurnStart)
        #expect(t.latestPending?.summary.name == "Bash")
        #expect(t.latestPending?.summary.working == "Running Bash: Run the test suite")
        #expect(t.latestPending?.summary.detail == "npm test -- --watch=false")
        #expect(t.turnEndedAt == nil)
        #expect(t.bestTitle == "Demo title")
        // Metadata trailer records carry no timestamp and must not move lastRecordAt.
        #expect(t.lastRecordAt == ClaudeFixtures.date("2026-09-22T19:10:02.200Z"))
    }

    @Test func cleanTurnEnd() {
        let t = ClaudeFixtures.transcript("turn-ended.jsonl")
        #expect(t.pending.isEmpty)
        #expect(t.turnEndedAt == ClaudeFixtures.date("2026-09-22T19:10:05.000Z"))
    }

    @Test func toolResultBeforeToolUseInFileOrder() {
        let t = ClaudeFixtures.transcript("split-message-out-of-order.jsonl")
        #expect(t.pending.keys.sorted() == ["toolu_C"])
        #expect(t.latestPending?.summary.working == "Editing App.swift")
    }

    @Test func questionHeader() {
        let t = ClaudeFixtures.transcript("ask-user-question.jsonl")
        #expect(t.latestPending?.summary.questionHeader == "Database")
    }

    @Test func terminalErrorsAndRetries() {
        let server = ClaudeFixtures.transcript("terminal-server-error.jsonl")
        #expect(server.currentTurnError?.category == "server_error")
        #expect(server.currentTurnError?.text?.hasPrefix("API Error") == true)
        let retry = ClaudeFixtures.transcript("api-retry.jsonl")
        #expect(retry.lastRetry?.attempt == 3)
        #expect(retry.lastRetry?.message == "Connection dropped (ECONNRESET)")
    }

    @Test func newPromptClearsError() {
        var t = ClaudeFixtures.transcript("terminal-server-error.jsonl")
        t.apply(.userPrompt(at: ClaudeFixtures.date("2026-09-22T19:20:00Z"), isInterrupt: false))
        #expect(t.currentTurnError == nil)
    }

    @Test func interruptClearsPending() {
        let t = ClaudeFixtures.transcript("interrupted.jsonl")
        #expect(t.pending.isEmpty)
        #expect(t.interruptedAt != nil)
    }

    @Test func sidechainRecordsIgnored() {
        let t = ClaudeFixtures.transcript("sidechain-lines.jsonl")
        #expect(t.pending.isEmpty)
        #expect(t.turnEndedAt != nil)
    }

    @Test func oversizeToolResultResolvedBySniffing() {
        var t = ClaudeFixtures.transcript("running-bash.jsonl")
        let prefix = Data(#"{"parentUuid":"p","isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_A","type":"tool_result","content":"xxxxx"#.utf8)
        t.apply(ClaudeRecordDecoder.decode(.oversize(prefix: prefix, totalBytes: 9_000_000)))
        #expect(t.pending.isEmpty)
    }
}

@Suite("Claude state derivation")
struct ClaudeDerivationTests {
    let now = ClaudeFixtures.date("2026-09-22T19:30:00Z")

    @Test func busyWithPendingTool() throws {
        let e = try ClaudeFixtures.entry("desktop-busy.json")
        let d = ClaudeStateDeriver.derive(e, transcript: ClaudeFixtures.transcript("running-bash.jsonl"), registryModified: nil, now: now)
        #expect(d.state == .working)
        #expect(d.activity == "Running Bash: Run the test suite")
        #expect(d.since == ClaudeRegistryEntry.date(ms: e.statusUpdatedAt))
    }

    @Test func waitingForPermissionUsesPendingTool() throws {
        let e = try ClaudeFixtures.entry("desktop-waiting-permission.json")
        let d = ClaudeStateDeriver.derive(e, transcript: ClaudeFixtures.transcript("running-bash.jsonl"), registryModified: nil, now: now)
        #expect(d.state == .needsAttention(.approval(tool: "Bash", detail: "npm test -- --watch=false")))
        #expect(d.activity == "Needs approval · Bash: npm test -- --watch=false")
    }

    @Test func waitingForInputWithQuestion() throws {
        let e = try ClaudeFixtures.entry("desktop-waiting-input.json")
        let d = ClaudeStateDeriver.derive(e, transcript: ClaudeFixtures.transcript("ask-user-question.jsonl"), registryModified: nil, now: now)
        #expect(d.state == .needsAttention(.question("Database")))
        #expect(d.activity == "Question: Database")
    }

    @Test func terminalApproveStringWithoutTranscript() throws {
        let e = try ClaudeFixtures.entry("tui-2.1.121-approve-bash.json")
        let d = ClaudeStateDeriver.derive(e, transcript: nil, registryModified: nil, now: now)
        #expect(d.state == .needsAttention(.approval(tool: "Bash", detail: "npm test")))
        #expect(e.origin == .terminal)
        // No statusUpdatedAt on 2.1.121: falls back to updatedAt.
        #expect(d.since == ClaudeRegistryEntry.date(ms: 1_788_336_001_000))
    }

    @Test func shellMeansTurnDoneWithBackgroundShell() throws {
        let d = ClaudeStateDeriver.derive(try ClaudeFixtures.entry("shell-status.json"), transcript: nil, registryModified: nil, now: now)
        #expect(d.state == .waitingForUser)
        #expect(d.activity == "Background shell running")
    }

    @Test func busyButTurnEndedLongAgoIsBackgroundTask() throws {
        var e = try ClaudeFixtures.entry("desktop-busy.json")
        e.statusUpdatedAt = ClaudeFixtures.date("2026-09-22T19:10:00Z").timeIntervalSince1970 * 1000
        let t = ClaudeFixtures.transcript("background-bash-2.1.121.jsonl")
        let d = ClaudeStateDeriver.derive(e, transcript: t, registryModified: nil, now: now)
        #expect(d.state == .waitingForUser)
        #expect(d.activity == "Background task running")
        #expect(d.since == ClaudeFixtures.date("2026-09-22T19:10:03Z"))
        // Within the grace period it is still "working".
        let early = ClaudeStateDeriver.derive(e, transcript: t, registryModified: nil,
                                              now: ClaudeFixtures.date("2026-09-22T19:10:30Z"))
        #expect(early.state == .working)
    }

    @Test func retryingShowsAttempt() throws {
        let e = try ClaudeFixtures.entry("desktop-busy.json")
        let t = ClaudeFixtures.transcript("api-retry.jsonl")
        let d = ClaudeStateDeriver.derive(e, transcript: t, registryModified: nil, now: ClaudeFixtures.date("2026-09-22T19:10:05Z"))
        #expect(d.state == .working)
        #expect(d.activity == "Retrying (3/10): Connection dropped (ECONNRESET)")
    }

    @Test func idleWithTerminalErrors() throws {
        var e = try ClaudeFixtures.entry("desktop-busy.json")
        e.status = .idle
        let server = ClaudeStateDeriver.derive(e, transcript: ClaudeFixtures.transcript("terminal-server-error.jsonl"), registryModified: nil, now: now)
        guard case .needsAttention(.error) = server.state else {
            Issue.record("expected error, got \(server.state)")
            return
        }
        let limit = ClaudeStateDeriver.derive(e, transcript: ClaudeFixtures.transcript("terminal-rate-limit.jsonl"), registryModified: nil, now: now)
        #expect(limit.state == .needsAttention(.usageLimit))
        #expect(limit.activity == "Usage limit reached")
    }

    @Test func freshlyResumedIdleSessionIsAgedFromLastActivity() throws {
        var e = try ClaudeFixtures.entry("desktop-busy.json")
        e.status = .idle
        e.statusUpdatedAt = e.startedAt.map { $0 + 700 }
        let t = ClaudeFixtures.transcript("turn-ended.jsonl")
        let d = ClaudeStateDeriver.derive(e, transcript: t, registryModified: nil, now: now)
        #expect(d.state == .waitingForUser)
        #expect(d.since == t.turnEndedAt)
    }

    @Test func backgroundJobBlocked() throws {
        let d = ClaudeStateDeriver.derive(try ClaudeFixtures.entry("bg-blocked-needs.json"), transcript: nil, registryModified: nil, now: now)
        #expect(d.state == .needsAttention(.input("Needs a GitHub token")))
    }

    @Test func unknownStatusFallsBackToTranscript() throws {
        let e = try ClaudeFixtures.entry("future-fields.json")
        let d = ClaudeStateDeriver.derive(e, transcript: ClaudeFixtures.transcript("turn-ended.jsonl"), registryModified: nil, now: now)
        #expect(d.state == .waitingForUser)
        #expect(d.confidence == .inferred)
    }

    @Test func titlePrecedence() throws {
        let e = try ClaudeFixtures.entry("desktop-busy.json")
        #expect(ClaudeStateDeriver.title(e, transcript: nil) == "Demo")
        var unnamed = e
        unnamed.name = nil
        #expect(ClaudeStateDeriver.title(unnamed, transcript: ClaudeFixtures.transcript("running-bash.jsonl")) == "Demo title")
        #expect(ClaudeStateDeriver.title(unnamed, transcript: nil) == "demo")
    }
}

@Suite("AttentionMapper")
struct AttentionMapperTests {
    static let bash = PendingTool(id: "t", summary: ClaudeActivity.summarize(name: "Bash", input: .object(["command": .string("rm -rf build")])), at: nil)

    @Test func mapsKnownStrings() {
        #expect(AttentionMapper.map("permission prompt", pending: Self.bash) == .approval(tool: "Bash", detail: "rm -rf build"))
        #expect(AttentionMapper.map("approve plan", pending: nil) == .approval(tool: "Plan", detail: nil))
        #expect(AttentionMapper.map("approve Edit: src/app.ts", pending: nil) == .approval(tool: "Edit", detail: "src/app.ts"))
        #expect(AttentionMapper.map("approve WebFetch", pending: nil) == .approval(tool: "WebFetch", detail: nil))
        #expect(AttentionMapper.map("dialog open", pending: nil) == .input("Dialog open"))
        #expect(AttentionMapper.map("sandbox request", pending: nil) == .approval(tool: "Sandbox", detail: "network access"))
        #expect(AttentionMapper.map("worker request", pending: nil) == .approval(tool: "Worker", detail: nil))
        #expect(AttentionMapper.map("input needed", pending: nil) == .input("Input needed"))
        #expect(AttentionMapper.map("brand new reason", pending: nil) == .input("brand new reason"))
        #expect(AttentionMapper.map(nil, pending: Self.bash) == .approval(tool: "Bash", detail: "rm -rf build"))
    }

    @Test func mcpToolNames() {
        let mcp = PendingTool(id: "m", summary: ClaudeActivity.summarize(name: "mcp__github__create_issue", input: nil), at: nil)
        #expect(AttentionMapper.map("permission prompt", pending: mcp) == .approval(tool: "github · create_issue", detail: "create_issue"))
        #expect(mcp.summary.working == "MCP github · create_issue")
    }
}

@Suite("Claude activity text")
struct ClaudeActivityTests {
    @Test(arguments: [
        ("Read", JSONValue.object(["file_path": .string("/a/b/Main.swift")]), "Reading Main.swift"),
        ("Write", .object(["file_path": .string("/a/notes.md")]), "Writing notes.md"),
        ("Grep", .object(["pattern": .string("TODO")]), "Searching 'TODO'"),
        ("Glob", .object(["pattern": .string("**/*.swift")]), "Finding files '**/*.swift'"),
        ("WebFetch", .object(["url": .string("https://docs.swift.org/x")]), "Fetching docs.swift.org"),
        ("WebSearch", .object(["query": .string("swift actors")]), "Searching the web: swift actors"),
        ("Task", .object(["description": .string("Explore data layer")]), "Running agent: Explore data layer"),
        ("TodoWrite", .object([:]), "Updating todos"),
        ("ExitPlanMode", .object([:]), "Plan ready for review"),
        ("Bash", .object(["command": .string("export TOKEN=abcdef1234567890 && deploy")]), "Running Bash: export TOKEN=‹redacted› && deploy"),
        ("SomethingNew", .null, "Running SomethingNew"),
    ])
    func summaries(name: String, input: JSONValue, expected: String) {
        #expect(ClaudeActivity.summarize(name: name, input: input).working == expected)
    }
}
