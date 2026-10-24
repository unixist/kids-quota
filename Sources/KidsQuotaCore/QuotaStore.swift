import Foundation
import CSQLite

public struct UsageIncrement {
    public var childId: String
    public var quotaId: String
    public var periodStart: Date
    public var seconds: Double
    public init(childId: String, quotaId: String, periodStart: Date, seconds: Double) {
        self.childId = childId; self.quotaId = quotaId; self.periodStart = periodStart; self.seconds = seconds
    }
}

// Administrative audit stays in the protected database, outside public balances.
struct UsageResetRecord: Equatable {
    var occurredAt: Date
    var actorUID: UInt32
    var childId: String
    var periodStart: Date
    var priorSeconds: Double
    var policyRevision: Int
}

/// Caller-serialized SQLite store. Counters and policy metadata are written in a
/// single transaction; SQLite WAL and FULL synchronization provide crash recovery.
public final class QuotaStore {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        if path != ":memory:" {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            defer { sqlite3_close(db); db = nil }
            throw QuotaError.persistence("Unable to open database.")
        }
        sqlite3_busy_timeout(db, 3000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=FULL")
        try execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value BLOB NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS usage (child_id TEXT NOT NULL, quota_id TEXT NOT NULL, period_start REAL NOT NULL, seconds REAL NOT NULL CHECK(seconds >= 0), PRIMARY KEY(child_id, quota_id, period_start))")
        try execute("CREATE TABLE IF NOT EXISTS reset_events (id INTEGER PRIMARY KEY AUTOINCREMENT, occurred_at REAL NOT NULL, actor_uid INTEGER NOT NULL CHECK(actor_uid >= 0), child_id TEXT NOT NULL, period_start REAL NOT NULL, prior_seconds REAL NOT NULL CHECK(prior_seconds >= 0), policy_revision INTEGER NOT NULL UNIQUE)")
        if path != ":memory:" {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }

    deinit { sqlite3_close(db) }

    private func error() -> QuotaError { .persistence(db.map { String(cString: sqlite3_errmsg($0)) } ?? "Database closed.") }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    private func statement(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw error() }
        return stmt
    }

    private func bind(_ string: String, _ index: Int32, _ stmt: OpaquePointer) { sqlite3_bind_text(stmt, index, string, -1, transient) }

    private func metadata(_ key: String) throws -> Data? {
        let stmt = try statement("SELECT value FROM metadata WHERE key=?")
        defer { sqlite3_finalize(stmt) }
        bind(key, 1, stmt)
        let result = sqlite3_step(stmt)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw error() }
        let count = Int(sqlite3_column_bytes(stmt, 0))
        guard let bytes = sqlite3_column_blob(stmt, 0), count > 0 else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private func setMetadata(_ key: String, _ value: Data) throws {
        let stmt = try statement("INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value")
        defer { sqlite3_finalize(stmt) }
        bind(key, 1, stmt)
        _ = value.withUnsafeBytes { bytes in sqlite3_bind_blob(stmt, 2, bytes.baseAddress, Int32(bytes.count), transient) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }

    public func loadPolicy() throws -> Policy? {
        guard let data = try metadata("policy") else { return nil }
        return try JSONDecoder().decode(Policy.self, from: data)
    }

    public func savePolicy(_ policy: Policy) throws {
        try policy.validate()
        try setMetadata("policy", JSONEncoder().encode(policy))
    }

    public func periodFloor() throws -> Date? {
        guard let data = try metadata("periodFloor") else { return nil }
        return try JSONDecoder().decode(Date.self, from: data)
    }

    public func usageSeconds(childId: String, quotaId: String, periodStart: Date) throws -> Double {
        let stmt = try statement("SELECT seconds FROM usage WHERE child_id=? AND quota_id=? AND period_start=?")
        defer { sqlite3_finalize(stmt) }
        bind(childId, 1, stmt); bind(quotaId, 2, stmt)
        sqlite3_bind_double(stmt, 3, periodStart.timeIntervalSince1970)
        let result = sqlite3_step(stmt)
        if result == SQLITE_DONE { return 0 }
        guard result == SQLITE_ROW else { throw error() }
        return sqlite3_column_double(stmt, 0)
    }

    public func recordUsage(_ increments: [UsageIncrement], periodFloor: Date?, policy: Policy? = nil) throws {
        for item in increments where !item.seconds.isFinite || item.seconds < 0 { throw QuotaError.invalidPolicy("Invalid usage duration.") }
        try execute("BEGIN IMMEDIATE")
        do {
            for item in increments where item.seconds > 0 {
                let stmt = try statement("INSERT INTO usage(child_id,quota_id,period_start,seconds) VALUES(?,?,?,?) ON CONFLICT(child_id,quota_id,period_start) DO UPDATE SET seconds=seconds+excluded.seconds")
                defer { sqlite3_finalize(stmt) }
                bind(item.childId, 1, stmt); bind(item.quotaId, 2, stmt)
                sqlite3_bind_double(stmt, 3, item.periodStart.timeIntervalSince1970)
                sqlite3_bind_double(stmt, 4, item.seconds)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
            }
            if let periodFloor {
                let previous = try self.periodFloor()
                if previous == nil || previous! < periodFloor { try setMetadata("periodFloor", JSONEncoder().encode(periodFloor)) }
            }
            if let policy { try savePolicy(policy) }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func addUsage(_ increments: [UsageIncrement]) throws { try recordUsage(increments, periodFloor: nil) }

    /// Reset counters, audit the prior total, and advance policy as one commit.
    /// The caller has already settled observed activity up to occurredAt.
    func resetUsage(childId: String, periodStart: Date, actorUID: UInt32, occurredAt: Date,
                    expectedRevision: Int, policy: Policy) throws {
        guard periodStart.timeIntervalSince1970.isFinite, occurredAt.timeIntervalSince1970.isFinite,
              expectedRevision >= 0, expectedRevision < Int.max, policy.revision == expectedRevision + 1 else {
            throw QuotaError.invalidPolicy("Invalid usage reset.")
        }
        try execute("BEGIN IMMEDIATE")
        do {
            guard try loadPolicy()?.revision == expectedRevision else { throw QuotaError.conflict }
            guard policy.children.contains(where: { $0.id == childId }) else { throw QuotaError.unknownChild }
            let total = try statement("SELECT COALESCE(SUM(seconds),0) FROM usage WHERE child_id=? AND period_start=?")
            defer { sqlite3_finalize(total) }
            bind(childId, 1, total); sqlite3_bind_double(total, 2, periodStart.timeIntervalSince1970)
            guard sqlite3_step(total) == SQLITE_ROW else { throw error() }
            let prior = sqlite3_column_double(total, 0)
            guard prior.isFinite, prior >= 0 else { throw QuotaError.persistence("Invalid stored usage total.") }

            let reset = try statement("UPDATE usage SET seconds=0 WHERE child_id=? AND period_start=?")
            defer { sqlite3_finalize(reset) }
            bind(childId, 1, reset); sqlite3_bind_double(reset, 2, periodStart.timeIntervalSince1970)
            guard sqlite3_step(reset) == SQLITE_DONE else { throw error() }

            let audit = try statement("INSERT INTO reset_events(occurred_at,actor_uid,child_id,period_start,prior_seconds,policy_revision) VALUES(?,?,?,?,?,?)")
            defer { sqlite3_finalize(audit) }
            sqlite3_bind_double(audit, 1, occurredAt.timeIntervalSince1970)
            sqlite3_bind_int64(audit, 2, Int64(actorUID)); bind(childId, 3, audit)
            sqlite3_bind_double(audit, 4, periodStart.timeIntervalSince1970)
            sqlite3_bind_double(audit, 5, prior); sqlite3_bind_int64(audit, 6, Int64(policy.revision))
            guard sqlite3_step(audit) == SQLITE_DONE else { throw error() }
            try savePolicy(policy)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func resetAuditEvents() throws -> [UsageResetRecord] {
        let query = try statement("SELECT occurred_at,actor_uid,child_id,period_start,prior_seconds,policy_revision FROM reset_events ORDER BY id")
        defer { sqlite3_finalize(query) }
        var events: [UsageResetRecord] = []
        while true {
            let result = sqlite3_step(query)
            if result == SQLITE_DONE { return events }
            guard result == SQLITE_ROW, let child = sqlite3_column_text(query, 2),
                  let actor = UInt32(exactly: sqlite3_column_int64(query, 1)) else { throw error() }
            events.append(.init(occurredAt: Date(timeIntervalSince1970: sqlite3_column_double(query, 0)), actorUID: actor,
                                childId: String(cString: child), periodStart: Date(timeIntervalSince1970: sqlite3_column_double(query, 3)),
                                priorSeconds: sqlite3_column_double(query, 4), policyRevision: Int(sqlite3_column_int64(query, 5))))
        }
    }
}
