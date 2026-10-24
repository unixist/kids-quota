import XCTest
@testable import KidsQuotaCore

final class QuotaEngineTests: XCTestCase {
    private let start = instant("2026-10-21T12:00:00Z")
    private func engine(policy: Policy = fixturePolicy(), timeout: Double = 15) throws -> QuotaEngine {
        try QuotaEngine(store: QuotaStore(path: ":memory:"), policy: policy, heartbeatTimeout: timeout)
    }
    private func report(_ engine: QuotaEngine, at elapsed: Double, child: String = "alice", service: String? = "chesscom", session: String = "browser", sequence: UInt64 = 1, active: Bool = true) throws {
        try engine.reportActivity(childId: child, serviceId: service, sessionId: session, sequence: sequence, isActive: active, now: start.addingTimeInterval(elapsed), monotonic: elapsed)
    }
    private func balances(_ engine: QuotaEngine, at elapsed: Double, child: String = "alice") throws -> [Balance] {
        try engine.balances(childId: child, now: start.addingTimeInterval(elapsed), monotonic: elapsed).items
    }

    func testForegroundTimeCountsAndInactiveStops() throws {
        let engine = try engine()
        try report(engine, at: 0)
        try report(engine, at: 10, sequence: 2, active: false)
        XCTAssertEqual(try balances(engine, at: 100)[0].usedSeconds, 10)
    }

    func testHeartbeatRenewsLeaseWithoutDoubleCounting() throws {
        let engine = try engine()
        for index in 0...6 { try report(engine, at: Double(index * 10), sequence: UInt64(index + 1)) }
        XCTAssertEqual(try balances(engine, at: 65)[0].usedSeconds, 65)
        XCTAssertEqual(try balances(engine, at: 65)[0].usedSeconds, 65)
    }

    func testStaleActivityIsCappedAndNeedsFreshReport() throws {
        let engine = try engine()
        try report(engine, at: 0)
        XCTAssertEqual(try balances(engine, at: 500)[0].usedSeconds, 15)
        XCTAssertEqual(try balances(engine, at: 1000)[0].usedSeconds, 15)
        try report(engine, at: 1000, sequence: 2)
        XCTAssertEqual(try balances(engine, at: 1010)[0].usedSeconds, 25)
    }

    func testDuplicateAndOutOfOrderReportsDoNotRenewLease() throws {
        let engine = try engine()
        try report(engine, at: 0, sequence: 3)
        try report(engine, at: 10, sequence: 3)
        try report(engine, at: 14, sequence: 2)
        XCTAssertEqual(try balances(engine, at: 100)[0].usedSeconds, 15)
    }

    func testWebsiteAndApplicationShareOneAllowance() throws {
        let engine = try engine()
        try report(engine, at: 0)
        try report(engine, at: 10, session: "native-app")
        XCTAssertEqual(try balances(engine, at: 20)[0].usedSeconds, 20)
    }

    func testLateInactiveReportCannotStopNewSession() throws {
        let engine = try engine()
        try report(engine, at: 0)
        try report(engine, at: 5, session: "native-app")
        try report(engine, at: 10, sequence: 2, active: false)
        XCTAssertEqual(try balances(engine, at: 15)[0].usedSeconds, 15)
    }

    func testChildrenHaveIndependentBalancesWithOneForegroundOwner() throws {
        let engine = try engine()
        try report(engine, at: 0)
        try report(engine, at: 10, child: "bob")
        XCTAssertEqual(try balances(engine, at: 20)[0].usedSeconds, 10)
        XCTAssertEqual(try balances(engine, at: 20, child: "bob")[0].usedSeconds, 10)
    }

    func testChangingServiceStopsPreviousService() throws {
        let engine = try engine()
        try report(engine, at: 0)
        try report(engine, at: 10, service: "chatgpt", sequence: 2)
        let result = try balances(engine, at: 20)
        XCTAssertEqual(result.map(\.usedSeconds), [10, 10])
    }

    func testSleepWallClockGapIsNotBilled() throws {
        let engine = try engine()
        try report(engine, at: 0)
        try engine.tick(now: start.addingTimeInterval(3600), monotonic: 5)
        let result = try engine.balances(childId: "alice", now: start.addingTimeInterval(3610), monotonic: 15)
        XCTAssertEqual(result.items[0].usedSeconds, 0)
    }

    func testExplicitLockOrSleepStopPreventsBilling() throws {
        let engine = try engine()
        try report(engine, at: 0)
        try engine.stop(now: start.addingTimeInterval(5), monotonic: 5)
        XCTAssertEqual(try balances(engine, at: 3600)[0].usedSeconds, 5)
    }

    func testMonotonicClockResetDoesNotBillUnknownInterval() throws {
        let engine = try engine()
        try report(engine, at: 10)
        try engine.tick(now: start.addingTimeInterval(20), monotonic: 1)
        XCTAssertEqual(try engine.balances(childId: "alice", now: start.addingTimeInterval(21), monotonic: 2).items[0].usedSeconds, 0)
    }

    func testClockRollbackCannotRefundUsageOrReopenOldPeriod() throws {
        let engine = try engine()
        try report(engine, at: 0)
        let now = start.addingTimeInterval(-604800)
        let result = try engine.balances(childId: "alice", now: now, monotonic: 10)
        XCTAssertEqual(result.items[0].usedSeconds, 10)
        XCTAssertEqual(result.items[0].periodStart, instant("2026-10-19T00:00:00Z"))
    }

    func testSixHourQuotaExhaustsAndZeroQuotaStartsBlocked() throws {
        let engine = try engine(timeout: 22_000)
        try report(engine, at: 0)
        let result = try balances(engine, at: 21_600)[0]
        XCTAssertEqual(result.remainingSeconds, 0)
        XCTAssertEqual(result.quotaState, "exhausted")
        var policy = fixturePolicy(); policy.quotas[0].weeklyLimitSeconds = 0
        let zero = try self.engine(policy: policy)
        XCTAssertEqual(try balances(zero, at: 0)[0].quotaState, "exhausted")
    }

    func testFractionalDurationIsPersistedWithoutRoundingEveryTick() throws {
        let engine = try engine()
        try report(engine, at: 0)
        for time in [0.2, 0.4, 0.6, 0.8] { _ = try balances(engine, at: time) }
        XCTAssertEqual(try balances(engine, at: 1)[0].usedSeconds, 1)
    }

    func testBoundarySplitsUsageAndResetsOnce() throws {
        let engine = try engine()
        let sunday = instant("2026-10-25T23:59:55Z")
        try engine.reportActivity(childId: "alice", serviceId: "chesscom", sessionId: "web", sequence: 1, isActive: true, now: sunday, monotonic: 0)
        let result = try engine.balances(childId: "alice", now: sunday.addingTimeInterval(10), monotonic: 10)
        XCTAssertEqual(result.items[0].usedSeconds, 5)
        XCTAssertEqual(try engine.store.usageSeconds(childId: "alice", quotaId: "a-chess", periodStart: instant("2026-10-19T00:00:00Z")), 5)
    }

    func testAllowanceEditKeepsUsageAndChecksRevision() throws {
        let engine = try engine()
        try report(engine, at: 0)
        var policy = engine.policy; policy.quotas[0].weeklyLimitSeconds = 8
        let revised = try engine.replacePolicy(policy, expectedRevision: 0, now: start.addingTimeInterval(10), monotonic: 10)
        XCTAssertEqual(revised.revision, 1)
        XCTAssertEqual(try balances(engine, at: 10)[0].quotaState, "exhausted")
        XCTAssertThrowsError(try engine.replacePolicy(policy, expectedRevision: 0, now: start.addingTimeInterval(10), monotonic: 10)) { XCTAssertEqual($0 as? QuotaError, .conflict) }
    }

    func testQuotaIDCannotMoveToAnotherChild() throws {
        let engine = try engine()
        var policy = engine.policy; policy.quotas = [policy.quotas[0]]; policy.quotas[0].childId = "bob"
        XCTAssertThrowsError(try engine.replacePolicy(policy, expectedRevision: 0, now: start, monotonic: 0))
    }

    func testResetScheduleChangeTakesEffectAtOldBoundary() throws {
        let engine = try engine()
        try report(engine, at: 0)
        var policy = engine.policy; policy.reset.weekday = "wednesday"
        let revised = try engine.replacePolicy(policy, expectedRevision: 0, now: start.addingTimeInterval(10), monotonic: 10)
        XCTAssertEqual(revised.reset.weekday, "monday")
        XCTAssertEqual(revised.pendingReset?.effectiveAt, instant("2026-10-26T00:00:00Z"))
        XCTAssertEqual(try balances(engine, at: 10)[0].usedSeconds, 10)
        let newWeek = try engine.balances(childId: "alice", now: instant("2026-10-26T00:00:00Z"), monotonic: 400_000)
        XCTAssertEqual(newWeek.policyRevision, 2)
        XCTAssertEqual(newWeek.items[0].periodStart, instant("2026-10-26T00:00:00Z"))
        XCTAssertEqual(newWeek.items[0].periodEnd, instant("2026-10-28T00:00:00Z"))
        XCTAssertEqual(newWeek.items[0].usedSeconds, 0)
    }

    func testCoverageIsSeparateFromRemainingBalance() throws {
        let engine = try engine()
        let result = try engine.balances(childId: "alice", now: start, monotonic: 0, coverage: ["chesscom": true])
        XCTAssertEqual(result.items.map(\.coverage), ["complete", "incomplete"])
        XCTAssertEqual(result.items.map(\.remainingSeconds), [21_600, 21_600])
    }

    func testUnknownChildCannotPublishOrRead() throws {
        let engine = try engine()
        XCTAssertThrowsError(try report(engine, at: 0, child: "missing"))
        XCTAssertThrowsError(try balances(engine, at: 0, child: "missing"))
    }
}
