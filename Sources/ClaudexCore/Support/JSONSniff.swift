import Foundation

/// Byte-level extraction of string fields from the *prefix* of a JSON line, for lines too
/// large to decode (huge tool outputs, compaction records, base instructions).
public enum JSONSniff {
    /// Returns the first string value for `"key":` found in `data` (after `start`), with
    /// basic escape handling. Returns nil when the key is absent or the value is not a string.
    public static func string(_ key: String, in data: Data, after start: Int = 0) -> String? {
        let bytes = [UInt8](data)
        guard let valueStart = locateValue(key, in: bytes, from: start) else { return nil }
        return readString(bytes, at: valueStart)
    }

    /// For Codex rollout lines (`{"timestamp":…,"ordinal":…,"type":X,"payload":{"type":Y,…`):
    /// returns (X, Y).
    public static func codexKinds(_ data: Data) -> (type: String?, payloadType: String?) {
        let bytes = [UInt8](data)
        let type = locateValue("type", in: bytes, from: 0).flatMap { readString(bytes, at: $0) }
        var payloadType: String?
        if let p = find(Array(#""payload":"#.utf8), in: bytes, from: 0) {
            payloadType = locateValue("type", in: bytes, from: p).flatMap { readString(bytes, at: $0) }
        }
        return (type, payloadType)
    }

    // MARK: - Internals

    static func find(_ needle: [UInt8], in hay: [UInt8], from: Int) -> Int? {
        guard !needle.isEmpty, hay.count >= needle.count, from <= hay.count - needle.count else { return nil }
        var i = from
        let last = hay.count - needle.count
        while i <= last {
            if hay[i] == needle[0] {
                var j = 1
                while j < needle.count && hay[i + j] == needle[j] { j += 1 }
                if j == needle.count { return i }
            }
            i += 1
        }
        return nil
    }

    /// Index of the first byte of the value following `"key"` + optional spaces + `:`.
    static func locateValue(_ key: String, in bytes: [UInt8], from: Int) -> Int? {
        let needle = Array("\"\(key)\"".utf8)
        var searchFrom = from
        while let k = find(needle, in: bytes, from: searchFrom) {
            var i = k + needle.count
            while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x09 { i += 1 }
            if i < bytes.count, bytes[i] == UInt8(ascii: ":") {
                i += 1
                while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x09 { i += 1 }
                return i
            }
            searchFrom = k + 1
        }
        return nil
    }

    static func readString(_ bytes: [UInt8], at start: Int) -> String? {
        guard start < bytes.count, bytes[start] == UInt8(ascii: "\"") else { return nil }
        var out = [UInt8]()
        var i = start + 1
        while i < bytes.count {
            let c = bytes[i]
            if c == UInt8(ascii: "\"") { return String(decoding: out, as: UTF8.self) }
            if c == UInt8(ascii: "\\"), i + 1 < bytes.count {
                let e = bytes[i + 1]
                switch e {
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "u"):
                    if i + 5 < bytes.count,
                       let v = UInt32(String(decoding: bytes[(i + 2)...(i + 5)], as: UTF8.self), radix: 16),
                       let scalar = Unicode.Scalar(v) {
                        out.append(contentsOf: Array(String(Character(scalar)).utf8))
                        i += 6
                        continue
                    }
                    out.append(e)
                default: out.append(e)
                }
                i += 2
                continue
            }
            out.append(c)
            i += 1
        }
        return nil   // unterminated (truncated prefix)
    }
}
