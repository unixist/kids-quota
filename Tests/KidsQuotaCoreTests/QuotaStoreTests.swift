import XCTest
import CSQLite
@testable import KidsQuotaCore

final class QuotaStoreTests: XCTestCase {
    func testPolicyRoundtripPreservesOptionalBindings() throws {
        let store = try QuotaStore(path: ":memory:")
        XCTAssertNil(try store.loadPolicy())
        let policy = fixturePolicy()
        try store.savePolicy(policy)
        XCTAssertEqual(try store.loadPolicy(), policy)
    }

    func testInvalidBatchWritesNothing() throws {
        let store = try QuotaStore(path: ":memory:")
        let period = instant("2026-10-19T00:00:00Z")
        XCTAssertThrowsError(try store.addUsage([
            .init(childId: "alice", quotaId: "a-chess", periodStart: period, seconds: 10),
            .init(childId: "alice", quotaId: "a-chess", periodStart: period, seconds: -.infinity)
        ]))
        XCTAssertEqual(try store.usageSeconds(childId: "alice", quotaId: "a-chess", periodStart: period), 0)
    }

    func testInvalidPolicyRollsBackCountersAndMetadata() throws {
        let store = try QuotaStore(path: ":memory:")
        let period = instant("2026-10-19T00:00:00Z")
        var invalid = fixturePolicy(); invalid.schemaVersion = 99
        XCTAssertThrowsError(try store.recordUsage([.init(childId: "alice", quotaId: "a-chess", periodStart: period, seconds: 10)], periodFloor: period, policy: invalid))
        XCTAssertNil(try store.periodFloor())
        XCTAssertEqual(try store.usageSeconds(childId: "alice", quotaId: "a-chess", periodStart: period), 0)
    }

    func testRestartRestoresLedgerButNeverBillsDowntime() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kids-quota-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("usage.sqlite").path
        let start = instant("2026-10-21T12:00:00Z")
        do {
            let store = try QuotaStore(path: path)
            let engine = try QuotaEngine(store: store, policy: fixturePolicy())
            try engine.reportActivity(childId: "alice", serviceId: "chesscom", sessionId: "web", sequence: 1, isActive: true, now: start, monotonic: 0)
            try engine.tick(now: start.addingTimeInterval(10), monotonic: 10)
        }
        let store = try QuotaStore(path: path)
        let engine = try QuotaEngine(store: store, policy: XCTUnwrap(store.loadPolicy()))
        let result = try engine.balances(childId: "alice", now: start.addingTimeInterval(3600), monotonic: 0)
        XCTAssertEqual(result.items[0].usedSeconds, 10)
        let rollback = try engine.balances(childId: "alice", now: start.addingTimeInterval(-604800), monotonic: 1)
        XCTAssertEqual(rollback.items[0].usedSeconds, 10)
    }

    func testPeriodFloorOnlyAdvances() throws {
        let store = try QuotaStore(path: ":memory:")
        let period = instant("2026-10-19T00:00:00Z")
        try store.recordUsage([], periodFloor: period)
        try store.recordUsage([], periodFloor: period.addingTimeInterval(-604800))
        XCTAssertEqual(try store.periodFloor(), period)
    }

    func testFailedExpiredLeaseCommitRetriesItsUncommittedUsageExactlyOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kids-quota-tick-failure-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("quota.sqlite").path
        let store = try QuotaStore(path: path)
        let engine = try QuotaEngine(store: store, policy: fixturePolicy())
        let start = instant("2026-10-21T12:00:00Z")
        let week = instant("2026-10-19T00:00:00Z")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        try engine.reportActivity(childId: "alice", serviceId: "chesscom", sessionId: "web", sequence: 1, isActive: true, now: start, monotonic: 0)
        XCTAssertEqual(sqlite3_exec(database, "CREATE TRIGGER reject_usage BEFORE INSERT ON usage BEGIN SELECT RAISE(ABORT,'simulated disk failure'); END", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try engine.tick(now: start.addingTimeInterval(20), monotonic: 20))
        XCTAssertEqual(try store.usageSeconds(childId: "alice", quotaId: "a-chess", periodStart: week), 0)
        XCTAssertEqual(sqlite3_exec(database, "DROP TRIGGER reject_usage", nil, nil, nil), SQLITE_OK)

        try engine.tick(now: start.addingTimeInterval(25), monotonic: 25)
        XCTAssertEqual(try store.usageSeconds(childId: "alice", quotaId: "a-chess", periodStart: week), 15,
                       "A transient write failure must not discard already-observed usage when the lease expires.")
        try engine.tick(now: start.addingTimeInterval(30), monotonic: 30)
        XCTAssertEqual(try store.usageSeconds(childId: "alice", quotaId: "a-chess", periodStart: week), 15,
                       "Retry must neither renew an expired lease nor double-charge the successful commit.")
    }

    func testFailedRolloverCommitRestoresScheduleAndBothWeeksBeforeRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kids-quota-rollover-failure-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("quota.sqlite").path
        let store = try QuotaStore(path: path)
        let engine = try QuotaEngine(store: store, policy: fixturePolicy())
        let oldWeek = instant("2026-10-19T00:00:00Z")
        let boundary = instant("2026-10-26T00:00:00Z")
        let start = boundary.addingTimeInterval(-5)
        let scheduled = try engine.setResetSchedule(.init(weekday: "wednesday", timeZone: "UTC"), expectedRevision: 0, now: start, monotonic: 0)
        try engine.reportActivity(childId: "alice", serviceId: "chesscom", sessionId: "web", sequence: 1, isActive: true, now: start, monotonic: 0)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        // Fail on the second week, after the previous week's insert succeeded
        // inside the transaction. Neither week nor the new schedule may commit.
        let trigger = "CREATE TRIGGER reject_new_week BEFORE INSERT ON usage WHEN NEW.period_start >= \(boundary.timeIntervalSince1970) BEGIN SELECT RAISE(ABORT,'simulated rollover failure'); END"
        XCTAssertEqual(sqlite3_exec(database, trigger, nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try engine.tick(now: start.addingTimeInterval(20), monotonic: 20))
        XCTAssertEqual(engine.policy, scheduled)
        XCTAssertEqual(try store.loadPolicy(), scheduled)
        XCTAssertEqual(try store.periodFloor(), oldWeek)
        for week in [oldWeek, boundary] {
            XCTAssertEqual(try store.usageSeconds(childId: "alice", quotaId: "a-chess", periodStart: week), 0)
        }
        XCTAssertEqual(sqlite3_exec(database, "DROP TRIGGER reject_new_week", nil, nil, nil), SQLITE_OK)

        let recovered = try engine.balances(childId: "alice", now: start.addingTimeInterval(25), monotonic: 25)
        XCTAssertEqual(recovered.items[0].usedSeconds, 10)
        XCTAssertEqual(try store.usageSeconds(childId: "alice", quotaId: "a-chess", periodStart: oldWeek), 5)
        XCTAssertEqual(recovered.items[0].periodStart, boundary)
        XCTAssertEqual(recovered.items[0].periodEnd, instant("2026-10-28T00:00:00Z"))
        XCTAssertEqual(engine.policy.revision, scheduled.revision + 1)
        XCTAssertNil(engine.policy.pendingReset)
        XCTAssertEqual(try store.loadPolicy(), engine.policy)
        XCTAssertEqual(try store.periodFloor(), boundary)
    }
}
