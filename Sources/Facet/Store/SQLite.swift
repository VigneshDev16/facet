import Foundation
import SQLite3
import CoreGraphics

let SQLITE_TRANSIENT_ = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLError: Error, CustomStringConvertible {
    case open(String), prepare(String, String), step(String, String)
    var description: String {
        switch self {
        case .open(let m): return "sqlite open: \(m)"
        case .prepare(let m, let sql): return "sqlite prepare: \(m) — \(sql)"
        case .step(let m, let sql): return "sqlite step: \(m) — \(sql)"
        }
    }
}

/// Minimal value type for binding.
enum SQLValue {
    case int(Int64), double(Double), text(String), blob(Data), null
}

protocol SQLBindable { var sqlValue: SQLValue { get } }
extension Int: SQLBindable { var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLBindable { var sqlValue: SQLValue { .int(self) } }
extension Int32: SQLBindable { var sqlValue: SQLValue { .int(Int64(self)) } }
extension Double: SQLBindable { var sqlValue: SQLValue { .double(self) } }
extension Float: SQLBindable { var sqlValue: SQLValue { .double(Double(self)) } }
extension Bool: SQLBindable { var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension String: SQLBindable { var sqlValue: SQLValue { .text(self) } }
extension Data: SQLBindable { var sqlValue: SQLValue { .blob(self) } }
extension CGFloat: SQLBindable { var sqlValue: SQLValue { .double(Double(self)) } }

/// A prepared statement with ergonomic column readers.
final class Statement {
    fileprivate var handle: OpaquePointer?
    private let sql: String

    init(db: OpaquePointer?, sql: String) throws {
        self.sql = sql
        guard sqlite3_prepare_v2(db, sql, -1, &handle, nil) == SQLITE_OK else {
            throw SQLError.prepare(String(cString: sqlite3_errmsg(db)), sql)
        }
    }
    deinit { sqlite3_finalize(handle) }

    @discardableResult
    func bind(_ values: [SQLBindable?]) -> Statement {
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            switch v?.sqlValue ?? .null {
            case .null: sqlite3_bind_null(handle, idx)
            case .int(let n): sqlite3_bind_int64(handle, idx, n)
            case .double(let d): sqlite3_bind_double(handle, idx, d)
            case .text(let s): sqlite3_bind_text(handle, idx, s, -1, SQLITE_TRANSIENT_)
            case .blob(let d):
                if d.isEmpty { sqlite3_bind_zeroblob(handle, idx, 0) }
                else { d.withUnsafeBytes { sqlite3_bind_blob(handle, idx, $0.baseAddress, Int32(d.count), SQLITE_TRANSIENT_) } }
            }
        }
        return self
    }

    /// Advances one row. Returns false when the result set is exhausted.
    func step() throws -> Bool {
        let rc = sqlite3_step(handle)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        throw SQLError.step(String(cString: sqlite3_errmsg(sqlite3_db_handle(handle))), sql)
    }

    func reset() { sqlite3_reset(handle); sqlite3_clear_bindings(handle) }

    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(handle, i) }
    func intOpt(_ i: Int32) -> Int64? { isNull(i) ? nil : sqlite3_column_int64(handle, i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(handle, i) }
    func doubleOpt(_ i: Int32) -> Double? { isNull(i) ? nil : sqlite3_column_double(handle, i) }
    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(handle, i) == SQLITE_NULL }
    func string(_ i: Int32) -> String {
        guard let c = sqlite3_column_text(handle, i) else { return "" }
        return String(cString: c)
    }
    func stringOpt(_ i: Int32) -> String? { isNull(i) ? nil : string(i) }
    func blob(_ i: Int32) -> Data {
        guard let p = sqlite3_column_blob(handle, i) else { return Data() }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(handle, i)))
    }
}

/// Serialized SQLite connection. All access funnels through `sync`.
final class SQLiteDB: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw SQLError.open(msg)
        }
        db = handle
        sqlite3_busy_timeout(db, 5000)
        try? exec("PRAGMA journal_mode=WAL;")
        try? exec("PRAGMA synchronous=NORMAL;")
        try? exec("PRAGMA foreign_keys=ON;")
        try? exec("PRAGMA temp_store=MEMORY;")
        try? exec("PRAGMA cache_size=-64000;")   // ~64 MB page cache
        try? exec("PRAGMA mmap_size=268435456;") // 256 MB
    }
    deinit { sqlite3_close_v2(db) }

    func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    func exec(_ sql: String) throws {
        try sync {
            var err: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
                let m = err.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(err)
                throw SQLError.step(m, sql)
            }
        }
    }

    func prepare(_ sql: String) throws -> Statement { try sync { try Statement(db: db, sql: sql) } }

    /// Runs a statement that returns no rows.
    func run(_ sql: String, _ values: [SQLBindable?] = []) throws {
        try sync {
            let st = try Statement(db: db, sql: sql)
            st.bind(values)
            while try st.step() {}
        }
    }

    /// Runs a query, invoking `row` for each result row.
    func query(_ sql: String, _ values: [SQLBindable?] = [], _ row: (Statement) throws -> Void) throws {
        try sync {
            let st = try Statement(db: db, sql: sql)
            st.bind(values)
            while try st.step() { try row(st) }
        }
    }

    func scalarInt(_ sql: String, _ values: [SQLBindable?] = []) -> Int64 {
        var out: Int64 = 0
        try? query(sql, values) { out = $0.int(0) }
        return out
    }

    var lastInsertRowID: Int64 { sync { sqlite3_last_insert_rowid(db) } }

    /// Wraps `body` in a transaction, rolling back on throw.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try sync {
            try exec("BEGIN IMMEDIATE;")
            do {
                let r = try body()
                try exec("COMMIT;")
                return r
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }
}
