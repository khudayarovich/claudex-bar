import Foundation

/// Delivers an event as soon as a watched process exits (kqueue NOTE_EXIT via Dispatch),
/// so crashed sessions disappear immediately instead of on the next poll.
public final class ProcessExitWatcher: @unchecked Sendable {
    public let exits: AsyncStream<Int32>
    private let continuation: AsyncStream<Int32>.Continuation
    private let queue = DispatchQueue(label: "dev.claudexbar.exitwatcher", qos: .utility)
    private var sources: [Int32: DispatchSourceProcess] = [:]   // queue-confined

    public init() {
        (exits, continuation) = AsyncStream.makeStream(of: Int32.self, bufferingPolicy: .unbounded)
    }

    deinit {
        for source in sources.values { source.cancel() }
        continuation.finish()
    }

    /// Keeps exactly `pids` under watch.
    public func setWatched(_ pids: Set<Int32>) {
        queue.async { [self] in
            for (pid, source) in sources where !pids.contains(pid) {
                source.cancel()
                sources[pid] = nil
            }
            for pid in pids where sources[pid] == nil && pid > 0 {
                let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
                let cont = continuation
                source.setEventHandler { [weak self] in
                    cont.yield(pid)
                    self?.sources[pid]?.cancel()
                    self?.sources[pid] = nil
                }
                sources[pid] = source
                source.resume()
            }
        }
    }
}
