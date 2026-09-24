import ClaudexCore
import Foundation

/// Scripted sessions and usage for demos, screenshots and visual verification.
nonisolated enum DemoScenarios {
    static let names = ["idle", "single-green", "mixed", "all-lit", "parked", "attention", "limits", "many"]

    static func session(_ id: String, _ p: Provider, _ state: SessionState, _ title: String, _ activity: String,
                        ago: TimeInterval, now: Date, origin: SessionOrigin = .desktop) -> AgentSession {
        AgentSession(id: "\(p.rawValue):demo-\(id)", provider: p, state: state, stateSince: now.addingTimeInterval(-ago),
                     activity: activity, title: title, project: title, cwd: "/Users/demo/Projects/\(title)",
                     origin: origin, pid: nil, appBundleID: origin == .desktop ? p.desktopBundleID : nil,
                     lastEventAt: now, confidence: .reported)
    }

    static func window(_ p: Provider, _ minutes: Double, _ percent: Double, resetIn: TimeInterval?, now: Date,
                       source: UsageSource = .demo) -> UsageWindow {
        UsageWindow(id: "\(p.rawValue).\(Int(minutes))", kind: WindowLabeler.kind(minutes: minutes),
                    label: WindowLabeler.label(minutes: minutes), usedPercent: percent,
                    resetsAt: resetIn.map { now.addingTimeInterval($0) }, windowDuration: minutes * 60,
                    source: source, fetchedAt: now)
    }

    static func usage(claude5h: Double = 24, claudeWeek: Double = 41, codexWeek: Double = 63, now: Date) -> UsageSnapshot {
        UsageSnapshot(
            claude: ProviderUsage(provider: .claude, plan: "Max 20×", windows: [
                window(.claude, 300, claude5h, resetIn: 2 * 3600 + 13 * 60, now: now),
                window(.claude, 10_080, claudeWeek, resetIn: 3 * 86_400 + 4 * 3600, now: now),
            ], limitReached: claude5h >= 100, status: .ok, lastSuccessAt: now),
            codex: ProviderUsage(provider: .codex, plan: "Pro Lite", windows: [
                window(.codex, 10_080, codexWeek, resetIn: 86_400 + 16 * 3600, now: now),
            ], limitReached: codexWeek >= 100, status: .ok, lastSuccessAt: now),
            generatedAt: now)
    }

    static func sessions(_ name: String, now: Date) -> [AgentSession] {
        switch name {
        case "single-green":
            return [session("a", .claude, .working, "claudex-bar", "Running Bash: swift build", ago: 95, now: now)]
        case "mixed":
            return [
                session("a", .claude, .working, "claudex-bar", "Editing IslandView.swift", ago: 312, now: now),
                session("b", .claude, .needsAttention(.approval(tool: "Bash", detail: "rm -rf .build")), "api-server",
                        "Needs approval · Bash: rm -rf .build", ago: 42, now: now, origin: .terminal),
                session("c", .codex, .waitingForUser, "report-agent", "Waiting for you", ago: 380, now: now),
                session("d", .codex, .waitingForUser, "docs-site", "Waiting for you", ago: 3 * 3600, now: now),
            ]
        case "all-lit":
            return [
                session("a", .claude, .working, "claudex-bar", "Running Bash: npm test", ago: 60, now: now),
                session("b", .claude, .waitingForUser, "jev-voice-agent", "Waiting for you", ago: 240, now: now),
                session("c", .claude, .needsAttention(.question("Database")), "api-server", "Question: Database", ago: 30, now: now),
                session("d", .codex, .working, "report-agent", "Running: uv run pytest -q", ago: 120, now: now),
                session("e", .codex, .waitingForUser, "docs-site", "Waiting for you", ago: 600, now: now),
                session("f", .codex, .needsAttention(.error("stream disconnected")), "infra", "Error: stream disconnected",
                        ago: 15, now: now),
            ]
        case "parked":
            return [
                session("a", .claude, .waitingForUser, "jev-voice-agent", "Waiting for you", ago: 50 * 3600, now: now),
                session("b", .codex, .waitingForUser, "report-agent", "Waiting for you", ago: 5 * 3600, now: now),
            ]
        case "attention":
            return [
                session("a", .claude, .needsAttention(.approval(tool: "Edit", detail: "Package.swift")), "claudex-bar",
                        "Needs approval · Edit: Package.swift", ago: 20, now: now),
                session("b", .codex, .needsAttention(.question("Deploy target")), "report-agent",
                        "Question: Deploy target", ago: 65, now: now),
            ]
        case "limits":
            return [session("a", .claude, .needsAttention(.usageLimit), "claudex-bar", "Usage limit reached", ago: 90, now: now)]
        case "many":
            return (0..<10).map { i in
                let p: Provider = i % 2 == 0 ? .claude : .codex
                let state: SessionState = i % 3 == 0 ? .working : (i % 3 == 1 ? .waitingForUser : .needsAttention(.input("Dialog open")))
                return session("m\(i)", p, state, "project-\(i)", i % 3 == 0 ? "Running tests" : "Waiting for you",
                               ago: Double(60 * (i + 1)), now: now)
            }
        default:
            return []
        }
    }

    static func usage(for name: String, now: Date) -> UsageSnapshot {
        switch name {
        case "limits": return usage(claude5h: 100, claudeWeek: 86, codexWeek: 97, now: now)
        case "all-lit": return usage(claude5h: 64, claudeWeek: 81, codexWeek: 44, now: now)
        default: return usage(now: now)
        }
    }
}

/// A `StatusFeed` that replays a scripted timeline (or freezes one scenario).
actor DemoDriver: StatusFeed {
    nonisolated let sessionSnapshots: AsyncStream<SessionSnapshot>
    nonisolated let usageSnapshots: AsyncStream<UsageSnapshot>
    private nonisolated let sessionContinuation: AsyncStream<SessionSnapshot>.Continuation
    private nonisolated let usageContinuation: AsyncStream<UsageSnapshot>.Continuation
    private let speed: Double
    private var frozen: String?
    private var task: Task<Void, Never>?

    init(speed: Double = 1, freeze: String? = nil) {
        self.speed = max(0.1, speed)
        frozen = freeze
        (sessionSnapshots, sessionContinuation) = AsyncStream.makeStream(of: SessionSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        (usageSnapshots, usageContinuation) = AsyncStream.makeStream(of: UsageSnapshot.self, bufferingPolicy: .bufferingNewest(1))
    }

    func start() async {
        guard task == nil else { return }
        if let frozen {
            emit(scenario: frozen)
            return
        }
        task = Task { [weak self] in await self?.runTimeline() }
    }

    func stop() async {
        task?.cancel()
        sessionContinuation.finish()
        usageContinuation.finish()
    }

    func panelDidExpand() async {}
    func refreshNow() async {}
    func systemDidWake() async {}

    func freeze(_ scenario: String) {
        task?.cancel()
        task = nil
        frozen = scenario
        emit(scenario: scenario)
    }

    private func emit(scenario: String) {
        let now = Date()
        sessionContinuation.yield(SessionSnapshot(generatedAt: now, sessions: DemoScenarios.sessions(scenario, now: now)))
        usageContinuation.yield(DemoScenarios.usage(for: scenario, now: now))
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds / speed))
    }

    /// A loop that walks through every state and triggers each kind of peek.
    private func runTimeline() async {
        let S = DemoScenarios.self
        while !Task.isCancelled {
            let t0 = Date()
            func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset / speed) }
            func push(_ sessions: [AgentSession], claude5h: Double = 24) {
                sessionContinuation.yield(SessionSnapshot(generatedAt: Date(), sessions: sessions))
                usageContinuation.yield(S.usage(claude5h: claude5h, now: Date()))
            }
            let codexStart = at(0)
            func codex(_ state: SessionState, _ activity: String, since: Date) -> AgentSession {
                var s = S.session("r", .codex, state, "report-agent", activity, ago: 0, now: Date())
                s.stateSince = since
                return s
            }
            func claude(_ state: SessionState, _ activity: String, since: Date) -> AgentSession {
                var s = S.session("c", .claude, state, "claudex-bar", activity, ago: 0, now: Date())
                s.stateSince = since
                return s
            }
            push([])
            await pause(2)
            let claudeStart = at(2)
            push([claude(.working, "Thinking…", since: claudeStart)])
            await pause(3)
            push([claude(.working, "Running Bash: swift build", since: claudeStart),
                  codex(.working, "Running: uv run pytest -q", since: codexStart)])
            await pause(4)
            let approval = at(9)
            push([claude(.needsAttention(.approval(tool: "Bash", detail: "rm -rf .build")),
                         "Needs approval · Bash: rm -rf .build", since: approval),
                  codex(.working, "Editing agent.py", since: codexStart)])
            await pause(6)
            push([claude(.working, "Editing IslandView.swift", since: claudeStart),
                  codex(.working, "Running: uv run ruff check .", since: codexStart)], claude5h: 78)
            await pause(5)
            let codexDone = at(20)
            push([claude(.working, "Running Bash: swift test", since: claudeStart),
                  codex(.waitingForUser, "Waiting for you", since: codexDone)], claude5h: 82)
            await pause(6)
            let question = at(26)
            push([claude(.working, "Reading Package.swift", since: claudeStart),
                  codex(.needsAttention(.question("Deploy target")), "Question: Deploy target", since: question)], claude5h: 83)
            await pause(6)
            push([claude(.working, "Writing README.md", since: claudeStart),
                  codex(.working, "Running: make deploy", since: at(32))], claude5h: 84)
            await pause(5)
            let claudeDone = at(37)
            push([claude(.waitingForUser, "Waiting for you", since: claudeDone),
                  codex(.working, "Running: make deploy", since: at(32))], claude5h: 85)
            await pause(8)
        }
    }
}
