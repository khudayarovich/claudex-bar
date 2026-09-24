import Foundation

/// Wraps a credential so it can never be printed, logged, dumped or encoded by accident.
/// The raw value is only reachable through `withValue`, used by the HTTP layer.
public struct SecretToken: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    private let value: String

    public init(_ value: String) { self.value = value }

    public var isEmpty: Bool { value.isEmpty }
    public var count: Int { value.count }

    public func withValue<T>(_ body: (String) throws -> T) rethrows -> T { try body(value) }

    /// A process-local fingerprint for change detection; never persisted.
    public var fingerprint: Int {
        var h = Hasher()
        h.combine(value)
        return h.finalize()
    }

    public var description: String { "<redacted \(value.count) chars>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// Produces short, single-line, redacted text suitable for the UI.
public enum TextSanitizer {
    /// Collapses whitespace, strips control characters and ANSI escapes, redacts secrets
    /// and truncates to `maxLength` characters (with an ellipsis).
    public static func oneLine(_ input: String, maxLength: Int = 100) -> String {
        var out = String.UnicodeScalarView()
        var lastWasSpace = false
        var iterator = input.unicodeScalars.makeIterator()
        var budget = maxLength * 4 + 256   // bound the work on huge inputs
        while let scalar = iterator.next(), budget > 0 {
            budget -= 1
            if scalar == "\u{1B}" {
                // Skip an ANSI CSI sequence: ESC [ … final byte in @…~
                if let next = iterator.next(), next == "[" {
                    while let c = iterator.next() {
                        if (0x40...0x7E).contains(c.value) { break }
                    }
                }
                continue
            }
            if scalar.properties.generalCategory == .control || scalar.properties.isWhitespace {
                if !lastWasSpace && !out.isEmpty { out.append(" ") }
                lastWasSpace = true
                continue
            }
            out.append(scalar)
            lastWasSpace = false
        }
        var text = String(out)
        while text.last == " " { text.removeLast() }
        text = redact(text)
        if text.count > maxLength {
            text = String(text.prefix(max(1, maxLength - 1))) + "…"
        }
        return text
    }

    /// Replaces things that look like credentials with `‹redacted›`.
    public static func redact(_ input: String) -> String {
        guard input.count >= 8 else { return input }
        var text = input
        // Whole-match replacements.
        let whole: [(String, String)] = [
            (#"(?i)bearer\s+[A-Za-z0-9._~+/=-]{8,}"#, "Bearer ‹redacted›"),
            (#"sk-ant-[A-Za-z0-9_-]{8,}"#, "‹redacted›"),
            (#"sk-[A-Za-z0-9_-]{16,}"#, "‹redacted›"),
            (#"gh[pousr]_[A-Za-z0-9]{20,}"#, "‹redacted›"),
            (#"github_pat_[A-Za-z0-9_]{20,}"#, "‹redacted›"),
            (#"xox[abpr]-[A-Za-z0-9-]{10,}"#, "‹redacted›"),
            (#"AKIA[0-9A-Z]{16}"#, "‹redacted›"),
            (#"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#, "‹redacted›"),
        ]
        for (pattern, replacement) in whole {
            if let regex = try? Regex<Substring>(pattern) {
                text = text.replacing(regex, with: replacement)
            }
        }
        // Key/value pairs: keep the key, redact the value.
        let keyed = [
            #"(?i)((?:api[_-]?key|access[_-]?token|auth[_-]?token|token|secret|password|passwd)[A-Za-z0-9_]*\s*[=:]\s*)[^\s‹]+"#,
            #"(?i)(--(?:password|token|api-key)(?:=|\s+))[^\s‹]+"#,
        ]
        for pattern in keyed {
            if let regex = try? Regex<(Substring, Substring)>(pattern) {
                text = text.replacing(regex) { match in String(match.output.1) + "‹redacted›" }
            }
        }
        return text
    }
}
