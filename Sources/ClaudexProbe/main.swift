import ClaudexCore
import CoreGraphics
import Foundation

/// Read-only diagnostics. Never prints secrets.
@main
struct ClaudexProbe {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "windows":
            WindowsCommand.run(owner: args.dropFirst().first ?? "ClaudexBar")
        case "claude-sessions":
            await SessionsCommand.claude(watch: args.contains("--watch"))
        case "codex-sessions":
            await SessionsCommand.codex(watch: args.contains("--watch"), all: args.contains("--all"))
        case "codex-loaded":
            SessionsCommand.codexLoaded()
        case "usage":
            await UsageCommand.run()
        case "engine":
            await UsageCommand.engine()
        default:
            print("""
            usage: claudex-probe <command>
              windows [owner]     list on-screen windows of an app (layer, bounds, number)
              claude-sessions [--watch]   derived Claude sessions (registry + transcripts)
              codex-sessions [--watch] [--all]  derived Codex sessions (loaded threads + rollouts)
              codex-loaded                Codex threads held open by live codex processes
              usage                       Claude + Codex plan usage (no secrets printed)
              engine                      stream merged session + usage snapshots
            """)
        }
    }
}

enum WindowsCommand {
    static func run(owner: String) {
        let options: CGWindowListOption = [.optionOnScreenOnly]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            print("no window list")
            return
        }
        for w in list where (w[kCGWindowOwnerName as String] as? String) == owner {
            let layer = w[kCGWindowLayer as String] as? Int ?? -1
            let number = w[kCGWindowNumber as String] as? Int ?? -1
            let alpha = w[kCGWindowAlpha as String] as? Double ?? -1
            var bounds = CGRect.zero
            if let b = w[kCGWindowBounds as String] as? NSDictionary {
                bounds = CGRect(dictionaryRepresentation: b as CFDictionary) ?? .zero
            }
            print("window \(number) layer=\(layer) alpha=\(alpha) bounds=(\(Int(bounds.minX)),\(Int(bounds.minY)),\(Int(bounds.width)),\(Int(bounds.height)))")
        }
    }
}

enum SessionsCommand {
    static func claude(watch: Bool) async {
        let source = ClaudeSessionSource()
        await source.start()
        var count = 0
        for await batch in source.updates {
            print("--- \(Date()) health=\(batch.health) sessions=\(batch.sessions.count)")
            for s in batch.sessions { print(describe(s)) }
            count += 1
            if !watch { break }
        }
        await source.stop()
    }

    static func codex(watch: Bool, all: Bool) async {
        var filter = CodexSessionSource.Filter()
        if all { filter.recentWindow = 1e9; filter.errorWindow = 1e9 }
        let source = CodexSessionSource(filter: filter)
        await source.start()
        for await batch in source.updates {
            print("--- \(Date()) health=\(batch.health) sessions=\(batch.sessions.count)")
            for s in batch.sessions { print(describe(s)) }
            if !watch { break }
        }
        await source.stop()
    }

    static func codexLoaded() {
        var detector = LoadedThreadDetector()
        let r = detector.detect(paths: .standard(), fs: LiveFileSystem(), inspector: LibprocInspector(), now: Date(),
                                forceEnumerate: true)
        print("owners=\(r.ownerPIDs.sorted()) fdListingFailed=\(r.fdListingFailed)")
        for t in r.threads.values.sorted(by: { $0.threadID < $1.threadID }) {
            print("\(t.ownerPID) \(t.threadID) rollout=\(t.rolloutPath != nil) lock=\(t.lockPath != nil)")
        }
    }

    static func describe(_ s: AgentSession) -> String {
        let lamp: String
        switch s.state.lamp {
        case .red: lamp = "RED   "
        case .yellow: lamp = "YELLOW"
        case .green: lamp = "GREEN "
        }
        let age = Int(Date().timeIntervalSince(s.stateSince))
        return "\(lamp) [\(s.origin.badge)] \(s.title) — \(s.activity) (since \(age)s, pid \(s.pid.map(String.init) ?? "-"), \(s.confidence))"
    }
}

enum UsageCommand {
    static func describe(_ u: ProviderUsage) -> String {
        var out = "\(u.provider.displayName) plan=\(u.plan ?? "-") status=\(u.status) limitReached=\(u.limitReached)"
        for w in u.windows {
            let pct = w.usedPercent.map { String(format: "%.0f%%", $0) } ?? "—"
            let reset = w.resetsAt.map { "resets in \(Durations.short($0.timeIntervalSinceNow))" } ?? "reset time unknown"
            out += "\n    \(w.label.padding(toLength: 16, withPad: " ", startingAt: 0)) \(pct.padding(toLength: 5, withPad: " ", startingAt: 0)) \(reset)  [\(w.source.displayName), \(Durations.short(-w.fetchedAt.timeIntervalSinceNow)) old\(w.isReset ? ", reset" : "")]"
        }
        return out
    }

    static func run() async {
        let claude = ClaudeUsageProvider()
        let codex = CodexUsageProvider()
        await claude.start()
        await codex.start()
        await claude.refresh(force: true)
        await codex.refresh(force: true)
        var claudeIt = claude.updates.makeAsyncIterator()
        var codexIt = codex.updates.makeAsyncIterator()
        if let u = await claudeIt.next() { print(describe(u)) }
        if let u = await codexIt.next() { print(describe(u)) }
        await claude.stop()
        await codex.stop()
    }

    static func engine() async {
        let engine = ClaudexEngine()
        await engine.start()
        let sessions = Task {
            for await snap in engine.sessionSnapshots {
                print("=== sessions @ \(snap.generatedAt)")
                for s in Aggregator.ordered(snap.sessions, now: Date()) { print("  " + SessionsCommand.describe(s)) }
                let lamps = Aggregator.lamps(snap.sessions, now: Date())
                for p in Provider.allCases {
                    let l = lamps[p]!
                    print("  lamps \(p.displayName): red=\(l.red) yellow=\(l.yellow) green=\(l.green)")
                }
            }
        }
        let usage = Task {
            for await u in engine.usageSnapshots {
                print("=== usage @ \(u.generatedAt)")
                print("  " + describe(u.claude).replacingOccurrences(of: "\n", with: "\n  "))
                print("  " + describe(u.codex).replacingOccurrences(of: "\n", with: "\n  "))
            }
        }
        try? await Task.sleep(for: .seconds(8))
        sessions.cancel()
        usage.cancel()
        await engine.stop()
    }
}
