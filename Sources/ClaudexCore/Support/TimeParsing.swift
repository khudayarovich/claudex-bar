import Foundation

/// Hand-rolled, allocation-light, Sendable time parsers (no shared DateFormatter).
public enum TimeParsing {
    /// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
    static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// Parses ISO-8601 timestamps such as `2026-09-22T19:23:24.036Z`,
    /// `2026-09-19T06:09:04.873161Z` or `2026-09-23T03:00:00.123+00:00`.
    public static func iso8601(_ s: String) -> Date? {
        let b = Array(s.utf8)
        func num(_ from: Int, _ len: Int) -> Int? {
            guard from + len <= b.count else { return nil }
            var v = 0
            for i in from..<(from + len) {
                let c = b[i]
                guard c >= 48, c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            return v
        }
        guard b.count >= 19,
              let year = num(0, 4), b[4] == UInt8(ascii: "-"),
              let month = num(5, 2), b[7] == UInt8(ascii: "-"),
              let day = num(8, 2), b[10] == UInt8(ascii: "T") || b[10] == UInt8(ascii: " "),
              let hour = num(11, 2), b[13] == UInt8(ascii: ":"),
              let minute = num(14, 2), b[16] == UInt8(ascii: ":"),
              let second = num(17, 2),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61
        else { return nil }

        var i = 19
        var fraction = 0.0
        if i < b.count, b[i] == UInt8(ascii: ".") || b[i] == UInt8(ascii: ",") {
            i += 1
            var scale = 0.1
            while i < b.count, b[i] >= 48, b[i] <= 57 {
                fraction += Double(b[i] - 48) * scale
                scale /= 10
                i += 1
            }
        }
        var offset = 0
        if i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "Z") || c == UInt8(ascii: "z") {
                i += 1
            } else if c == UInt8(ascii: "+") || c == UInt8(ascii: "-") {
                let sign = c == UInt8(ascii: "+") ? 1 : -1
                guard let oh = num(i + 1, 2) else { return nil }
                var om = 0
                if let m = num(i + 4, 2), b[i + 3] == UInt8(ascii: ":") {
                    om = m
                } else if let m = num(i + 3, 2) {
                    om = m
                }
                offset = sign * (oh * 3600 + om * 60)
            } else {
                return nil
            }
        }
        let days = daysFromCivil(year, month, day)
        let seconds = Double(days * 86_400 + hour * 3600 + minute * 60 + second - offset) + fraction
        return Date(timeIntervalSince1970: seconds)
    }

    /// Interprets a numeric epoch in seconds, milliseconds, microseconds or nanoseconds.
    public static func epoch(_ v: Double) -> Date? {
        guard v.isFinite, v > 0 else { return nil }
        if v > 1e17 { return Date(timeIntervalSince1970: v / 1e9) }
        if v > 1e14 { return Date(timeIntervalSince1970: v / 1e6) }
        if v > 1e11 { return Date(timeIntervalSince1970: v / 1e3) }
        return Date(timeIntervalSince1970: v)
    }

    /// Accepts an epoch number, a numeric string, or an ISO-8601 string.
    public static func flexible(_ value: JSONValue?) -> Date? {
        guard let value else { return nil }
        switch value {
        case let .number(d): return epoch(d)
        case let .string(s):
            if let d = Double(s) { return epoch(d) }
            return iso8601(s)
        default: return nil
        }
    }

    private static let months: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
    ]

    /// Parses `ps -o lstart` style strings in UTC, e.g. `"Tue Sep 22 19:21:32 2026"` or
    /// `"Wed Sep  2 08:00:00 2026"` (space-padded day). Claude Code writes these as
    /// `procStart` to detect PID reuse.
    public static func procStart(_ s: String) -> Date? {
        let parts = s.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 5,
              let month = months[parts[1].prefix(3).lowercased()],
              let day = Int(parts[2]),
              let year = Int(parts[4])
        else { return nil }
        let hms = parts[3].split(separator: ":")
        guard hms.count == 3, let h = Int(hms[0]), let m = Int(hms[1]), let sec = Int(hms[2]) else { return nil }
        let days = daysFromCivil(year, month, day)
        return Date(timeIntervalSince1970: Double(days * 86_400 + h * 3600 + m * 60 + sec))
    }
}
