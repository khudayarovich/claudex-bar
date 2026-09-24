import Foundation

/// Follows an append-only JSONL file from a saved offset.
public struct ForwardTailer: Sendable {
    public enum Result: Sendable, Equatable {
        case lines([JSONLine])
        case unchanged
        case missing
        /// The file was replaced, truncated, or grew by more than `maxGap`: re-bootstrap.
        case needsBootstrap(reason: String)
    }

    public let path: String
    public private(set) var identity: FileIdentity?
    /// Bytes consumed into the framer.
    public private(set) var readOffset: Int64
    /// End of the last complete line (safe restart point).
    public var committedOffset: Int64 { readOffset - Int64(framer.pendingBytes) }

    private var framer: LineFramer
    private let chunk: Int
    private let maxGap: Int64

    public init(path: String, identity: FileIdentity?, offset: Int64, maxLineBytes: Int,
                chunk: Int = 1 << 20, maxGap: Int64 = 8 << 20) {
        self.path = path
        self.identity = identity
        self.readOffset = offset
        self.framer = LineFramer(maxLineBytes: maxLineBytes)
        self.chunk = chunk
        self.maxGap = maxGap
    }

    public mutating func poll(_ fs: FileSystemReading) -> Result {
        guard let st = fs.stat(path), st.isRegular else { return .missing }
        if let identity, identity != st.identity { return .needsBootstrap(reason: "replaced") }
        identity = st.identity
        if st.size < readOffset { return .needsBootstrap(reason: "truncated") }
        if st.size == readOffset { return .unchanged }
        if st.size - readOffset > maxGap { return .needsBootstrap(reason: "gap") }

        var lines: [JSONLine] = []
        while readOffset < st.size {
            let want = Int(min(Int64(chunk), st.size - readOffset))
            guard let data = fs.read(path, offset: readOffset, length: want), !data.isEmpty else { break }
            readOffset += Int64(data.count)
            lines.append(contentsOf: framer.push(data))
        }
        return lines.isEmpty ? .unchanged : .lines(lines)
    }
}
