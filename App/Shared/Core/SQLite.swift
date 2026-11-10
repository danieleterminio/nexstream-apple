import Foundation
import SQLite3

struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String
    var description: String { "sqlite \(code): \(message)" }
}

private let SQLITE_TRANSIENT_NX = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One row of a result set, read by column index (the SELECT lists are written out in full, in the order of the fields).
struct SQLRow {
    fileprivate let stmt: OpaquePointer

    func isNull(_ i: Int) -> Bool { sqlite3_column_type(stmt, Int32(i)) == SQLITE_NULL }
    func string(_ i: Int) -> String { sqlite3_column_text(stmt, Int32(i)).map { String(cString: $0) } ?? "" }
    func stringOrNil(_ i: Int) -> String? { isNull(i) ? nil : string(i) }
    func int(_ i: Int) -> Int { Int(sqlite3_column_int64(stmt, Int32(i))) }
    func intOrNil(_ i: Int) -> Int? { isNull(i) ? nil : int(i) }
    func int64(_ i: Int) -> Int64 { sqlite3_column_int64(stmt, Int32(i)) }
    func int64OrNil(_ i: Int) -> Int64? { isNull(i) ? nil : int64(i) }
    func double(_ i: Int) -> Double { sqlite3_column_double(stmt, Int32(i)) }
    func bool(_ i: Int) -> Bool { sqlite3_column_int64(stmt, Int32(i)) != 0 }
}

/// A small, thread-safe SQLite connection: every call takes one recursive lock, so a transaction can call the same
/// methods from inside its closure. Statements are prepared per call and cached by their SQL text.
final class SQLiteDB {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var cache = [String: OpaquePointer]()
    let path: String

    init(path: String) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        if rc != SQLITE_OK {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            throw SQLiteError(code: rc, message: msg)
        }
        sqlite3_busy_timeout(db, 5000)
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=OFF;")
    }

    deinit {
        for (_, s) in cache { sqlite3_finalize(s) }
        if let db = db { sqlite3_close_v2(db) }
    }

    private func fail(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc, message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "?")
    }

    /// Runs one or more statements without parameters (schema, pragmas).
    func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError(code: rc, message: msg)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        if let s = cache[sql] { sqlite3_reset(s); sqlite3_clear_bindings(s); return s }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let s = stmt else { throw fail(rc) }
        if cache.count > 200 { for (_, old) in cache { sqlite3_finalize(old) }; cache.removeAll() }
        cache[sql] = s
        return s
    }

    private func bind(_ stmt: OpaquePointer, _ args: [Any?]) throws {
        for (n, a) in args.enumerated() {
            let i = Int32(n + 1)
            var rc: Int32 = SQLITE_OK
            switch a {
            case nil: rc = sqlite3_bind_null(stmt, i)
            case let v as String: rc = sqlite3_bind_text(stmt, i, v, -1, SQLITE_TRANSIENT_NX)
            case let v as Bool: rc = sqlite3_bind_int64(stmt, i, v ? 1 : 0)
            case let v as Int: rc = sqlite3_bind_int64(stmt, i, Int64(v))
            case let v as Int64: rc = sqlite3_bind_int64(stmt, i, v)
            case let v as Int32: rc = sqlite3_bind_int64(stmt, i, Int64(v))
            case let v as Double: rc = sqlite3_bind_double(stmt, i, v)
            case let v as Float: rc = sqlite3_bind_double(stmt, i, Double(v))
            default: rc = sqlite3_bind_text(stmt, i, String(describing: a!), -1, SQLITE_TRANSIENT_NX)
            }
            if rc != SQLITE_OK { throw fail(rc) }
        }
    }

    /// INSERT / UPDATE / DELETE. Returns the number of rows changed.
    @discardableResult
    func run(_ sql: String, _ args: [Any?] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let s = try prepare(sql)
        try bind(s, args)
        let rc = sqlite3_step(s)
        sqlite3_reset(s)
        if rc != SQLITE_DONE && rc != SQLITE_ROW { throw fail(rc) }
        return Int(sqlite3_changes(db))
    }

    /// INSERT returning the new row id.
    func insert(_ sql: String, _ args: [Any?] = []) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        try run(sql, args)
        return sqlite3_last_insert_rowid(db)
    }

    func query<T>(_ sql: String, _ args: [Any?] = [], _ map: (SQLRow) -> T) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        let s = try prepare(sql)
        try bind(s, args)
        var out = [T]()
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_ROW { out.append(map(SQLRow(stmt: s))) }
            else if rc == SQLITE_DONE { break }
            else { sqlite3_reset(s); throw fail(rc) }
        }
        sqlite3_reset(s)
        return out
    }

    func first<T>(_ sql: String, _ args: [Any?] = [], _ map: (SQLRow) -> T) throws -> T? {
        try query(sql, args, map).first
    }

    /// Single value helpers.
    func scalarInt(_ sql: String, _ args: [Any?] = []) throws -> Int { (try first(sql, args) { $0.int(0) }) ?? 0 }
    func scalarInt64OrNil(_ sql: String, _ args: [Any?] = []) throws -> Int64? { (try first(sql, args) { $0.int64OrNil(0) }) ?? nil }
    func scalarString(_ sql: String, _ args: [Any?] = []) throws -> String? { (try first(sql, args) { $0.stringOrNil(0) }) ?? nil }

    /// Everything inside happens or nothing does.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do {
            let r = try body()
            try exec("COMMIT")
            return r
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    var userVersion: Int {
        get { (try? scalarInt("PRAGMA user_version")) ?? 0 }
        set { try? exec("PRAGMA user_version = \(newValue)") }
    }
}
