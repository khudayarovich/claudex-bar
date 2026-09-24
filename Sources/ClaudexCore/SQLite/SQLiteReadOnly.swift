import Foundation
import SQLite3

public enum SQLiteValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)

    public var string: String? {
        switch self {
        case let .text(s): return s
        case let .integer(i): return String(i)
        case let .real(d): return String(d)
        case .null: return nil
        }
    }

    public var int64: Int64? {
        switch self {
        case let .integer(i): return i
        case let .real(d): return Int64(d)
        case let .text(s): return Int64(s)
        case .null: return nil
        }
    }

    public var bool: Bool? { int64.map { $0 != 0 } }
}

/// Strictly passive read-only access to another tool's SQLite database.
///
/// A plain `mode=ro` open of a WAL database creates a `-shm` file, so when no `-wal` exists
/// the database is opened with `immutable=1` (no locks, no side files).
public final class SQLiteReadOnly {
    private var db: OpaquePointer?

    public static func open(_ path: String, fs: FileSystemReading = LiveFileSystem()) -> SQLiteReadOnly? {
        guard fs.stat(path)?.isRegular == true else { return nil }
        let hasWal = fs.stat(path + "-wal") != nil
        let hasShm = fs.stat(path + "-shm") != nil
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let candidates: [String]
        if !hasWal {
            candidates = ["file:\(encoded)?immutable=1"]
        } else if hasShm {
            candidates = ["file:\(encoded)?mode=ro", "file:\(encoded)?immutable=1"]
        } else {
            candidates = ["file:\(encoded)?immutable=1"]
        }
        for uri in candidates {
            var handle: OpaquePointer?
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
            if sqlite3_open_v2(uri, &handle, flags, nil) == SQLITE_OK, let handle {
                sqlite3_busy_timeout(handle, 200)
                let db = SQLiteReadOnly(handle)
                _ = db.query("PRAGMA query_only=1")
                // Verify the connection can actually read the schema.
                if db.query("SELECT count(*) AS n FROM sqlite_master") != nil { return db }
            } else if let handle {
                sqlite3_close_v2(handle)
            }
        }
        return nil
    }

    private init(_ handle: OpaquePointer) { db = handle }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    public func tableExists(_ name: String) -> Bool {
        (query("SELECT name FROM sqlite_master WHERE type='table' AND name=?", [.text(name)])?.isEmpty == false)
    }

    public func columns(of table: String) -> Set<String> {
        guard table.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return [] }
        let rows = query("PRAGMA table_info(\(table))") ?? []
        return Set(rows.compactMap { $0["name"]?.string })
    }

    /// Runs a query and returns rows as column-name dictionaries, or nil on error.
    public func query(_ sql: String, _ bindings: [SQLiteValue] = []) -> [[String: SQLiteValue]]? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in bindings.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case .null: sqlite3_bind_null(stmt, idx)
            case let .integer(v): sqlite3_bind_int64(stmt, idx, v)
            case let .real(v): sqlite3_bind_double(stmt, idx, v)
            case let .text(v): sqlite3_bind_text(stmt, idx, v, -1, transient)
            }
        }
        var rows: [[String: SQLiteValue]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { return rows.isEmpty ? nil : rows }
            var row: [String: SQLiteValue] = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(stmt, c) { row[name] = .text(String(cString: text)) }
                    else { row[name] = .null }
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }
}
