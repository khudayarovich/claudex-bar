import Foundation

public struct DerivedState: Sendable, Equatable {
    public var state: SessionState
    public var activity: String
    public var since: Date
    public var confidence: Confidence
}

/// Combines a registry entry (authoritative status) with transcript detail.
public enum ClaudeStateDeriver {
    /// A clean turn end older than this while the registry still says `busy` means a
    /// background task is keeping the session busy (2.1.121 reports that case as `busy`).
    public static let busyDemoteGrace: TimeInterval = 60

    public static func derive(
        _ e: ClaudeRegistryEntry,
        transcript t: ClaudeTranscriptState?,
        registryModified: Date?,
        now: Date
    ) -> DerivedState {
        let since = ClaudeRegistryEntry.date(ms: e.statusUpdatedAt ?? e.updatedAt)
            ?? registryModified
            ?? ClaudeRegistryEntry.date(ms: e.startedAt)
            ?? now
        let pending = t?.latestPending

        if e.kind == .bg {
            let detail = (e.detail ?? e.needs).map { TextSanitizer.oneLine($0, maxLength: 80) }
            switch (e.state?.lowercased(), e.tempo?.lowercased()) {
            case ("failed", _):
                return .init(state: .needsAttention(.error(detail)), activity: AttentionMapper.text(.error(detail)),
                             since: since, confidence: .reported)
            case ("blocked", _), (_, "blocked"):
                let reason = AttentionReason.input(e.needs.map { TextSanitizer.oneLine($0, maxLength: 80) } ?? detail)
                return .init(state: .needsAttention(reason), activity: AttentionMapper.text(reason), since: since, confidence: .reported)
            case ("working", _), (_, "active"):
                return .init(state: .working, activity: detail ?? pending?.summary.working ?? "Working in background",
                             since: since, confidence: .reported)
            case ("done", _):
                return .init(state: .waitingForUser, activity: "Finished", since: since, confidence: .reported)
            case ("stopped", _):
                return .init(state: .waitingForUser, activity: "Stopped", since: since, confidence: .reported)
            default:
                break   // fall through to the status mapping
            }
        }

        switch e.status {
        case .waiting?:
            let reason = AttentionMapper.map(e.waitingFor, pending: pending)
            return .init(state: .needsAttention(reason), activity: AttentionMapper.text(reason), since: since, confidence: .reported)

        case .busy?:
            if let t, let ended = t.turnEndedAt, t.pending.isEmpty,
               now.timeIntervalSince(ended) >= busyDemoteGrace, ended >= since.addingTimeInterval(-1) {
                return .init(state: .waitingForUser, activity: "Background task running", since: ended, confidence: .inferred)
            }
            if let r = t?.lastRetry, let at = r.at,
               at >= max(t?.lastAssistantAt ?? .distantPast, t?.lastPromptAt ?? .distantPast),
               now.timeIntervalSince(at) < (r.retryInMs ?? 0) / 1000 + 30 {
                var text = "Retrying"
                if let a = r.attempt, let m = r.maxAttempts { text += " (\(a)/\(m))" }
                if let msg = r.message { text += ": \(msg)" }
                return .init(state: .working, activity: text, since: since, confidence: .reported)
            }
            let activity = pending?.summary.working ?? (t?.lastPromptAt != nil ? "Thinking…" : "Working…")
            return .init(state: .working, activity: activity, since: since, confidence: .reported)

        case .shell?:
            return .init(state: .waitingForUser, activity: "Background shell running", since: since, confidence: .reported)

        case .idle?:
            if let err = t?.currentTurnError {
                let reason: AttentionReason = err.category == "rate_limit" ? .usageLimit : .error(err.text)
                return .init(state: .needsAttention(reason), activity: AttentionMapper.text(reason),
                             since: err.at ?? since, confidence: .reported)
            }
            var idleSince = since
            if let started = ClaudeRegistryEntry.date(ms: e.startedAt), abs(since.timeIntervalSince(started)) < 5 {
                // Just (re)started with no new turn: age from the last real activity instead.
                idleSince = t?.turnEndedAt ?? t?.lastRecordAt ?? since
            }
            let interrupted = t?.interruptedAt.map { $0 >= (t?.lastAssistantAt ?? .distantPast) } ?? false
            return .init(state: .waitingForUser, activity: interrupted ? "Interrupted" : "Waiting for you",
                         since: idleSince, confidence: .reported)

        case .unknown?, nil:
            // Unknown status: infer from the transcript.
            if let err = t?.currentTurnError {
                let reason: AttentionReason = err.category == "rate_limit" ? .usageLimit : .error(err.text)
                return .init(state: .needsAttention(reason), activity: AttentionMapper.text(reason),
                             since: err.at ?? since, confidence: .inferred)
            }
            if let p = pending, let last = t?.lastRecordAt, now.timeIntervalSince(last) < 600 {
                return .init(state: .working, activity: p.summary.working, since: p.at ?? since, confidence: .inferred)
            }
            return .init(state: .waitingForUser, activity: "Waiting for you",
                         since: t?.turnEndedAt ?? t?.lastRecordAt ?? since, confidence: .inferred)
        }
    }

    public static func title(_ e: ClaudeRegistryEntry, transcript t: ClaudeTranscriptState?) -> String {
        let candidates = [e.name, t?.bestTitle, e.cwd.map(Paths.basename)]
        for c in candidates {
            if let c, !c.trimmingCharacters(in: .whitespaces).isEmpty {
                return TextSanitizer.oneLine(c, maxLength: 60)
            }
        }
        return "Claude session"
    }
}
