import Foundation
import Testing
@testable import ClaudexCore

private func session(_ id: String, _ p: Provider = .claude, _ state: SessionState, since: Date, project: String = "demo") -> AgentSession {
    AgentSession(id: id, provider: p, state: state, stateSince: since, activity: "x", title: project, project: project,
                 cwd: nil, origin: .desktop, pid: nil, appBundleID: nil, lastEventAt: nil, confidence: .reported)
}

@Suite("Lamps & aggregation")
struct LampTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func multipleLampsLightTogether() {
        let sessions = [
            session("a", .claude, .working, since: now),
            session("b", .claude, .needsAttention(.approval(tool: "Bash", detail: nil)), since: now),
            session("c", .codex, .waitingForUser, since: now.addingTimeInterval(-60)),
            session("d", .codex, .waitingForUser, since: now.addingTimeInterval(-7200)),
        ]
        let lamps = Aggregator.lamps(sessions, now: now)
        #expect(LampTriple(lamps[.claude]!) == LampTriple(red: .blinking, yellow: .off, green: .breathing))
        #expect(LampTriple(lamps[.codex]!) == LampTriple(red: .off, yellow: .steady, green: .off))
        #expect(lamps[.codex]!.waitingParked == 1)
    }

    @Test func freshWindowBoundaryIsParked() {
        let s = [session("a", .claude, .waitingForUser, since: now.addingTimeInterval(-1800))]
        #expect(Aggregator.lamps(s, now: now)[.claude]!.yellow == .parked)
        let fresh = [session("a", .claude, .waitingForUser, since: now.addingTimeInterval(-1799))]
        #expect(Aggregator.lamps(fresh, now: now)[.claude]!.yellow == .fresh)
    }

    @Test func noSessionsMeansAllOff() {
        #expect(LampTriple(Aggregator.lamps([], now: now)[.claude]!).isAllOff)
    }

    @Test func driverOrder() {
        let s = [
            session("green-old", .claude, .working, since: now.addingTimeInterval(-600)),
            session("parked", .claude, .waitingForUser, since: now.addingTimeInterval(-9000)),
            session("err", .codex, .needsAttention(.error("x")), since: now.addingTimeInterval(-10)),
            session("fresh", .codex, .waitingForUser, since: now.addingTimeInterval(-100)),
            session("approval-late", .claude, .needsAttention(.approval(tool: nil, detail: nil)), since: now.addingTimeInterval(-5)),
            session("approval-early", .claude, .needsAttention(.approval(tool: nil, detail: nil)), since: now.addingTimeInterval(-50)),
            session("green-new", .codex, .working, since: now.addingTimeInterval(-20)),
        ]
        #expect(Aggregator.ordered(s, now: now).map(\.id)
            == ["approval-early", "approval-late", "err", "fresh", "green-new", "green-old", "parked"])
    }

    @Test func smootherHoldsBriefYellowFlaps() {
        var smoother = StateSmoother(holdInterval: 1.5)
        let working = session("a", .claude, .working, since: now)
        _ = smoother.apply([working], now: now)
        let yellow = session("a", .claude, .waitingForUser, since: now.addingTimeInterval(1))
        let held = smoother.apply([yellow], now: now.addingTimeInterval(1))
        #expect(held.sessions.first?.state == .working)
        #expect(held.recheckAt == now.addingTimeInterval(2.5))
        // Back to working within the grace period: yellow never published.
        #expect(smoother.apply([working], now: now.addingTimeInterval(2)).sessions.first?.state == .working)
        // A yellow that persists is published after the grace period.
        _ = smoother.apply([yellow], now: now.addingTimeInterval(3))
        #expect(smoother.apply([yellow], now: now.addingTimeInterval(4.6)).sessions.first?.state == .waitingForUser)
        // Red publishes immediately.
        let red = session("a", .claude, .needsAttention(.input(nil)), since: now)
        #expect(smoother.apply([red], now: now.addingTimeInterval(5)).sessions.first?.state == red.state)
    }
}

@Suite("Peek detection")
struct PeekDetectorTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func firstSnapshotNeverPeeks() {
        var d = PeekEventDetector()
        #expect(d.diff(sessions: [session("a", .claude, .needsAttention(.question("Q")), since: t0)], now: t0).isEmpty)
    }

    @Test func attentionAndFinishedEvents() {
        var d = PeekEventDetector()
        _ = d.diff(sessions: [session("a", .claude, .working, since: t0)], now: t0)
        let red = d.diff(sessions: [session("a", .claude, .needsAttention(.approval(tool: "Bash", detail: nil)), since: t0)],
                         now: t0.addingTimeInterval(5))
        #expect(red.map(\.kind) == [.attention])
        #expect(red.first?.detail == "needs approval — Bash")
        // Same red state again: no duplicate.
        #expect(d.diff(sessions: [session("a", .claude, .needsAttention(.approval(tool: "Bash", detail: nil)), since: t0)],
                       now: t0.addingTimeInterval(6)).isEmpty)
        // A long working turn that finishes peeks "Done"; a short one doesn't.
        _ = d.diff(sessions: [session("a", .claude, .working, since: t0.addingTimeInterval(10))], now: t0.addingTimeInterval(10))
        let done = d.diff(sessions: [session("a", .claude, .waitingForUser, since: t0.addingTimeInterval(40))],
                          now: t0.addingTimeInterval(40))
        #expect(done.map(\.kind) == [.finished])
        _ = d.diff(sessions: [session("a", .claude, .working, since: t0.addingTimeInterval(50))], now: t0.addingTimeInterval(50))
        #expect(d.diff(sessions: [session("a", .claude, .waitingForUser, since: t0.addingTimeInterval(55))],
                       now: t0.addingTimeInterval(55)).isEmpty)
    }

    @Test func usageThresholdCrossings() {
        var d = PeekEventDetector()
        func snapshot(_ v: Double) -> UsageSnapshot {
            var u = UsageSnapshot.empty
            u.claude.windows = [UsageWindow(id: "claude.five_hour", kind: .session5h, label: "5h", usedPercent: v,
                                            resetsAt: t0.addingTimeInterval(3600), windowDuration: 18_000,
                                            source: .claudeOAuthAPI, fetchedAt: t0)]
            return u
        }
        #expect(d.diff(usage: snapshot(85), now: t0).isEmpty)          // first reading: no event
        #expect(d.diff(usage: snapshot(90), now: t0).isEmpty)          // already above 80
        let limit = d.diff(usage: snapshot(100), now: t0)
        #expect(limit.map(\.title) == ["Claude 5h at 100%"])
        #expect(limit.first?.lamp == .red)
        _ = d.diff(usage: snapshot(10), now: t0)                        // window reset
        #expect(d.diff(usage: snapshot(81), now: t0).map(\.title) == ["Claude 5h at 80%"])
    }
}

@Suite("Peek queue")
struct PeekQueueTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func event(_ key: String, _ kind: PeekEvent.Kind, at: Date) -> PeekEvent {
        PeekEvent(key: key, kind: kind, provider: .claude, lamp: .red, title: key, detail: "", sessionID: nil, createdAt: at)
    }

    @Test func showsThenExpiresThenShowsNext() {
        var q = PeekQueue()
        let a = event("a", .finished, at: t0)
        #expect(q.enqueue(a, now: t0) == .show(a))
        let b = event("b", .finished, at: t0)
        #expect(q.enqueue(b, now: t0.addingTimeInterval(0.5)) == .none)
        #expect(q.deadline == t0.addingTimeInterval(3))
        #expect(q.expire(now: t0.addingTimeInterval(3)) == .show(b))
        #expect(q.expire(now: t0.addingTimeInterval(6)) == .hide)
    }

    @Test func higherPriorityPreemptsAfterMinimumShowTime() {
        var q = PeekQueue()
        let done = event("done", .finished, at: t0)
        _ = q.enqueue(done, now: t0)
        let attention = event("attn", .attention, at: t0)
        #expect(q.enqueue(attention, now: t0.addingTimeInterval(0.5)) == .none)   // too early to preempt
        var q2 = PeekQueue()
        _ = q2.enqueue(done, now: t0)
        #expect(q2.enqueue(attention, now: t0.addingTimeInterval(2)) == .show(attention))
        #expect(q2.queued.isEmpty)   // a preempted "finished" peek is dropped
    }

    @Test func sameKeyUpdatesInPlaceAndExtends() {
        var q = PeekQueue()
        var a = event("a", .attention, at: t0)
        _ = q.enqueue(a, now: t0)
        a.title = "updated"
        #expect(q.enqueue(a, now: t0.addingTimeInterval(4.5)) == .show(a))
        #expect(q.deadline == t0.addingTimeInterval(6.5))
    }

    @Test func holdPausesAndReleaseResumesWithMinimum() {
        var q = PeekQueue()
        _ = q.enqueue(event("a", .finished, at: t0), now: t0)
        q.hold(now: t0.addingTimeInterval(2.9))
        #expect(q.deadline == nil)
        #expect(q.expire(now: t0.addingTimeInterval(10)) == .none)
        q.release(now: t0.addingTimeInterval(10))
        #expect(q.deadline == t0.addingTimeInterval(11.5))
    }

    @Test func staleQueuedEventsAreDropped() {
        var q = PeekQueue()
        _ = q.enqueue(event("a", .attention, at: t0), now: t0)
        _ = q.enqueue(event("b", .finished, at: t0), now: t0)
        #expect(q.expire(now: t0.addingTimeInterval(40)) == .hide)
    }
}

@Suite("Formatters")
struct FormatterTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func countdownsAndElapsed() {
        #expect(Formatters.countdown(2 * 3600 + 13 * 60 + 5) == "2h 13m")
        #expect(Formatters.countdown(86_400 + 16 * 3600) == "1d 16h")
        #expect(Formatters.countdown(30) == "<1m")
        #expect(Formatters.elapsed(since: now.addingTimeInterval(-2), now: now) == "now")
        #expect(Formatters.elapsed(since: now.addingTimeInterval(-750), now: now) == "12m")
    }

    @Test func resetTexts() {
        var w = UsageWindow(id: "x", kind: .session5h, label: "5h", usedPercent: 40, resetsAt: now.addingTimeInterval(3600),
                            windowDuration: nil, source: .claudeOAuthAPI, fetchedAt: now)
        #expect(Formatters.reset(w, now: now) == "resets in 1h")
        #expect(Formatters.shortReset(w, now: now) == "↻ 1h")
        w.resetIsEstimate = true
        #expect(Formatters.shortReset(w, now: now) == "≈↻ 1h")
        w.resetsAt = nil
        #expect(Formatters.reset(w, now: now) == nil)
        #expect(UsageLevel(percent: 85) == .high)
        #expect(UsageLevel(percent: 100) == .critical)
    }
}

@Suite("Claude source integration", .tags(.slow))
struct ClaudeSourceIntegrationTests {
    @Test func registryAndTranscriptChangesFlowThrough() async throws {
        let dir = TempDir()
        let paths = ClaudePaths(home: dir.path, desktopSupport: dir.url("desktop"), accountFile: dir.url(".claude.json"))
        try FileManager.default.createDirectory(atPath: paths.sessionsDir, withIntermediateDirectories: true)
        let cwd = "/Users/test/Projects/demo"
        let sid = "00000000-0000-4000-8000-000000000001"
        let transcript = "projects/-Users-test-Projects-demo/\(sid).jsonl"
        dir.write(transcript, #"{"type":"user","message":{"role":"user","content":"hi"},"timestamp":"2026-09-22T19:10:00.000Z","sessionId":"s"}"# + "\n")
        let start = Date()
        let procStart = TimeParsing.procStart("Tue Sep 22 19:03:03 2026")!
        let entry = """
        {"pid":4242,"sessionId":"\(sid)","cwd":"\(cwd)","kind":"interactive","entrypoint":"cli","status":"busy",
         "procStart":"Tue Sep 22 19:03:03 2026","statusUpdatedAt":\(Int(start.timeIntervalSince1970 * 1000))}
        """
        dir.write("sessions/4242.json", entry)
        let inspector = FakeProcessInspector(alive: [4242], starts: [4242: procStart])
        let source = ClaudeSessionSource(paths: paths, inspector: inspector, pollInterval: .seconds(60))
        await source.start()
        var it = source.updates.makeAsyncIterator()
        let first = try #require(await it.next())
        #expect(first.sessions.count == 1)
        #expect(first.sessions.first?.state == .working)
        #expect(first.sessions.first?.activity == "Thinking…")

        // Append a tool call: FSEvents → tail → new activity text.
        dir.append(transcript, #"{"type":"assistant","message":{"id":"m1","role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"make test","description":"Run the tests"}}]},"timestamp":"2026-09-22T19:10:05.000Z"}"# + "\n")
        let second = try #require(await it.next())
        #expect(second.sessions.first?.activity == "Running Bash: Run the tests")

        // Registry says waiting for a permission → red with the pending tool.
        dir.write("sessions/4242.json", entry.replacingOccurrences(of: #""status":"busy""#,
                                                                   with: #""status":"waiting","waitingFor":"permission prompt""#))
        let third = try #require(await it.next())
        #expect(third.sessions.first?.state == .needsAttention(.approval(tool: "Bash", detail: "make test")))

        // Process gone → session disappears.
        try FileManager.default.removeItem(atPath: dir.url("sessions/4242.json"))
        let fourth = try #require(await it.next())
        #expect(fourth.sessions.isEmpty)
        await source.stop()
    }
}
