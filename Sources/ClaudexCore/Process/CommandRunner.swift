import Foundation

/// Runs a short-lived helper (e.g. `/usr/bin/security`) with a timeout, a minimal
/// environment, no stdin, and a cap on captured output.
public enum CommandRunner {
    public struct Output: Sendable {
        public var status: Int32
        public var stdout: Data
        public var timedOut: Bool
    }

    public static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = 10,
        maxOutput: Int = 64 * 1024
    ) async -> Output? {
        await withCheckedContinuation { (cont: CheckedContinuation<Output?, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let env = ProcessInfo.processInfo.environment
            var minimal: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
            for key in ["HOME", "USER", "LOGNAME", "TMPDIR"] { minimal[key] = env[key] }
            process.environment = minimal
            process.standardInput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe

            let collector = OutputCollector(limit: maxOutput)
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    collector.append(chunk)
                }
            }
            let finished = OnceFlag()
            process.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                collector.append(rest)
                if finished.set() {
                    cont.resume(returning: Output(status: p.terminationStatus, stdout: collector.data, timedOut: false))
                }
            }
            do {
                try process.run()
            } catch {
                if finished.set() { cont.resume(returning: nil) }
                return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    process.terminate()
                    if finished.set() {
                        cont.resume(returning: Output(status: -1, stdout: Data(), timedOut: true))
                    }
                }
            }
        }
    }
}

/// Thread-safe byte accumulator with a size cap.
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        let room = limit - buffer.count
        if room > 0 { buffer.append(chunk.prefix(room)) }
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

/// Returns true exactly once.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func set() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
