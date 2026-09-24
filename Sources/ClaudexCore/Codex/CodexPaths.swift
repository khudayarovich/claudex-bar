import Foundation

public struct CodexPaths: Sendable, Equatable {
    /// `~/.codex` (or `CODEX_HOME`).
    public var home: String

    public init(home: String) { self.home = home }

    public static func standard(homeDirectory: String = NSHomeDirectory(), override: String? = nil) -> CodexPaths {
        CodexPaths(home: override ?? Paths.join(homeDirectory, ".codex"))
    }

    public var sessionsDir: String { Paths.join(home, "sessions") }
    public var locksDir: String { Paths.join(home, "thread-writer-locks") }
    public var sessionIndex: String { Paths.join(home, "session_index.jsonl") }
    public var authFile: String { Paths.join(home, "auth.json") }

    /// Newest `state_N.sqlite` (highest N) in the home or `sqlite/` directory.
    public func stateDatabase(fs: FileSystemReading) -> String? {
        var best: (version: Int, path: String)?
        for dir in [home, Paths.join(home, "sqlite")] {
            for name in fs.contentsOfDirectory(dir) ?? [] where name.hasPrefix("state_") && name.hasSuffix(".sqlite") {
                let middle = name.dropFirst("state_".count).dropLast(".sqlite".count)
                guard let v = Int(middle) else { continue }
                if best == nil || v > best!.version { best = (v, Paths.join(dir, name)) }
            }
        }
        return best?.path
    }

    /// Thread id from `rollout-<local time>-<uuid>.jsonl` (the trailing 36 characters).
    public static func threadID(fromRollout path: String) -> String? {
        let name = Paths.basename(path)
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { return nil }
        let stem = name.dropLast(6)
        guard stem.count > 36 else { return nil }
        let id = String(stem.suffix(36))
        return isUUIDLike(id) ? id : nil
    }

    public static func threadID(fromLock path: String) -> String? {
        let name = Paths.basename(path)
        guard name.hasSuffix(".lock") else { return nil }
        let id = String(name.dropLast(5))
        return isUUIDLike(id) ? id : nil
    }

    static func isUUIDLike(_ s: String) -> Bool {
        guard s.count == 36 else { return false }
        for (i, c) in s.enumerated() {
            if [8, 13, 18, 23].contains(i) {
                if c != "-" { return false }
            } else if !c.isHexDigit {
                return false
            }
        }
        return true
    }
}
