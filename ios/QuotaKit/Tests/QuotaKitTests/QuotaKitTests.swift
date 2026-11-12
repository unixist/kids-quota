import XCTest
@testable import QuotaKit

final class QuotaKitTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_445_200)
    private var pairing: [String: Any] { ["schemaVersion": 1, "endpoint": "https://quota.example.com", "familyName": "Our family", "readToken": String(repeating: "a", count: 43)] }
    private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func text(_ object: Any) throws -> String { String(data: try json(object), encoding: .utf8)! }
    private func fixture() throws -> [String: Any] { try JSONSerialization.jsonObject(with: DemoFamily.snapshot(now: now).encoded()) as! [String: Any] }
    private func changeBalance(_ transform: (inout [String: Any]) -> Void) throws -> Data {
        var family = try fixture(); var devices = family["devices"] as! [[String: Any]]
        var snapshot = devices[0]["snapshot"] as! [String: Any]; var children = snapshot["children"] as! [[String: Any]]
        var balances = children[0]["balances"] as! [[String: Any]]; transform(&balances[0]); children[0]["balances"] = balances
        snapshot["children"] = children; devices[0]["snapshot"] = snapshot; family["devices"] = devices
        return try json(family)
    }
    func testPairingJSONAndQRUseSameValidatedConnection() throws {
        let raw = try text(pairing); let connection = try PhoneConnection.parse(raw)
        let encoded = Data(raw.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(try PhoneConnection.parse("kidsquota://pair?data=" + encoded), connection)
    }
    func testCredentialsCannotGoToHTTPOrPathsOrURLUserInfo() throws {
        for endpoint in ["http://quota.example.com", "https://token@quota.example.com", "https://quota.example.com/path", "https://quota.example.com?token=secret", "https://quota.example.com#secret"] {
            var object = pairing; object["endpoint"] = endpoint
            XCTAssertThrowsError(try PhoneConnection.parse(text(object)), endpoint)
        }
    }
    func testPairingAcceptsValidHTTPSPortsAndPreservesThemInRequests() throws {
        for port in [1, 443, 8443, 65535] {
            var object = pairing; object["endpoint"] = "https://quota.example.com:\(port)"
            let connection = try PhoneConnection.parse(text(object))
            XCTAssertEqual(connection.origin.port, port)
            XCTAssertEqual(connection.origin.appendingPathComponent("v1/family").port, port)
        }
    }
    func testPairingRejectsInvalidHTTPSPorts() throws {
        for port in ["", "0", "-1", "65536", "999999999999999999999", "abc", "443.5"] {
            var object = pairing; object["endpoint"] = "https://quota.example.com:\(port)"
            XCTAssertThrowsError(try PhoneConnection.parse(text(object)), "Accepted invalid port \(port)")
        }
    }
    func testRejectsWritePairingAndMalformedTokens() throws {
        var object = pairing; object.removeValue(forKey: "readToken"); object["writeToken"] = String(repeating: "a", count: 43)
        XCTAssertThrowsError(try PhoneConnection.parse(text(object)))
        for token in ["short", String(repeating: "a", count: 32) + "\r\nX-Header: injected", String(repeating: "a", count: 513)] {
            object = pairing; object["readToken"] = token
            XCTAssertThrowsError(try PhoneConnection.parse(text(object)))
        }
    }
    func testPairingRejectsUnexpectedVersionsOversizeAndExtraQRParameters() throws {
        var object = pairing; object["schemaVersion"] = 2
        XCTAssertThrowsError(try PhoneConnection.parse(text(object)))
        XCTAssertThrowsError(try PhoneConnection.parse(String(repeating: "x", count: 16_385)))
        XCTAssertThrowsError(try PhoneConnection.parse("kidsquota://pair?data=e30&endpoint=https://attacker.example"))
    }
    func testValidFamilyRoundTripPreservesReportedUsage() throws {
        let value = try FamilySnapshot.decode(DemoFamily.snapshot(now: now).encoded(), now: now)
        XCTAssertEqual(value.children.count, 2)
        XCTAssertEqual(value.children[0].child.balances[0].remainingSeconds, 13_500)
        XCTAssertEqual(value.children[0].id, "demo-mac:alex")
    }
    func testMalformedBalanceRejectsWholeSnapshot() throws {
        let data = try changeBalance { $0["remainingSeconds"] = 21_600 }
        XCTAssertThrowsError(try FamilySnapshot.decode(data, now: now))
    }
    func testNegativeDurationAndInconsistentStateAreRejected() throws {
        XCTAssertThrowsError(try FamilySnapshot.decode(changeBalance { $0["usedSeconds"] = -1 }, now: now))
        XCTAssertThrowsError(try FamilySnapshot.decode(changeBalance { $0["quotaState"] = "exhausted" }, now: now))
    }
    func testPausedTrackingDoesNotErasePositiveBalance() throws {
        let value = try FamilySnapshot.decode(changeBalance { $0["blockingReason"] = "collector_unavailable"; $0["coverage"] = "incomplete" }, now: now)
        let balance = value.children[0].child.balances[0]
        XCTAssertTrue(balance.isPaused); XCTAssertFalse(balance.isExhausted)
        XCTAssertEqual(balance.remainingSeconds, 13_500); XCTAssertEqual(balance.status, "Tracking paused")
    }
    func testStaleSnapshotRetainsBalanceAndNeverInventsReset() throws {
        let child = DemoFamily.snapshot(now: now).children[0]
        XCTAssertFalse(child.isStale(at: now)); XCTAssertTrue(child.isStale(at: now.addingTimeInterval(901)))
        XCTAssertTrue(child.isStale(at: now.addingTimeInterval(6 * 86_400)))
        XCTAssertEqual(child.child.balances[0].remainingSeconds, 13_500)
    }
    func testFutureClockAndUnknownStateCannotAppearFresh() throws {
        XCTAssertThrowsError(try FamilySnapshot.decode(DemoFamily.snapshot(now: now.addingTimeInterval(3600)).encoded(), now: now))
        XCTAssertThrowsError(try FamilySnapshot.decode(changeBalance { $0["blockingReason"] = "unknown" }, now: now))
    }
    func testDevicesWithoutReportsAreRepresentable() throws {
        var object = try fixture(); object["devices"] = [["deviceId": "mac2", "deviceName": "Other Mac", "snapshot": NSNull(), "receivedAt": NSNull()]]
        let family = try FamilySnapshot.decode(json(object), now: now)
        XCTAssertTrue(family.children.isEmpty); XCTAssertNil(family.devices[0].snapshot)
    }
    func testSameChildIDOnDifferentMacsIsNotPooled() throws {
        var object = try fixture(); var devices = object["devices"] as! [[String: Any]]
        var second = devices[0]; second["deviceId"] = "second-mac"
        var snapshot = second["snapshot"] as! [String: Any]; snapshot["deviceId"] = "second-mac"; second["snapshot"] = snapshot
        devices.append(second); object["devices"] = devices
        let family = try FamilySnapshot.decode(json(object), now: now)
        XCTAssertEqual(family.children.count, 4); XCTAssertEqual(Set(family.children.map(\.id)).count, 4)
    }
    func testDuplicateDeviceAndChildIDsAreRejected() throws {
        var object = try fixture(); let device = (object["devices"] as! [[String: Any]])[0]; object["devices"] = [device, device]
        XCTAssertThrowsError(try FamilySnapshot.decode(json(object), now: now))
        var changed = device; var snapshot = changed["snapshot"] as! [String: Any]; let child = (snapshot["children"] as! [[String: Any]])[0]
        snapshot["children"] = [child, child]; changed["snapshot"] = snapshot; object["devices"] = [changed]
        XCTAssertThrowsError(try FamilySnapshot.decode(json(object), now: now))
    }
    func testFractionalRFC3339DatesAreAccepted() throws {
        let raw = String(data: try DemoFamily.snapshot(now: now).encoded(), encoding: .utf8)!.replacingOccurrences(of: "Z\"", with: ".000Z\"")
        XCTAssertEqual(try FamilySnapshot.decode(Data(raw.utf8), now: now).children.count, 2)
    }
    func testDurationNeverRoundsUpAvailableMinutes() {
        XCTAssertEqual(QuotaFormat.duration(59), "<1m"); XCTAssertEqual(QuotaFormat.duration(0), "0m")
        XCTAssertEqual(QuotaFormat.duration(3599), "59m"); XCTAssertEqual(QuotaFormat.duration(13_500), "3h 45m")
    }
    func testLoweredLimitCanHaveMoreUsageThanAllowance() throws {
        let family = try FamilySnapshot.decode(changeBalance { $0["limitSeconds"] = 60; $0["usedSeconds"] = 9_000; $0["remainingSeconds"] = 0; $0["quotaState"] = "exhausted"; $0["blockingReason"] = "exhausted" }, now: now)
        XCTAssertEqual(family.children[0].child.balances[0].fractionUsed, 1)
    }
    func testOlderResponsesNeverReplaceNewerCachedReports() throws {
        let recent = DemoFamily.snapshot(now: now)
        let old = DemoFamily.snapshot(now: now.addingTimeInterval(-300))
        XCTAssertEqual(old.preservingNewerReports(from: recent).children[0].capturedAt, recent.children[0].capturedAt)
        var incoming = try fixture()
        incoming["servedAt"] = ISO8601DateFormatter().string(from: now.addingTimeInterval(60))
        incoming["devices"] = (try JSONSerialization.jsonObject(with: old.encoded()) as! [String: Any])["devices"]
        let newerResponseWithOldReport = try FamilySnapshot.decode(json(incoming), now: now.addingTimeInterval(60))
        XCTAssertEqual(newerResponseWithOldReport.preservingNewerReports(from: recent).children[0].capturedAt, recent.children[0].capturedAt)
    }
    func testNewRosterRemovalsAreRespected() throws {
        var object = try fixture(); object["devices"] = []
        let removed = try FamilySnapshot.decode(json(object), now: now)
        XCTAssertTrue(removed.preservingNewerReports(from: DemoFamily.snapshot(now: now)).children.isEmpty)
    }
    func testWidgetSchedulesResetBoundaryBeforeAgeThreshold() throws {
        let end = now.addingTimeInterval(30)
        let value = try FamilySnapshot.decode(changeBalance { $0["periodEnd"] = ISO8601DateFormatter().string(from: end) }, now: now)
        let changes = value.freshnessTransitions(after: now)
        XCTAssertEqual(changes.first, end)
        XCTAssertTrue(changes.contains(value.children[0].capturedAt.addingTimeInterval(901)))
        XCTAssertTrue(value.children[0].isStale(at: end))
    }
    func testUnreportedMacRemainsVisibleAlongsideReportedChildren() throws {
        var object = try fixture(), devices = try fixture()["devices"] as! [[String: Any]]
        devices.append(["deviceId": "other-mac", "deviceName": "Other Mac", "snapshot": NSNull(), "receivedAt": NSNull()])
        object["devices"] = devices
        let value = try FamilySnapshot.decode(json(object), now: now)
        XCTAssertFalse(value.children.isEmpty)
        XCTAssertEqual(value.unreportedMacCount, 1)
        XCTAssertEqual(value.unreportedMacSummary, "1 Mac has no saved report")
    }
    func testNoSavedReportIsDifferentFromNoConfiguredChildren() throws {
        var object = try fixture()
        object["devices"] = [["deviceId": "other-mac", "deviceName": "Other Mac", "snapshot": NSNull(), "receivedAt": NSNull()]]
        XCTAssertEqual(try FamilySnapshot.decode(json(object), now: now).emptyState(), .waitingForMac)
        object = try fixture(); var devices = object["devices"] as! [[String: Any]]
        var snapshot = devices[0]["snapshot"] as! [String: Any]; snapshot["children"] = []
        devices[0]["snapshot"] = snapshot; object["devices"] = devices
        XCTAssertEqual(try FamilySnapshot.decode(json(object), now: now).emptyState(), .noChildren)
        XCTAssertEqual(DemoFamily.snapshot(now: now).emptyState(childID: "removed-child"), .chooseChild)
    }
    func testIncompleteCoverageIsVisibleEvenWhenBalanceIsAvailable() throws {
        let value = try FamilySnapshot.decode(changeBalance { $0["coverage"] = "incomplete"; $0["blockingReason"] = "available" }, now: now)
        XCTAssertEqual(value.children[0].trackingNotice, "Check tracking on Mac")
        XCTAssertFalse(value.children[0].child.balances[0].isPaused)
    }
    func testFreshStorageWarningDoesNotPretendFetchFailed() {
        XCTAssertFalse(DashboardIssue.localStorage.usesLastKnownBalance)
        XCTAssertTrue(DashboardIssue.cannotRefresh.usesLastKnownBalance)
        XCTAssertTrue(DashboardIssue.reconnect.needsConnectionCode)
        XCTAssertNotEqual(ConnectionLoad.absent.issue, ConnectionLoad.unavailable.issue)
    }
    func testSelectedChildWithoutMacReportWaitsForAnUpdate() throws {
        var object = try fixture()
        object["devices"] = [["deviceId": "other-mac", "deviceName": "Other Mac", "snapshot": NSNull(), "receivedAt": NSNull()]]
        let family = try FamilySnapshot.decode(json(object), now: now)
        XCTAssertEqual(family.emptyState(childID: "other-mac:alex"), .waitingForMac)
        XCTAssertEqual(family.emptyState(childID: "removed-mac:alex"), .chooseChild)
        XCTAssertEqual(DemoFamily.snapshot(now: now).emptyState(childID: "demo-mac:removed-child"), .chooseChild)
    }
}
