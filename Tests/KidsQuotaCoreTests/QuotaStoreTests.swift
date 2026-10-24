import XCTest
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
}
