import XCTest
import Security
import QuotaKit

final class DashboardReaderTests: XCTestCase {
    private func connection(_ token: String = "a") throws -> PhoneConnection {
        try PhoneConnection.parse("{\"schemaVersion\":1,\"endpoint\":\"https://quota.example.com\",\"familyName\":\"Family\",\"readToken\":\"\(String(repeating: token, count: 43))\"}")
    }
    func testStorageReadDistinguishesMissingLockedAndInvalidConnection() throws {
        XCTAssertEqual(PhoneStorage.decodeConnection(status: errSecItemNotFound, data: nil), .absent)
        for status in [errSecInteractionNotAllowed, errSecMissingEntitlement, errSecNotAvailable] {
            XCTAssertEqual(PhoneStorage.decodeConnection(status: status, data: nil), .unavailable)
        }
        XCTAssertEqual(PhoneStorage.decodeConnection(status: errSecSuccess, data: Data("{}".utf8)), .invalid)
        let value = try connection()
        XCTAssertEqual(PhoneStorage.decodeConnection(status: errSecSuccess, data: try JSONEncoder().encode(value)), .available(value))
    }
    func testUnreadableConnectionDoesNotBecomeAnUnpairedWidget() async {
        let result = await DashboardReader.load(connection: { .unavailable }, fetch: { _ in XCTFail("Must not fetch without a readable credential"); throw FamilyClient.Failure.unavailable })
        XCTAssertNil(result.family); XCTAssertEqual(result.issue, .connectionUnavailable)
    }
    func testUnauthorizedWidgetWithoutCacheAsksToReconnect() async throws {
        let value = try connection()
        let result = await DashboardReader.load(connection: { .available(value) }, cached: { _ in nil }, fetch: { _ in throw FamilyClient.Failure.unauthorized })
        XCTAssertNil(result.family); XCTAssertEqual(result.issue, .reconnect)
    }
    func testOfflineWidgetKeepsLastKnownReport() async throws {
        let value = try connection(), previous = DemoFamily.snapshot()
        let result = await DashboardReader.load(connection: { .available(value) }, cached: { _ in previous }, fetch: { _ in throw FamilyClient.Failure.unavailable })
        XCTAssertEqual(result.family?.children.first?.capturedAt, previous.children.first?.capturedAt)
        XCTAssertEqual(result.issue, .cannotRefresh); XCTAssertTrue(result.issue!.usesLastKnownBalance)
    }
    func testWidgetKeepsValidatedResponseWhenCacheWriteFails() async throws {
        let value = try connection(), report = DemoFamily.snapshot()
        let result = await DashboardReader.load(connection: { .available(value) }, cached: { _ in nil }, save: { _, _ in throw PhoneStorage.StorageError.appGroup }, fetch: { _ in report })
        XCTAssertEqual(result.family?.children.first?.capturedAt, report.children.first?.capturedAt)
        XCTAssertEqual(result.issue, .localStorage); XCTAssertFalse(result.issue!.usesLastKnownBalance)
    }
    func testWidgetCannotReviveConnectionRemovedDuringFetch() async throws {
        let value = try connection()
        var loaded = ConnectionLoad.available(value)
        let result = await DashboardReader.load(connection: { loaded }, cached: { _ in nil }, save: { report, _ in XCTFail("Must not save a disconnected family"); return report }, fetch: { _ in loaded = .absent; return DemoFamily.snapshot() })
        XCTAssertNil(result.family); XCTAssertEqual(result.issue, .notConnected)
    }
    func testWidgetDoesNotTreatConnectionChangeAsCacheFailure() async throws {
        let value = try connection(), replacement = try connection("b")
        var loaded = ConnectionLoad.available(value)
        let result = await DashboardReader.load(connection: { loaded }, cached: { _ in nil }, save: { _, _ in loaded = .available(replacement); throw PhoneStorage.StorageError.changedConnection }, fetch: { _ in DemoFamily.snapshot() })
        XCTAssertNil(result.family); XCTAssertEqual(result.issue, .cannotRefresh)
    }
}
