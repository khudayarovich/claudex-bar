import Foundation
import Testing
@testable import ClaudexCore

@Suite("TimeParsing")
struct TimeParsingTests {
    @Test(arguments: [
        ("2026-09-22T19:23:24.036Z", 1_790_105_004.036),
        ("2026-09-19T06:09:04.873161Z", 1_789_798_144.873161),
        ("2026-09-02T04:09:59Z", 1_788_322_199.0),
        ("2026-09-23T03:00:00.123+00:00", 1_790_132_400.123),
        ("2026-09-23T08:00:00+05:00", 1_790_132_400.0),
        ("2026-09-23T08:00:00+0500", 1_790_132_400.0),
    ])
    func iso8601(input: String, expected: Double) throws {
        let d = try #require(TimeParsing.iso8601(input))
        #expect(abs(d.timeIntervalSince1970 - expected) < 0.000_5)
    }

    @Test func iso8601RejectsGarbage() {
        #expect(TimeParsing.iso8601("") == nil)
        #expect(TimeParsing.iso8601("yesterday") == nil)
        #expect(TimeParsing.iso8601("2026-13-01T00:00:00Z") == nil)
    }

    @Test func epochHeuristics() {
        #expect(TimeParsing.epoch(1_790_105_004)?.timeIntervalSince1970 == 1_790_105_004)
        #expect(TimeParsing.epoch(1_790_105_004_036)?.timeIntervalSince1970 == 1_790_105_004.036)
        #expect(TimeParsing.epoch(1_790_105_004_036_000)?.timeIntervalSince1970 == 1_790_105_004.036)
        #expect(TimeParsing.epoch(0) == nil)
        #expect(TimeParsing.epoch(.nan) == nil)
    }

    @Test func procStartMatchesPsLstartInUTC() throws {
        let d = try #require(TimeParsing.procStart("Thu Sep 24 21:50:26 2026"))
        #expect(d.timeIntervalSince1970 == 1_790_286_626)
        let padded = try #require(TimeParsing.procStart("Wed Sep  2 08:00:00 2026"))
        #expect(padded.timeIntervalSince1970 == 1_788_336_000)
        #expect(TimeParsing.procStart("not a date") == nil)
    }
}

@Suite("LineFramer")
struct LineFramerTests {
    @Test func holdsPartialLinesAcrossPushes() {
        var f = LineFramer(maxLineBytes: 100)
        #expect(f.push(Data("{\"a\":".utf8)).isEmpty)
        #expect(f.pendingBytes == 5)
        let lines = f.push(Data("1}\n{\"b\":2}\n{\"c\"".utf8))
        #expect(lines.map(\.text) == ["{\"a\":1}", "{\"b\":2}"])
        #expect(f.pendingBytes == 4)
    }

    @Test func stripsCRAndSkipsEmptyLines() {
        var f = LineFramer(maxLineBytes: 100)
        let lines = f.push(Data("a\r\n\n\nb\n".utf8))
        #expect(lines.map(\.text) == ["a", "b"])
    }

    @Test func multibyteCharacterSplitAcrossChunks() {
        var f = LineFramer(maxLineBytes: 100)
        let bytes = Array("héllo\n".utf8)
        var out = f.push(Data(bytes[0..<2]))
        out += f.push(Data(bytes[2...]))
        #expect(out.map(\.text) == ["héllo"])
    }

    @Test func oversizeLinesKeepOnlyAPrefix() {
        var f = LineFramer(maxLineBytes: 10, prefixBytes: 4)
        var out = f.push(Data("0123456789ABCDEF".utf8))
        #expect(out.isEmpty)
        out = f.push(Data("GH\nok\n".utf8))
        #expect(out.count == 2)
        #expect(out[0] == .oversize(prefix: Data("0123".utf8), totalBytes: 18))
        #expect(out[1].text == "ok")
    }
}

@Suite("ForwardTailer")
struct ForwardTailerTests {
    @Test func followsAppendsAndDetectsReplacement() {
        let dir = TempDir()
        let path = dir.write("log.jsonl", "a\nb\n")
        let fs = LiveFileSystem()
        var tailer = ForwardTailer(path: path, identity: fs.stat(path)?.identity, offset: 2, maxLineBytes: 100)
        #expect(tailer.poll(fs) == .lines([.complete(Data("b".utf8))]))
        #expect(tailer.poll(fs) == .unchanged)

        dir.append("log.jsonl", "c\npartial")
        #expect(tailer.poll(fs) == .lines([.complete(Data("c".utf8))]))
        #expect(tailer.committedOffset == 6)
        dir.append("log.jsonl", "-done\n")
        #expect(tailer.poll(fs) == .lines([.complete(Data("partial-done".utf8))]))

        // Atomic replacement (new inode) forces a re-bootstrap.
        let tmp = dir.write("new.jsonl", "x\n")
        _ = rename(tmp, path)
        if case .needsBootstrap = tailer.poll(fs) {} else { Issue.record("expected needsBootstrap") }
    }

    @Test func truncationAndGapForceBootstrap() {
        let dir = TempDir()
        let path = dir.write("log.jsonl", "aaaa\nbbbb\n")
        let fs = LiveFileSystem()
        var tailer = ForwardTailer(path: path, identity: fs.stat(path)?.identity, offset: 10, maxLineBytes: 100)
        _ = truncate(path, 5)
        #expect(tailer.poll(fs) == .needsBootstrap(reason: "truncated"))

        var small = ForwardTailer(path: path, identity: fs.stat(path)?.identity, offset: 0, maxLineBytes: 100, maxGap: 2)
        #expect(small.poll(fs) == .needsBootstrap(reason: "gap"))
    }

    @Test func missingFile() {
        var tailer = ForwardTailer(path: "/nonexistent/x.jsonl", identity: nil, offset: 0, maxLineBytes: 100)
        #expect(tailer.poll(LiveFileSystem()) == .missing)
    }
}

@Suite("BackwardScanner")
struct BackwardScannerTests {
    static func numbered(_ n: Int, marker: Int? = nil) -> String {
        (1...n).map { i in i == marker ? "{\"type\":\"task_started\",\"i\":\(i)}" : "{\"i\":\(i)}" }
            .joined(separator: "\n") + "\n"
    }

    @Test func stopsAtTheLastMarkerAndExcludesPartialTail() throws {
        let dir = TempDir()
        let path = dir.write("r.jsonl", Self.numbered(50, marker: 40) + "{\"partial\":")
        let r = try #require(BackwardScanner.scan(LiveFileSystem(), path: path, chunk: 16, budget: 1 << 20,
                                                   maxLineBytes: 1000) { $0.text.contains("task_started") })
        #expect(r.reachedStop)
        #expect(r.lines.first?.text.contains("\"i\":40") == true)
        #expect(r.lines.last?.text == "{\"i\":50}")
        #expect(r.lines.count == 11)
        let size = try #require(LiveFileSystem().stat(path)?.size)
        #expect(r.endOffset == size - Int64("{\"partial\":".utf8.count))
    }

    @Test func readsWholeSmallFileWhenNoMarker() throws {
        let dir = TempDir()
        let path = dir.write("r.jsonl", Self.numbered(5))
        let r = try #require(BackwardScanner.scan(LiveFileSystem(), path: path, chunk: 7, budget: 1 << 20,
                                                   maxLineBytes: 1000) { _ in false })
        #expect(r.reachedStart)
        #expect(!r.reachedStop)
        #expect(r.lines.map(\.text) == (1...5).map { "{\"i\":\($0)}" })
    }

    @Test func budgetExhaustion() throws {
        let dir = TempDir()
        let path = dir.write("r.jsonl", Self.numbered(2000))
        let fs = CountingFileSystem()
        let r = try #require(BackwardScanner.scan(fs, path: path, chunk: 64, budget: 256, maxLineBytes: 1000) { _ in false })
        #expect(r.exhausted)
        #expect(!r.reachedStart)
        #expect(fs.bytesRead <= 256 + 64)
        #expect(r.lines.last?.text == "{\"i\":2000}")
    }

    @Test func oversizeLineBecomesPrefix() throws {
        let dir = TempDir()
        let big = "{\"type\":\"compacted\",\"payload\":\"" + String(repeating: "x", count: 5000) + "\"}"
        let path = dir.write("r.jsonl", "{\"i\":1}\n" + big + "\n{\"i\":3}\n")
        let r = try #require(BackwardScanner.scan(LiveFileSystem(), path: path, chunk: 100, budget: 1 << 20,
                                                   maxLineBytes: 1000, prefixBytes: 40) { _ in false })
        #expect(r.lines.count == 3)
        guard case let .oversize(prefix, total) = r.lines[1] else {
            Issue.record("expected oversize")
            return
        }
        #expect(total == big.utf8.count)
        #expect(String(decoding: prefix, as: UTF8.self).hasPrefix("{\"type\":\"compacted\""))
        #expect(r.lines[2].text == "{\"i\":3}")
    }

    @Test(.tags(.slow)) func hugeSparseFileReadsOnlyTheBudget() throws {
        let dir = TempDir()
        let path = dir.write("huge.jsonl", "")
        let handle = try #require(FileHandle(forWritingAtPath: path))
        try handle.truncate(atOffset: 450 * 1024 * 1024)
        try handle.seekToEnd()
        handle.write(Data(("\n" + Self.numbered(100, marker: 60)).utf8))
        try handle.close()

        let fs = CountingFileSystem()
        let r = try #require(BackwardScanner.scan(fs, path: path, budget: 8 << 20, maxLineBytes: 1 << 20) {
            $0.text.contains("task_started")
        })
        #expect(r.reachedStop)
        #expect(r.lines.count == 41)
        #expect(fs.bytesRead <= (8 << 20) + (256 * 1024))
    }
}

extension Tag {
    @Tag static var slow: Self
}

@Suite("JSONSniff")
struct JSONSniffTests {
    @Test func codexKindsFromPrefix() {
        let line = Data(#"{"timestamp":"2026-09-19T06:09:04Z","ordinal":12,"type":"response_item","payload":{"type":"function_call_output","call_id":"call_\"abc","output":"…"#.utf8)
        let kinds = JSONSniff.codexKinds(line)
        #expect(kinds.type == "response_item")
        #expect(kinds.payloadType == "function_call_output")
        #expect(JSONSniff.string("call_id", in: line) == "call_\"abc")
        #expect(JSONSniff.string("missing", in: line) == nil)
    }

    @Test func unterminatedStringIsNil() {
        #expect(JSONSniff.string("a", in: Data(#"{"a":"abc"#.utf8)) == nil)
        #expect(JSONSniff.string("a", in: Data(#"{"a" : "xAy"}"#.utf8)) == "xAy")
    }
}

@Suite("TextSanitizer")
struct TextSanitizerTests {
    @Test func oneLineCollapsesWhitespaceAndStripsANSI() {
        let s = TextSanitizer.oneLine("  npm\n\ttest \u{1B}[31mred\u{1B}[0m  done ")
        #expect(s == "npm test red done")
    }

    @Test func truncatesWithEllipsis() {
        let s = TextSanitizer.oneLine(String(repeating: "a", count: 200), maxLength: 10)
        #expect(s.count == 10)
        #expect(s.hasSuffix("…"))
    }

    @Test(arguments: [
        "curl -H 'Authorization: Bearer abcdefghijklmnop.qrs' https://x",
        "export ANTHROPIC_API_KEY=sk-ant-api03-FAKEFAKEFAKEFAKE",
        "gh auth login --token ghp_FAKEFAKEFAKEFAKEFAKEFAKE1234",
        "SECRET_TOKEN=supersecretvalue123 ./run.sh",
        "token eyJhbGciOiJIUzI1NiJ9.eyJmYWtlIjp0cnVlfQ.c2lnbmF0dXJlZmFrZQ",
        "mysql --password hunter2hunter2 db",
    ])
    func redactsSecrets(input: String) {
        let out = TextSanitizer.oneLine(input, maxLength: 200)
        #expect(out.contains("‹redacted›"), "\(out)")
        for secret in ["abcdefghijklmnop", "FAKEFAKEFAKEFAKE", "supersecretvalue123", "c2lnbmF0dXJlZmFrZQ", "hunter2hunter2"] {
            #expect(!out.contains(secret), "\(out)")
        }
    }

    @Test func leavesOrdinaryTextAlone() {
        #expect(TextSanitizer.oneLine("Running Bash: swift test --filter Tokenizer") == "Running Bash: swift test --filter Tokenizer")
    }

    @Test func secretTokenNeverPrints() {
        let t = SecretToken("sk-ant-oat01-FAKE-VALUE")
        #expect(!String(describing: t).contains("FAKE"))
        #expect(!String(reflecting: t).contains("FAKE"))
        var dumped = ""
        dump(t, to: &dumped)
        #expect(!dumped.contains("FAKE"))
        #expect(t.withValue { $0 } == "sk-ant-oat01-FAKE-VALUE")
    }
}

@Suite("SQLiteReadOnly")
struct SQLiteReadOnlyTests {
    @Test func immutableOpenCreatesNoSideFiles() throws {
        let dir = TempDir()
        let path = dir.url("state_5.sqlite")
        let setup = Process()
        setup.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        setup.arguments = [path, "CREATE TABLE threads(id TEXT, title TEXT); INSERT INTO threads VALUES('t1','Hello');"]
        try setup.run()
        setup.waitUntilExit()
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))

        let db = try #require(SQLiteReadOnly.open(path))
        #expect(db.tableExists("threads"))
        #expect(db.columns(of: "threads") == ["id", "title"])
        let rows = try #require(db.query("SELECT id, title FROM threads WHERE id = ?", [.text("t1")]))
        #expect(rows.first?["title"]?.string == "Hello")

        let after = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(before == after)
    }

    @Test func missingDatabaseIsNil() {
        #expect(SQLiteReadOnly.open("/nonexistent/state.sqlite") == nil)
    }
}
