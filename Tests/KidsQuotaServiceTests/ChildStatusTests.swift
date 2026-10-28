import XCTest
@testable import KidsQuotaService

final class ChildStatusTests: XCTestCase {
    private func item(remaining: Int = 16380, limit: Int = 21600, used: Int = 5220, reset: String = "2026-11-02T06:00:00Z") -> [String: Any] {
        ["serviceId": "chesscom", "name": "Chess.com", "domains": [["hostname": "chess.com", "includeSubdomains": true]],
         "weeklyLimitSeconds": limit, "usedSeconds": used, "remainingSeconds": remaining, "resetAt": reset, "coverage": "complete"]
    }
    private func response(items: [[String: Any]]? = nil) -> [String: Any] {
        ["type": "childStatus", "configured": true, "childName": "Alex", "resetTimeZone": "America/Chicago", "items": items ?? [item()]]
    }

    func testConfiguredResponseDecodesDomainBalancesAndProgress() throws {
        let status = try ChildStatusSnapshot.decode(response())
        XCTAssertTrue(status.configured)
        XCTAssertEqual(status.childName, "Alex")
        XCTAssertEqual(status.items.first?.domains.first?.hostname, "chess.com")
        XCTAssertEqual(status.items.first?.domains.first?.includeSubdomains, true)
        XCTAssertEqual(status.items.first?.remainingSeconds, 16380)
        XCTAssertEqual(try XCTUnwrap(status.items.first).fractionRemaining, 16380.0 / 21600.0, accuracy: 0.0001)
    }

    func testNoAllowanceAndZeroLimitAreSupported() throws {
        XCTAssertTrue(try ChildStatusSnapshot.decode(response(items: [])).items.isEmpty)
        let blocked = try ChildStatusSnapshot.decode(response(items: [item(remaining: 0, limit: 0, used: 100)]))
        XCTAssertEqual(blocked.items.first?.fractionRemaining, 0)
        XCTAssertEqual(blocked.items.first?.remainingSeconds, 0)
    }

    func testFailureAndAccountRemovalDiscardPreviousBalances() throws {
        var state = ChildStatusDisplayState.loading
        state.accept(response())
        guard case .ready = state else { return XCTFail("Expected fresh balances") }
        state.accept(nil)
        XCTAssertEqual(state, .unavailable)
        state.accept(response())
        state.accept(["error": "Service request failed.", "configured": false])
        XCTAssertEqual(state, .unavailable)
        state.accept(response())
        // An unconfigured response cannot accidentally keep cached/private rows.
        state.accept(["type": "childStatus", "configured": false, "childName": "Old name", "items": [item()]])
        XCTAssertEqual(state, .notConfigured)
        let unlinked = try ChildStatusSnapshot.decode(["type": "childStatus", "configured": false, "childName": "Old name", "items": [item()]])
        XCTAssertNil(unlinked.childName)
        XCTAssertTrue(unlinked.items.isEmpty)
    }

    func testNextSnapshotReplacesBalanceAtWeeklyReset() throws {
        var state = ChildStatusDisplayState.loading
        state.accept(response(items: [item(remaining: 0, used: 21600)]))
        state.accept(response(items: [item(remaining: 21600, used: 0, reset: "2026-11-09T06:00:00Z")]))
        guard case .ready(let status) = state else { return XCTFail("Expected fresh balances") }
        XCTAssertEqual(status.items.first?.remainingSeconds, 21600)
        XCTAssertEqual(status.items.first?.usedSeconds, 0)
        XCTAssertEqual(status.items.first?.resetAt, ISO8601DateFormatter().date(from: "2026-11-09T06:00:00Z"))
    }

    func testMalformedResponsesDoNotAppearAsBalances() {
        var invalid = response()
        invalid["resetTimeZone"] = "Not/AZone"
        XCTAssertThrowsError(try ChildStatusSnapshot.decode(invalid))
        XCTAssertThrowsError(try ChildStatusSnapshot.decode(response(items: [item(remaining: -1)])))
        XCTAssertThrowsError(try ChildStatusSnapshot.decode(response(items: [item(remaining: 21601)])))
        XCTAssertThrowsError(try ChildStatusSnapshot.decode(response(items: [item(reset: "tomorrow")])))
        XCTAssertThrowsError(try ChildStatusSnapshot.decode(response(items: [item(), item()])))
        invalid = response(); invalid["type"] = "policy"
        XCTAssertThrowsError(try ChildStatusSnapshot.decode(invalid))
    }

    func testFormattingDoesNotOverstatePartialMinutes() {
        XCTAssertEqual(ChildStatusPresentation.duration(21600), "6h")
        XCTAssertEqual(ChildStatusPresentation.duration(16380), "4h 33m")
        XCTAssertEqual(ChildStatusPresentation.duration(119), "1m")
        XCTAssertEqual(ChildStatusPresentation.duration(59), "<1m")
        XCTAssertEqual(ChildStatusPresentation.duration(0), "0m")
        XCTAssertEqual(ChildStatusPresentation.duration(-1), "0m")
        XCTAssertEqual(ChildStatusPresentation.accessibleDuration(3600), "1 hour")
        XCTAssertEqual(ChildStatusPresentation.accessibleDuration(3660), "1 hour 1 minute")
        XCTAssertEqual(ChildStatusPresentation.accessibleDuration(119), "1 minute")
        XCTAssertEqual(ChildStatusPresentation.accessibleDuration(59), "Less than a minute")
    }

    func testResetLabelUsesConfiguredZoneInsteadOfComputerZone() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-02T06:00:00Z"))
        let locale = Locale(identifier: "en_US")
        let chicago = ChildStatusPresentation.resetLabel(date, timeZone: "America/Chicago", locale: locale)
        let losAngeles = ChildStatusPresentation.resetLabel(date, timeZone: "America/Los_Angeles", locale: locale)
        XCTAssertTrue(chicago.contains("Mon"), chicago)
        XCTAssertTrue(chicago.contains("12:00"), chicago)
        XCTAssertTrue(chicago.contains("CST"), chicago)
        XCTAssertTrue(losAngeles.contains("Sun"), losAngeles)
        XCTAssertTrue(losAngeles.contains("10:00"), losAngeles)
        XCTAssertTrue(losAngeles.contains("PST"), losAngeles)
    }
}
