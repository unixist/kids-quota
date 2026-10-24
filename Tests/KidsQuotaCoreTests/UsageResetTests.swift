import XCTest
import CSQLite
@testable import KidsQuotaCore

final class UsageResetTests: XCTestCase {
    private let now = instant("2026-10-21T12:00:00Z")
    private let week = instant("2026-10-19T00:00:00Z")

    private func engine() throws -> QuotaEngine {
        try QuotaEngine(store: QuotaStore(path: ":memory:"), policy: fixturePolicy())
    }
    private func add(_ engine: QuotaEngine, child: String = "alice", quota: String = "a-chess", seconds: Double, period: Date? = nil) throws {
        try engine.store.addUsage([.init(childId: child, quotaId: quota, periodStart: period ?? week, seconds: seconds)])
    }
    private func usage(_ engine: QuotaEngine, child: String = "alice", quota: String = "a-chess", period: Date? = nil) throws -> Double {
        try engine.store.usageSeconds(childId: child, quotaId: quota, periodStart: period ?? week)
    }

    func testResetRestoresAllCurrentWeekAllowancesAndRecordsPrivateAudit() throws {
        let engine = try engine()
        try add(engine, seconds: 21_600)
        try add(engine, quota: "a-chat", seconds: 12.75)
        XCTAssertEqual(try engine.balances(childId: "alice", now: now, monotonic: 0).items[0].quotaState, "exhausted")
        let revised = try engine.resetUsage(childId: "alice", expectedRevision: 0, actorUID: 501, now: now, monotonic: 0)
        let balance = try engine.balances(childId: "alice", now: now, monotonic: 0)
        XCTAssertEqual(revised.revision, 1)
        XCTAssertEqual(balance.policyRevision, 1)
        XCTAssertEqual(balance.items.map(\.usedSeconds), [0, 0])
        XCTAssertEqual(balance.items.map(\.remainingSeconds), [21_600, 21_600])
        let audit = try XCTUnwrap(engine.store.resetAuditEvents().first)
        XCTAssertEqual(audit.occurredAt, now)
        XCTAssertEqual(audit.actorUID, 501)
        XCTAssertEqual(audit.childId, "alice")
        XCTAssertEqual(audit.periodStart, week)
        XCTAssertEqual(audit.priorSeconds, 21_612.75)
        XCTAssertEqual(audit.policyRevision, 1)
    }

    func testResetPreservesSiblingsPriorPeriodsAndPendingResetSchedule() throws {
        let engine = try engine()
        let oldWeek = week.addingTimeInterval(-604_800)
        try add(engine, seconds: 20)
        try add(engine, child: "bob", quota: "b-chess", seconds: 30)
        try add(engine, seconds: 40, period: oldWeek)
        var changed = engine.policy; changed.reset.weekday = "friday"
        let scheduled = try engine.replacePolicy(changed, expectedRevision: 0, now: now, monotonic: 0)
        let revised = try engine.resetUsage(childId: "alice", expectedRevision: scheduled.revision, actorUID: 501, now: now, monotonic: 0)
        XCTAssertEqual(try usage(engine), 0)
        XCTAssertEqual(try usage(engine, child: "bob", quota: "b-chess"), 30)
        XCTAssertEqual(try usage(engine, period: oldWeek), 40)
        XCTAssertEqual(revised.reset, scheduled.reset)
        XCTAssertEqual(revised.pendingReset, scheduled.pendingReset)
        XCTAssertEqual(revised.quotas, scheduled.quotas)
        XCTAssertEqual(try engine.store.periodFloor(), week)
    }

    func testActiveUsageIsSettledThenContinuesFromResetInstantWithoutRebilling() throws {
        let engine = try engine()
        try engine.reportActivity(childId: "alice", serviceId: "chesscom", sessionId: "web", sequence: 1, isActive: true, now: now, monotonic: 0)
        _ = try engine.resetUsage(childId: "alice", expectedRevision: 0, actorUID: 501, now: now.addingTimeInterval(10), monotonic: 10)
        XCTAssertEqual(try engine.store.resetAuditEvents().first?.priorSeconds, 10)
        XCTAssertEqual(try usage(engine), 0)
        try engine.tick(now: now.addingTimeInterval(12), monotonic: 12)
        XCTAssertEqual(try usage(engine), 2)
        try engine.reportActivity(childId: "alice", serviceId: "chesscom", sessionId: "web", sequence: 2, isActive: true, now: now.addingTimeInterval(13), monotonic: 13)
        try engine.tick(now: now.addingTimeInterval(20), monotonic: 20)
        XCTAssertEqual(try usage(engine), 10)
        XCTAssertEqual(try engine.store.resetAuditEvents().count, 1)
    }

    func testResetDoesNotRenewStaleCollectorsLease() throws {
        let engine = try engine()
        try engine.reportActivity(childId: "alice", serviceId: "chesscom", sessionId: "web", sequence: 1, isActive: true, now: now, monotonic: 0)
        _ = try engine.resetUsage(childId: "alice", expectedRevision: 0, actorUID: 501, now: now.addingTimeInterval(10), monotonic: 10)
        try engine.tick(now: now.addingTimeInterval(40), monotonic: 40)
        XCTAssertEqual(try usage(engine), 5)
        try engine.tick(now: now.addingTimeInterval(60), monotonic: 60)
        XCTAssertEqual(try usage(engine), 5)
    }

    func testResetForInactiveChildDoesNotInterruptSiblingsActiveTimer() throws {
        let engine = try engine()
        try add(engine, seconds: 30)
        try engine.reportActivity(childId: "bob", serviceId: "chesscom", sessionId: "web", sequence: 1, isActive: true, now: now, monotonic: 0)
        _ = try engine.resetUsage(childId: "alice", expectedRevision: 0, actorUID: 501, now: now.addingTimeInterval(5), monotonic: 5)
        try engine.tick(now: now.addingTimeInterval(10), monotonic: 10)
        XCTAssertEqual(try usage(engine), 0)
        XCTAssertEqual(try usage(engine, child: "bob", quota: "b-chess"), 10)
    }

    func testReplayedResetIsRejectedAndCannotEraseNewUsage() throws {
        let engine = try engine()
        _ = try engine.resetUsage(childId: "alice", expectedRevision: 0, actorUID: 501, now: now, monotonic: 0)
        try add(engine, seconds: 6)
        XCTAssertThrowsError(try engine.resetUsage(childId: "alice", expectedRevision: 0, actorUID: 501, now: now, monotonic: 0)) {
            XCTAssertEqual($0 as? QuotaError, .conflict)
        }
        XCTAssertEqual(try usage(engine), 6)
        XCTAssertEqual(engine.policy.revision, 1)
        XCTAssertEqual(try engine.store.resetAuditEvents().count, 1)
    }

    func testUnknownChildDoesNotMutatePolicyUsageOrAudit() throws {
        let engine = try engine();try add(engine, seconds: 4)
        XCTAssertThrowsError(try engine.resetUsage(childId: "missing", expectedRevision: 0, actorUID: 501, now: now, monotonic: 0)) {
            XCTAssertEqual($0 as? QuotaError, .unknownChild)
        }
        XCTAssertEqual(engine.policy.revision, 0)
        XCTAssertEqual(try usage(engine), 4)
        XCTAssertTrue(try engine.store.resetAuditEvents().isEmpty)
    }

    func testZeroAllowanceRemainsExhaustedAfterReset() throws {
        var policy = fixturePolicy();policy.quotas[0].weeklyLimitSeconds = 0
        let engine = try QuotaEngine(store: QuotaStore(path: ":memory:"), policy: policy)
        _ = try engine.resetUsage(childId: "alice", expectedRevision: 0, actorUID: 501, now: now, monotonic: 0)
        let balance = try engine.balances(childId: "alice", now: now, monotonic: 0)
        XCTAssertEqual(balance.items[0].remainingSeconds, 0)
        XCTAssertEqual(balance.items[0].quotaState, "exhausted")
        XCTAssertEqual(balance.items[1].remainingSeconds, 21_600)
    }

    func testResetPersistsPolicyAuditAndCountersAcrossRestartWithoutBillingDowntime() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kids-quota-reset-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("quota.sqlite").path
        do {
            let engine = try QuotaEngine(store: QuotaStore(path: path), policy: fixturePolicy())
            try add(engine, seconds: 500)
            try add(engine, child: "bob", quota: "b-chess", seconds: 100)
            _ = try engine.resetUsage(childId: "alice", expectedRevision: 0, actorUID: 999, now: now, monotonic: 0)
        }
        let store = try QuotaStore(path: path)
        let engine = try QuotaEngine(store: store, policy: XCTUnwrap(store.loadPolicy()))
        let after = try engine.balances(childId: "alice", now: now.addingTimeInterval(3600), monotonic: 0)
        XCTAssertEqual(after.policyRevision, 1)
        XCTAssertEqual(after.items.map(\.usedSeconds), [0, 0])
        XCTAssertEqual(try usage(engine, child: "bob", quota: "b-chess"), 100)
        XCTAssertEqual(try store.resetAuditEvents().first?.actorUID, 999)
        XCTAssertEqual(try store.resetAuditEvents().first?.priorSeconds, 500)
    }

    func testInvalidResetPolicyRollsBackCountersAuditAndRevisionTogether() throws {
        let engine = try engine();try add(engine, seconds: 9.5)
        var invalid = engine.policy;invalid.revision = 1;invalid.schemaVersion = 999
        XCTAssertThrowsError(try engine.store.resetUsage(childId: "alice", periodStart: week, actorUID: 501, occurredAt: now, expectedRevision: 0, policy: invalid))
        XCTAssertEqual(try usage(engine), 9.5)
        XCTAssertEqual(try engine.store.loadPolicy()?.revision, 0)
        XCTAssertTrue(try engine.store.resetAuditEvents().isEmpty)
    }

    func testAuditWriteFailureRollsBackResetAndActiveUsageContinues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kids-quota-reset-failure-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("quota.sqlite").path
        let engine = try QuotaEngine(store: QuotaStore(path: path), policy: fixturePolicy())
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TRIGGER reject_reset BEFORE INSERT ON reset_events BEGIN SELECT RAISE(ABORT,'simulated audit failure'); END", nil, nil, nil), SQLITE_OK)
        try engine.reportActivity(childId: "alice", serviceId: "chesscom", sessionId: "web", sequence: 1, isActive: true, now: now, monotonic: 0)
        XCTAssertThrowsError(try engine.resetUsage(childId: "alice", expectedRevision: 0, actorUID: 501, now: now.addingTimeInterval(5), monotonic: 5))
        XCTAssertEqual(engine.policy.revision, 0)
        XCTAssertEqual(try engine.store.loadPolicy()?.revision, 0)
        XCTAssertEqual(try usage(engine), 5)
        XCTAssertTrue(try engine.store.resetAuditEvents().isEmpty)
        try engine.tick(now: now.addingTimeInterval(10), monotonic: 10)
        XCTAssertEqual(try usage(engine), 10)
        XCTAssertEqual(sqlite3_exec(database, "DROP TRIGGER reject_reset", nil, nil, nil), SQLITE_OK)
        _ = try engine.resetUsage(childId: "alice", expectedRevision: 0, actorUID: 501, now: now.addingTimeInterval(10), monotonic: 10)
        XCTAssertEqual(try usage(engine), 0)
        XCTAssertEqual(try engine.store.resetAuditEvents().first?.priorSeconds, 10)
    }

    func testScheduledResetBoundaryRequiresFreshRevisionBeforeManualReset() throws {
        let engine = try engine()
        var policy = engine.policy;policy.reset.weekday = "wednesday"
        let changed = try engine.replacePolicy(policy, expectedRevision: 0, now: now, monotonic: 0)
        let boundary = try XCTUnwrap(changed.pendingReset?.effectiveAt)
        XCTAssertThrowsError(try engine.resetUsage(childId: "alice", expectedRevision: 1, actorUID: 501, now: boundary, monotonic: boundary.timeIntervalSince(now))) {
            XCTAssertEqual($0 as? QuotaError, .conflict)
        }
        XCTAssertEqual(engine.policy.revision, 2)
        XCTAssertTrue(try engine.store.resetAuditEvents().isEmpty)
        _ = try engine.resetUsage(childId: "alice", expectedRevision: 2, actorUID: 501, now: boundary, monotonic: boundary.timeIntervalSince(now))
        XCTAssertEqual(try engine.store.resetAuditEvents().first?.periodStart, boundary)
    }

    func testWallClockRollbackCannotUseResetToEraseAnEarlierWeeksHistory() throws {
        let engine = try engine();let oldWeek = week.addingTimeInterval(-604_800)
        try add(engine, seconds: 20)
        try add(engine, seconds: 40, period: oldWeek)
        _ = try engine.balances(childId: "alice", now: now, monotonic: 0)
        _ = try engine.resetUsage(childId: "alice", expectedRevision: 0, actorUID: 501, now: now.addingTimeInterval(-604_800), monotonic: 1)
        XCTAssertEqual(try usage(engine), 0)
        XCTAssertEqual(try usage(engine, period: oldWeek), 40)
        XCTAssertEqual(try engine.store.resetAuditEvents().first?.periodStart, week)
    }
}
