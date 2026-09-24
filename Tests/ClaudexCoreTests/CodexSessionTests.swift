import Foundation
import Testing
@testable import ClaudexCore

enum CodexFixtures {
    static func records(_ name: String) -> [CodexRecord] {
        var framer = LineFramer(maxLineBytes: CodexRecordDecoder.maxLineBytes)
        return framer.push(Fixture.data("codex/rollouts/\(name)")).map(CodexRecordDecoder.decode)
    }

    static func state(_ name: String) -> CodexThreadState {
        var s = CodexThreadState()
        for r in records(name) { s.apply(r) }
        return s
    }

    static let context = CodexThreadContext(ownerPID: 1, ownerStart: TimeParsing.epoch(1_789_790_000),
                                            lockBirth: nil, loaded: true, confidence: .reported)
}

@Suite("Codex rollout decoding")
struct CodexDecodingTests {
    @Test func decodesTurnBoundariesAndMeta() {
        let r = CodexFixtures.records("complete.jsonl")
        #expect(r.first == .sessionMeta(CodexSessionMeta(
            id: "00000000-0000-4000-8000-00000000000c", cwd: "/Users/test/Projects/report", originator: "Codex Desktop",
            source: "vscode", cliVersion: "0.155.0"), at: TimeParsing.iso8601("2026-09-19T06:00:00.000Z")))
        #expect(r.contains(.taskStarted(turnID: "t1", at: TimeParsing.epoch(1_789_797_660))))
        #expect(r.last == .taskComplete(turnID: "t1", at: TimeParsing.epoch(1_789_797_720), error: nil))
    }

    @Test func execCommandSummary() {
        let calls = CodexFixtures.records("active-exec.jsonl").compactMap { r -> ToolSummary? in
            if case let .toolCall(_, s, _) = r { return s }
            return nil
        }
        #expect(calls.first?.working == "Running: npm test")
    }

    @Test func patchSummary() {
        let s = CodexFixtures.state("patch-exec.jsonl")
        #expect(s.activity == "Editing agent.py")
    }

    @Test func errorInfoAsStringOrObject() {
        guard case let .taskComplete(_, _, err?) = CodexFixtures.records("error-other.jsonl").last else {
            Issue.record("expected error")
            return
        }
        #expect(err.info == "other")
        #expect(!err.isUsageLimit)
        guard case let .taskComplete(_, _, limit?) = CodexFixtures.records("error-usage-limit.jsonl").last else {
            Issue.record("expected error")
            return
        }
        #expect(limit.isUsageLimit)
    }

    @Test func rateLimitVariants() {
        let limits = CodexFixtures.records("token-count-variants.jsonl").compactMap { r -> CodexRateLimits? in
            if case let .tokenCount(l, _) = r { return l }
            return nil
        }
        #expect(limits.count == 4)
        #expect(limits[0].windows.map(\.minutes) == [300, 10_080])
        #expect(limits[0].windows.first?.usedPercent == 12.5)
        #expect(limits[1].limitID == "codex_bengalfox")
        #expect(limits[2].windows.isEmpty)   // null windows mean "no data", not zero
        #expect(limits[3].windows.count == 1)
        #expect(limits[3].planType == "prolite")
        #expect(limits[3].windows.first?.resetsAt == TimeParsing.epoch(1_789_806_171))
    }

    @Test func bulkyRecordsAreNotFullyDecoded() {
        let huge = #"{"timestamp":"2026-09-19T06:00:00Z","ordinal":9,"type":"response_item","payload":{"type":"function_call_output","call_id":"call_9","output":""#
        #expect(CodexRecordDecoder.decode(.oversize(prefix: Data(huge.utf8), totalBytes: 5_000_000))
            == .toolOutput(callID: "call_9", at: TimeParsing.iso8601("2026-09-19T06:00:00Z")))
        let compacted = #"{"timestamp":"2026-09-19T06:00:00Z","ordinal":9,"type":"compacted","payload":{"message":""#
        #expect(CodexRecordDecoder.decode(.oversize(prefix: Data(compacted.utf8), totalBytes: 9_000_000))
            == .other(at: TimeParsing.iso8601("2026-09-19T06:00:00Z")))
    }
}

@Suite("Codex reducer + derivation")
struct CodexDerivationTests {
    let now = TimeParsing.iso8601("2026-09-19T06:10:00Z")!

    @Test func activeTurnIsGreenWithActivity() {
        let s = CodexFixtures.state("active-exec.jsonl")
        #expect(s.isActive)
        let d = CodexStateDeriver.derive(s, context: CodexFixtures.context, fallbackSince: now, now: now)
        #expect(d.state == .working)
        #expect(d.activity == "Running: npm test")
        #expect(d.since == TimeParsing.epoch(1_789_797_660))
    }

    @Test func completedTurnIsYellow() {
        let d = CodexStateDeriver.derive(CodexFixtures.state("complete.jsonl"), context: CodexFixtures.context,
                                         fallbackSince: now, now: now)
        #expect(d.state == .waitingForUser)
        #expect(d.since == TimeParsing.epoch(1_789_797_720))
    }

    @Test func pendingQuestionIsRed() {
        let d = CodexStateDeriver.derive(CodexFixtures.state("request-user-input-pending.jsonl"),
                                         context: CodexFixtures.context, fallbackSince: now, now: now)
        #expect(d.state == .needsAttention(.question("Deploy target")))
        #expect(d.activity == "Question: Deploy target")
    }

    @Test func answeredQuestionWithDuplicateOutputGoesBackToWorking() {
        let s = CodexFixtures.state("request-user-input-answered-dup.jsonl")
        #expect(s.pendingQuestion == nil)
        let d = CodexStateDeriver.derive(s, context: CodexFixtures.context, fallbackSince: now, now: now)
        #expect(d.state == .working)
        #expect(d.activity == "Running: make build")
    }

    @Test func errorsAreRed() {
        let other = CodexStateDeriver.derive(CodexFixtures.state("error-other.jsonl"), context: CodexFixtures.context,
                                             fallbackSince: now, now: now)
        #expect(other.state == .needsAttention(.error("stream disconnected before completion: error sending request")))
        let limit = CodexStateDeriver.derive(CodexFixtures.state("error-usage-limit.jsonl"), context: CodexFixtures.context,
                                             fallbackSince: now, now: now)
        #expect(limit.state == .needsAttention(.usageLimit))
    }

    @Test func abortedIsYellowInterrupted() {
        let d = CodexStateDeriver.derive(CodexFixtures.state("aborted.jsonl"), context: CodexFixtures.context,
                                         fallbackSince: now, now: now)
        #expect(d.state == .waitingForUser)
        #expect(d.activity == "Interrupted")
    }

    @Test func orphanTurnSupersededByNewStart() {
        let s = CodexFixtures.state("orphan-then-new-start.jsonl")
        #expect(s.pending.isEmpty)
        #expect(s.turn == .active(id: "t2", startedAt: TimeParsing.epoch(1_789_797_900)))
    }

    @Test func ownerRestartedAfterTurnStartMeansInterrupted() {
        let s = CodexFixtures.state("active-exec.jsonl")
        let restarted = CodexThreadContext(ownerPID: 1, ownerStart: now, lockBirth: nil, loaded: true, confidence: .reported)
        let d = CodexStateDeriver.derive(s, context: restarted, fallbackSince: now, now: now)
        #expect(d.state == .waitingForUser)
        #expect(d.activity == "Interrupted (app restarted)")
    }

    @Test func quietAndStaleTurns() {
        let s = CodexFixtures.state("active-exec.jsonl")
        let quiet = CodexStateDeriver.derive(s, context: CodexFixtures.context, fallbackSince: now,
                                             now: TimeParsing.iso8601("2026-09-19T06:30:00Z")!)
        #expect(quiet.state == .working)
        #expect(quiet.activity.hasSuffix("· quiet 28m"))
        let stale = CodexStateDeriver.derive(s, context: CodexFixtures.context, fallbackSince: now,
                                             now: TimeParsing.iso8601("2026-09-19T09:30:00Z")!)
        #expect(stale.state == .waitingForUser)
        #expect(stale.confidence == .inferred)
    }

    @Test func bootstrapFromTailFindsTheLastTurn() throws {
        let dir = TempDir()
        let path = dir.write("rollout-2026-09-19T11-07-54-00000000-0000-4000-8000-00000000000c.jsonl",
                             Fixture.text("codex/rollouts/orphan-then-new-start.jsonl"))
        let (state, result) = try #require(CodexRolloutScanner.bootstrap(path: path, fs: LiveFileSystem()))
        #expect(result.reachedStop)
        #expect(state.turn == .active(id: "t2", startedAt: TimeParsing.epoch(1_789_797_900)))
    }

    @Test func exhaustedBudgetPreseedsAnActiveTurn() throws {
        let dir = TempDir()
        var text = Fixture.text("codex/rollouts/active-exec.jsonl")
        for i in 0..<700 {   // > one 256 KiB chunk, so the 8 KiB budget is exhausted
            text += #"{"timestamp":"2026-09-19T06:02:00Z","ordinal":\#(100 + i),"type":"response_item","payload":{"type":"reasoning","summary":[],"encrypted_content":"\#(String(repeating: "x", count: 500))"}}"# + "\n"
        }
        let path = dir.write("r.jsonl", text)
        let (state, result) = try #require(CodexRolloutScanner.bootstrap(path: path, fs: LiveFileSystem(), budget: 8 * 1024))
        #expect(result.exhausted)
        #expect(state.isActive)
    }
}

@Suite("Codex loaded threads")
struct CodexLoadedTests {
    @Test func executableNames() {
        #expect(LoadedThreadDetector.isCodexExecutable("/Applications/ChatGPT.app/Contents/Resources/codex"))
        #expect(LoadedThreadDetector.isCodexExecutable("/opt/homebrew/Caskroom/codex/0.125.0/codex-aarch64-apple-darwin"))
        #expect(!LoadedThreadDetector.isCodexExecutable("/Applications/ChatGPT.app/Contents/Resources/codex-code-mode-host"))
        #expect(!LoadedThreadDetector.isCodexExecutable("/x/Codex (Renderer).app/Contents/MacOS/Codex (Renderer)"))
    }

    @Test func threadIDsFromPaths() {
        #expect(CodexPaths.threadID(fromRollout: "/h/.codex/sessions/2026/09/19/rollout-2026-09-19T11-07-54-0190aaaa-bbbb-7ccc-8ddd-eeeeffff0000.jsonl")
            == "0190aaaa-bbbb-7ccc-8ddd-eeeeffff0000")
        #expect(CodexPaths.threadID(fromLock: "/h/.codex/thread-writer-locks/0190aaaa-bbbb-7ccc-8ddd-eeeeffff0000.lock")
            == "0190aaaa-bbbb-7ccc-8ddd-eeeeffff0000")
        #expect(CodexPaths.threadID(fromLock: "/h/.codex/thread-writer-locks/.coordination.lock") == nil)
    }

    @Test func detectsThreadsHeldOpenByCodexProcesses() {
        let dir = TempDir()
        let paths = CodexPaths(home: dir.path)
        try? FileManager.default.createDirectory(atPath: paths.sessionsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: paths.locksDir, withIntermediateDirectories: true)
        let id = "00000000-0000-4000-8000-00000000000c"
        let rollout = Paths.join(paths.sessionsDir, "rollout-2026-09-19T11-07-54-\(id).jsonl")
        let lock = Paths.join(paths.locksDir, "\(id).lock")
        let inspector = FakeProcessInspector(
            alive: [100, 200, 300],
            paths: [100: "/Applications/ChatGPT.app/Contents/Resources/codex",
                    200: "/Applications/ChatGPT.app/Contents/Resources/codex-code-mode-host",
                    300: "/usr/bin/vim"],
            openFiles: [100: [rollout, lock, "/dev/null"], 200: [rollout], 300: [rollout]]
        )
        var detector = LoadedThreadDetector()
        let r = detector.detect(paths: paths, fs: LiveFileSystem(), inspector: inspector, now: Date(), forceEnumerate: true)
        #expect(Array(r.threads.keys) == [id])
        #expect(r.threads[id]?.ownerPID == 100)
        #expect(r.threads[id]?.lockPath == lock)
        #expect(r.ownerPIDs == [100])
        #expect(!r.fdListingFailed)
    }

    @Test func threadIndexReadsNamesWithoutSideFiles() throws {
        let dir = TempDir()
        let paths = CodexPaths(home: dir.path)
        let db = Paths.join(dir.path, "state_5.sqlite")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [db, """
            CREATE TABLE threads(id TEXT PRIMARY KEY, rollout_path TEXT, cwd TEXT, title TEXT, name TEXT, archived INTEGER, agent_role TEXT, updated_at_ms INTEGER);
            INSERT INTO threads VALUES('a','/r/a.jsonl','/p/one','first msg','Named thread',0,NULL,1789802047286);
            INSERT INTO threads VALUES('b','/r/b.jsonl','/p/two','Only title','',1,NULL,1789802047286);
            INSERT INTO threads VALUES('c','/r/c.jsonl','/p/three',NULL,NULL,0,'worker',NULL);
            """]
        try p.run()
        p.waitUntilExit()
        dir.write("session_index.jsonl", #"{"id":"c","thread_name":"From index","updated_at":"2026-09-19T06:09:04Z"}"# + "\n")
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        let info = CodexThreadIndex.load(ids: ["a", "b", "c"], paths: paths, fs: LiveFileSystem())
        #expect(info["a"]?.title == "Named thread")
        #expect(info["a"]?.updatedAt == TimeParsing.epoch(1_789_802_047_286))
        #expect(info["b"]?.title == "Only title")
        #expect(info["b"]?.archived == true)
        #expect(info["c"]?.isSubagent == true)
        #expect(info["c"]?.title == "From index")
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)) == before)
    }

    @Test func originFromAncestryAndMeta() {
        #expect(CodexStateDeriver.origin(meta: nil, ownerAppPath: "/Applications/ChatGPT.app") == .desktop)
        #expect(CodexStateDeriver.origin(meta: CodexSessionMeta(originator: "codex_cli_rs", source: "cli"), ownerAppPath: nil) == .terminal)
        #expect(CodexStateDeriver.origin(meta: CodexSessionMeta(originator: "codex_exec", source: "exec"), ownerAppPath: nil) == .background)
    }
}

@Suite("Codex activity text")
struct CodexActivityTests {
    @Test(arguments: [
        ("exec_command", #"{"cmd":"cargo test --all","workdir":"/x"}"#, "Running: cargo test --all"),
        ("shell", #"{"command":["bash","-lc","ls -la"]}"#, "Running: ls -la"),
        ("write_stdin", #"{"session_id":1,"chars":""}"#, "Waiting on command output"),
        ("update_plan", #"{"plan":[]}"#, "Updating plan"),
        ("view_image", #"{"path":"/tmp/a.png"}"#, "Viewing an image"),
        ("request_user_input", #"{"questions":[{"header":"Pick one","question":"?"}]}"#, "Asking a question"),
        ("mcp__linear__create_issue", "{}", "MCP linear · create_issue"),
    ])
    func summaries(name: String, arguments: String, expected: String) {
        #expect(CodexActivity.summarize(name: name, namespace: nil, arguments: arguments, input: nil).working == expected)
    }

    @Test func codeModeExecWithoutCommand() {
        #expect(CodexActivity.summarize(name: "exec", namespace: nil, arguments: nil, input: "const x = 1 + 1;").working == "Running code")
    }
}
