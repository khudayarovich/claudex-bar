import Foundation
@testable import ClaudexCore

/// A unique temporary directory (realpath-normalized), removed on deinit.
final class TempDir {
    let path: String

    init() {
        let base = NSTemporaryDirectory() + "claudexbar-tests-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        path = LiveFileSystem().realpath(base)
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }

    func url(_ name: String) -> String { Paths.join(path, name) }

    @discardableResult
    func write(_ name: String, _ text: String) -> String {
        let p = url(name)
        try? FileManager.default.createDirectory(
            atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: p, contents: Data(text.utf8))
        return p
    }

    func append(_ name: String, _ text: String) {
        let p = url(name)
        guard let h = FileHandle(forWritingAtPath: p) else { write(name, text); return }
        h.seekToEndOfFile()
        h.write(Data(text.utf8))
        try? h.close()
    }
}

/// Wraps the live file system and records every path opened for reading.
final class CountingFileSystem: FileSystemReading, @unchecked Sendable {
    private let inner = LiveFileSystem()
    private let lock = NSLock()
    private(set) var openedPaths: [String] = []
    private(set) var bytesRead = 0

    func stat(_ path: String) -> FileStat? { inner.stat(path) }
    func contentsOfDirectory(_ path: String) -> [String]? { inner.contentsOfDirectory(path) }
    func realpath(_ path: String) -> String { inner.realpath(path) }

    func read(_ path: String, offset: Int64, length: Int) -> Data? {
        let d = inner.read(path, offset: offset, length: length)
        lock.lock()
        openedPaths.append(path)
        bytesRead += d?.count ?? 0
        lock.unlock()
        return d
    }

    func readAll(_ path: String, maxBytes: Int) -> Data? {
        let d = inner.readAll(path, maxBytes: maxBytes)
        lock.lock()
        openedPaths.append(path)
        bytesRead += d?.count ?? 0
        lock.unlock()
        return d
    }
}

enum Fixture {
    static func url(_ relative: String) -> URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent(relative)
    }

    static func data(_ relative: String) -> Data {
        (try? Data(contentsOf: url(relative))) ?? Data()
    }

    static func text(_ relative: String) -> String {
        String(decoding: data(relative), as: UTF8.self)
    }
}

extension JSONLine {
    var text: String { String(decoding: bytes, as: UTF8.self) }
}
