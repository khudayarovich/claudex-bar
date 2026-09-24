import Foundation

/// A JSONL line: either complete, or a prefix of a line too large to buffer.
public enum JSONLine: Sendable, Equatable {
    case complete(Data)
    case oversize(prefix: Data, totalBytes: Int)

    /// Bytes available for parsing (the full line, or its prefix).
    public var bytes: Data {
        switch self {
        case let .complete(d): return d
        case let .oversize(p, _): return p
        }
    }

    public var isOversize: Bool {
        if case .oversize = self { return true }
        return false
    }
}

/// Incremental `\n` framing with a per-line size cap. Oversize lines keep only a prefix.
public struct LineFramer: Sendable {
    public let maxLineBytes: Int
    public let prefixBytes: Int

    private var buffer = Data()
    private var oversizePrefix: Data?
    private var oversizeTotal = 0

    public init(maxLineBytes: Int, prefixBytes: Int = 16 * 1024) {
        self.maxLineBytes = maxLineBytes
        self.prefixBytes = prefixBytes
    }

    /// Bytes belonging to a line whose terminating newline has not arrived yet.
    public var pendingBytes: Int { oversizePrefix != nil ? oversizeTotal : buffer.count }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
        oversizePrefix = nil
        oversizeTotal = 0
    }

    public mutating func push(_ chunk: Data) -> [JSONLine] {
        var lines: [JSONLine] = []
        var start = chunk.startIndex
        while start < chunk.endIndex {
            if let nl = chunk[start...].firstIndex(of: 0x0A) {
                let piece = chunk[start..<nl]
                if let prefix = oversizePrefix {
                    lines.append(.oversize(prefix: prefix, totalBytes: oversizeTotal + piece.count))
                    oversizePrefix = nil
                    oversizeTotal = 0
                } else {
                    var line = buffer
                    line.append(piece)
                    buffer.removeAll(keepingCapacity: true)
                    if line.count > maxLineBytes {
                        lines.append(.oversize(prefix: Data(line.prefix(prefixBytes)), totalBytes: line.count))
                    } else {
                        if line.last == 0x0D { line.removeLast() }
                        if !line.isEmpty { lines.append(.complete(line)) }
                    }
                }
                start = chunk.index(after: nl)
            } else {
                let piece = chunk[start..<chunk.endIndex]
                if oversizePrefix != nil {
                    oversizeTotal += piece.count
                } else {
                    buffer.append(piece)
                    if buffer.count > maxLineBytes {
                        oversizePrefix = Data(buffer.prefix(prefixBytes))
                        oversizeTotal = buffer.count
                        buffer.removeAll(keepingCapacity: false)
                    }
                }
                start = chunk.endIndex
            }
        }
        return lines
    }
}
