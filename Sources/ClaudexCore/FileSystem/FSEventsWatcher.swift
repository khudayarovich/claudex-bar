import CoreServices
import Foundation

/// File-level FSEvents for a set of directories, delivered as an AsyncStream of batches.
/// The stream ref is only touched on the watcher's private queue.
public final class FSEventsWatcher: @unchecked Sendable {
    public struct Event: Sendable, Equatable {
        public var path: String
        public var flags: UInt32

        /// Events were dropped or coalesced: rescan everything under the root.
        public var requiresRescan: Bool {
            let mask = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagRootChanged)
            return flags & mask != 0
        }
    }

    public let events: AsyncStream<[Event]>
    private let continuation: AsyncStream<[Event]>.Continuation
    private let queue = DispatchQueue(label: "dev.claudexbar.fsevents", qos: .utility)
    private let paths: [String]
    private let latency: CFTimeInterval
    private var stream: FSEventStreamRef?

    public init(paths: [String], latency: TimeInterval = 0.25) {
        self.paths = paths
        self.latency = latency
        (events, continuation) = AsyncStream.makeStream(of: [Event].self, bufferingPolicy: .unbounded)
    }

    deinit {
        continuation.finish()
    }

    @discardableResult
    public func start() -> Bool {
        queue.sync {
            guard stream == nil else { return true }
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil, release: nil, copyDescription: nil
            )
            let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
                guard let info else { return }
                let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
                let cfPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
                guard let paths = cfPaths as? [String] else { return }
                var batch: [Event] = []
                batch.reserveCapacity(count)
                for i in 0..<min(count, paths.count) {
                    batch.append(Event(path: paths[i], flags: eventFlags[i]))
                }
                watcher.continuation.yield(batch)
            }
            let flags = UInt32(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes
            )
            guard let s = FSEventStreamCreate(
                kCFAllocatorDefault, callback, &context, paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
            ) else { return false }
            FSEventStreamSetDispatchQueue(s, queue)
            guard FSEventStreamStart(s) else {
                FSEventStreamInvalidate(s)
                FSEventStreamRelease(s)
                return false
            }
            stream = s
            return true
        }
    }

    public func stop() {
        queue.sync {
            guard let s = stream else { return }
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        continuation.finish()
    }
}
