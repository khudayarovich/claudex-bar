import Darwin
import Foundation

public struct FileIdentity: Sendable, Hashable {
    public var device: UInt64
    public var inode: UInt64
}

public struct FileStat: Sendable, Equatable {
    public var identity: FileIdentity
    public var size: Int64
    public var modified: Date
    public var created: Date
    public var isDirectory: Bool
    public var isRegular: Bool
}

/// Read-only file access. Injected so tests can count bytes and assert which paths were
/// opened (e.g. that `*.key` files next to Claude's registry are never touched).
public protocol FileSystemReading: Sendable {
    func stat(_ path: String) -> FileStat?
    func contentsOfDirectory(_ path: String) -> [String]?
    /// Reads up to `length` bytes starting at `offset`. Returns nil if the file can't be opened.
    func read(_ path: String, offset: Int64, length: Int) -> Data?
    /// Reads the whole file if it is at most `maxBytes` long.
    func readAll(_ path: String, maxBytes: Int) -> Data?
    func realpath(_ path: String) -> String
}

public struct LiveFileSystem: FileSystemReading {
    public init() {}

    public func stat(_ path: String) -> FileStat? {
        var st = Darwin.stat()
        guard posixStat(path, &st) == 0 else { return nil }
        func date(_ ts: timespec) -> Date {
            Date(timeIntervalSince1970: Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9)
        }
        let type = st.st_mode & S_IFMT
        return FileStat(
            identity: FileIdentity(device: UInt64(bitPattern: Int64(st.st_dev)), inode: st.st_ino),
            size: Int64(st.st_size),
            modified: date(st.st_mtimespec),
            created: date(st.st_birthtimespec),
            isDirectory: type == S_IFDIR,
            isRegular: type == S_IFREG
        )
    }

    public func contentsOfDirectory(_ path: String) -> [String]? {
        guard let dir = opendir(path) else { return nil }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    public func read(_ path: String, offset: Int64, length: Int) -> Data? {
        guard length >= 0 else { return nil }
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if length == 0 { return Data() }
        var data = Data(count: length)
        var total = 0
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            while total < length {
                let n = pread(fd, base.advanced(by: total), length - total, off_t(offset) + off_t(total))
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if n == 0 { break }
                total += n
            }
            return true
        }
        guard ok else { return nil }
        if total < length { data.removeSubrange(total..<length) }
        return data
    }

    public func readAll(_ path: String, maxBytes: Int) -> Data? {
        guard let st = stat(path), st.isRegular, st.size <= Int64(maxBytes) else { return nil }
        return read(path, offset: 0, length: Int(st.size))
    }

    public func realpath(_ path: String) -> String {
        guard let resolved = Darwin.realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

public enum Paths {
    public static var home: String { NSHomeDirectory() }

    public static func join(_ parts: String...) -> String {
        parts.reduce("") { acc, part in
            if acc.isEmpty { return part }
            if acc.hasSuffix("/") { return acc + (part.hasPrefix("/") ? String(part.dropFirst()) : part) }
            return acc + (part.hasPrefix("/") ? part : "/" + part)
        }
    }

    /// Last path component without touching the file system.
    public static func basename(_ path: String) -> String {
        var p = Substring(path)
        while p.count > 1 && p.hasSuffix("/") { p = p.dropLast() }
        if let slash = p.lastIndex(of: "/") { return String(p[p.index(after: slash)...]) }
        return String(p)
    }
}

/// File-scope wrapper: inside a method named `stat`, `stat(path, &buf)` would resolve to
/// the struct initializer instead of the POSIX function.
private func posixStat(_ path: String, _ buf: UnsafeMutablePointer<Darwin.stat>) -> Int32 {
    fstatat(AT_FDCWD, path, buf, 0)
}
