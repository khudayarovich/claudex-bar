import Foundation

/// Reads complete lines backwards from the end of a file with a byte budget, so the tail of
/// a multi-hundred-megabyte JSONL file can be bootstrapped cheaply.
public enum BackwardScanner {
    public struct Result: Sendable {
        /// Lines in file order (oldest first).
        public var lines: [JSONLine]
        /// The `stop` predicate matched; that line is the first element of `lines`.
        public var reachedStop: Bool
        /// The scan consumed everything down to `floor`.
        public var reachedStart: Bool
        /// The byte budget ran out before reaching `stop` or `floor`.
        public var exhausted: Bool
        /// Offset just after the last complete line; forward tailing starts here.
        public var endOffset: Int64
        public var bytesRead: Int
        public var fileIdentity: FileIdentity?
    }

    public static func scan(
        _ fs: FileSystemReading,
        path: String,
        chunk: Int = 256 * 1024,
        budget: Int,
        maxLineBytes: Int,
        prefixBytes: Int = 16 * 1024,
        floor: Int64 = 0,
        stop: @escaping (JSONLine) -> Bool
    ) -> Result? {
        guard let st = fs.stat(path), st.isRegular else { return nil }
        var state = State(maxLineBytes: maxLineBytes, prefixBytes: prefixBytes, stop: stop)
        var pos = st.size
        var bytesRead = 0
        var end: Int64?

        while pos > floor {
            if bytesRead >= budget { state.exhausted = true; break }
            let n = Int(min(Int64(chunk), pos - floor))
            guard let data = fs.read(path, offset: pos - Int64(n), length: n), data.count == n else {
                state.exhausted = true
                break
            }
            bytesRead += n
            pos -= Int64(n)

            if end == nil {
                // Still looking for the newline that ends the last complete line.
                guard let nl = data.lastIndex(of: 0x0A) else { continue }
                end = pos + Int64(data.distance(from: data.startIndex, to: nl)) + 1
                if state.process(data[data.startIndex..<nl]) { break }
            } else {
                if state.process(data[data.startIndex..<data.endIndex]) { break }
            }
        }

        if end != nil, !state.reachedStop, !state.exhausted {
            // Reached `floor`: whatever is left is the first line of the region.
            state.flushFirstLine()
        }
        return Result(
            lines: state.newestFirst.reversed(),
            reachedStop: state.reachedStop,
            reachedStart: end != nil && !state.reachedStop && !state.exhausted,
            exhausted: state.exhausted,
            endOffset: end ?? floor,
            bytesRead: bytesRead,
            fileIdentity: st.identity
        )
    }

    private struct State {
        let maxLineBytes: Int
        let prefixBytes: Int
        let stop: (JSONLine) -> Bool
        var newestFirst: [JSONLine] = []
        /// Bytes of the current line seen so far (its end part), front-truncated when oversize.
        var lineTail = Data()
        var lineTailTotal = 0
        var reachedStop = false
        var exhausted = false

        init(maxLineBytes: Int, prefixBytes: Int, stop: @escaping (JSONLine) -> Bool) {
            self.maxLineBytes = maxLineBytes
            self.prefixBytes = prefixBytes
            self.stop = stop
        }

        /// Processes `slice` (which ends where the previously processed bytes begin) from
        /// right to left. Returns true when the stop predicate matched.
        mutating func process(_ slice: Data.SubSequence) -> Bool {
            var segEnd = slice.endIndex
            while let nl = slice[slice.startIndex..<segEnd].lastIndex(of: 0x0A) {
                let head = slice[slice.index(after: nl)..<segEnd]
                if emit(head: head) { return true }
                segEnd = nl
            }
            let part = slice[slice.startIndex..<segEnd]
            lineTailTotal += part.count
            lineTail.insert(contentsOf: part, at: lineTail.startIndex)
            if lineTailTotal > maxLineBytes, lineTail.count > prefixBytes {
                // Keep only the front-most bytes: they become the prefix once the start is found.
                lineTail = Data(lineTail.prefix(prefixBytes))
            }
            return false
        }

        mutating func flushFirstLine() {
            _ = emit(head: Data()[...])
        }

        private mutating func emit(head: Data.SubSequence) -> Bool {
            let total = head.count + lineTailTotal
            defer {
                lineTail.removeAll(keepingCapacity: true)
                lineTailTotal = 0
            }
            guard total > 0 else { return false }
            let line: JSONLine
            if total > maxLineBytes {
                var prefix = Data(head.prefix(prefixBytes))
                if prefix.count < prefixBytes { prefix.append(lineTail.prefix(prefixBytes - prefix.count)) }
                line = .oversize(prefix: prefix, totalBytes: total)
            } else {
                var bytes = Data(head)
                bytes.append(lineTail)
                if bytes.last == 0x0D { bytes.removeLast() }
                if bytes.isEmpty { return false }
                line = .complete(bytes)
            }
            newestFirst.append(line)
            if stop(line) {
                reachedStop = true
                return true
            }
            return false
        }
    }
}
