import XCTest
import QuotaKit

@MainActor final class FamilyStoreTests: XCTestCase {
    private final class Harness {
        var savedConnection: PhoneConnection?
        var loadOverride: ConnectionLoad?
        var cached: FamilySnapshot?
        var requests: [CheckedContinuation<FamilySnapshot, Error>] = []
        var requestArrived: (() -> Void)?
        var dependencies: FamilyStore.Dependencies {
            .init(connection: { self.loadOverride ?? self.savedConnection.map(ConnectionLoad.available) ?? .absent }, cached: { _ in self.cached },
                  saveConnection: { self.savedConnection = $0; self.cached = nil },
                  saveSnapshot: { value, _ in self.cached = value.preservingNewerReports(from: self.cached); return self.cached! },
                  disconnect: { self.savedConnection = nil; self.cached = nil },
                  fetch: { _ in try await withCheckedThrowingContinuation { self.requests.append($0); self.requestArrived?() } },
                  reloadWidgets: {})
        }
    }
    private func pairing(_ name: String = "Family") -> String {
        "{\"schemaVersion\":1,\"endpoint\":\"https://quota.example.com\",\"familyName\":\"\(name)\",\"readToken\":\"\(String(repeating: name.first!, count: 43))\"}"
    }
    func testLatePairingCannotUndoDisconnect() async throws {
        let harness = Harness(), arrived = expectation(description: "request")
        harness.requestArrived = { arrived.fulfill() }
        let store = FamilyStore(dependencies: harness.dependencies)
        let connecting = Task { try await store.connect(pairing()) }
        await fulfillment(of: [arrived], timeout: 2)
        try store.disconnect()
        harness.requests[0].resume(returning: DemoFamily.snapshot())
        do { try await connecting.value; XCTFail("Cancelled pairing should not complete") } catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        XCTAssertNil(store.connection); XCTAssertNil(harness.savedConnection); XCTAssertNil(store.snapshot)
    }
    func testNewPairingWinsOverOlderResponse() async throws {
        let harness = Harness(), first = expectation(description: "first"), second = expectation(description: "second")
        harness.requestArrived = { if harness.requests.count == 1 { first.fulfill() } else { second.fulfill() } }
        let store = FamilyStore(dependencies: harness.dependencies)
        let oldTask = Task { try await store.connect(pairing("Old")) }
        await fulfillment(of: [first], timeout: 2)
        let newTask = Task { try await store.connect(pairing("New")) }
        await fulfillment(of: [second], timeout: 2)
        harness.requests[1].resume(returning: DemoFamily.snapshot()); try await newTask.value
        harness.requests[0].resume(returning: DemoFamily.snapshot())
        _ = try? await oldTask.value
        XCTAssertEqual(store.connection?.familyName, "New"); XCTAssertEqual(harness.savedConnection?.familyName, "New")
    }
    func testPairingDuringRefreshDoesNotLeaveRefreshStuck() async throws {
        let harness = Harness(), first = expectation(description: "refresh"), second = expectation(description: "pairing")
        harness.savedConnection = try PhoneConnection.parse(pairing("Old"))
        harness.requestArrived = { if harness.requests.count == 1 { first.fulfill() } else { second.fulfill() } }
        let store = FamilyStore(dependencies: harness.dependencies)
        let refresh = Task { await store.refresh() }
        await fulfillment(of: [first], timeout: 2); XCTAssertTrue(store.isRefreshing)
        let connecting = Task { try await store.connect(pairing("New")) }
        await fulfillment(of: [second], timeout: 2)
        harness.requests[1].resume(returning: DemoFamily.snapshot()); try await connecting.value
        harness.requests[0].resume(returning: DemoFamily.snapshot()); await refresh.value
        XCTAssertFalse(store.isRefreshing); XCTAssertEqual(store.connection?.familyName, "New")
        let third = expectation(description: "next refresh"); harness.requestArrived = { third.fulfill() }
        let again = Task { await store.refresh() }
        await fulfillment(of: [third], timeout: 2)
        harness.requests[2].resume(returning: DemoFamily.snapshot()); await again.value
        XCTAssertFalse(store.isRefreshing)
    }
    func testFailedRefreshRetainsLastKnownBalance() async throws {
        let harness = Harness(), arrived = expectation(description: "request")
        harness.savedConnection = try PhoneConnection.parse(pairing()); harness.cached = DemoFamily.snapshot()
        harness.requestArrived = { arrived.fulfill() }
        let store = FamilyStore(dependencies: harness.dependencies)
        let task = Task { await store.refresh() }
        await fulfillment(of: [arrived], timeout: 2)
        harness.requests[0].resume(throwing: FamilyClient.Failure.unauthorized); await task.value
        XCTAssertEqual(store.snapshot?.children.first?.child.balances.first?.remainingSeconds, 13_500)
        XCTAssertEqual(store.issue, .reconnect); XCTAssertFalse(store.isRefreshing)
    }
    func testCacheFailureKeepsNewReportWithoutShowingPreviousFamily() async throws {
        let harness = Harness(), arrived = expectation(description: "pairing")
        harness.savedConnection = try PhoneConnection.parse(pairing("Old")); harness.cached = DemoFamily.snapshot()
        harness.requestArrived = { arrived.fulfill() }
        var dependencies = harness.dependencies
        dependencies.saveSnapshot = { _, _ in throw PhoneStorage.StorageError.appGroup }
        let store = FamilyStore(dependencies: dependencies)
        let task = Task { try await store.connect(pairing("New")) }
        await fulfillment(of: [arrived], timeout: 2)
        var raw = try JSONSerialization.jsonObject(with: DemoFamily.snapshot().encoded()) as! [String: Any]
        raw["familyName"] = "New family report"
        let report = try FamilySnapshot.decode(JSONSerialization.data(withJSONObject: raw))
        harness.requests[0].resume(returning: report)
        try await task.value
        XCTAssertEqual(store.connection?.familyName, "New")
        XCTAssertEqual(store.snapshot?.familyName, "New family report"); XCTAssertEqual(store.issue, .localStorage)
    }
    func testLockedConnectionRecoversOnRefreshWithoutPairingAgain() async throws {
        let harness = Harness(), arrived = expectation(description: "refresh after unlock")
        harness.savedConnection = try PhoneConnection.parse(pairing()); harness.loadOverride = .unavailable
        harness.requestArrived = { arrived.fulfill() }
        let store = FamilyStore(dependencies: harness.dependencies)
        XCTAssertEqual(store.issue, .connectionUnavailable)
        await store.refresh(); XCTAssertTrue(harness.requests.isEmpty)
        harness.loadOverride = nil
        let task = Task { await store.refresh() }
        await fulfillment(of: [arrived], timeout: 2)
        harness.requests[0].resume(returning: DemoFamily.snapshot()); await task.value
        XCTAssertNotNil(store.connection); XCTAssertNotNil(store.snapshot); XCTAssertNil(store.issue)
    }
    func testTemporarilyUnreadableConnectionKeepsLastKnownFamily() async throws {
        let harness = Harness()
        harness.savedConnection = try PhoneConnection.parse(pairing()); harness.cached = DemoFamily.snapshot()
        let store = FamilyStore(dependencies: harness.dependencies)
        harness.loadOverride = .unavailable
        await store.refresh()
        XCTAssertNotNil(store.connection); XCTAssertNotNil(store.snapshot)
        XCTAssertEqual(store.issue, .connectionUnavailable); XCTAssertTrue(harness.requests.isEmpty)
    }
    func testInvalidSavedConnectionRequiresReconnectInsteadOfWaiting() async {
        let harness = Harness(); harness.loadOverride = .invalid
        let store = FamilyStore(dependencies: harness.dependencies)
        await store.refresh()
        XCTAssertEqual(store.issue, .reconnect); XCTAssertNil(store.connection); XCTAssertTrue(harness.requests.isEmpty)
    }
    func testRefreshCacheFailureKeepsNewerBalanceInMemory() async throws {
        let harness = Harness(), arrived = expectation(description: "refresh")
        harness.savedConnection = try PhoneConnection.parse(pairing())
        harness.cached = DemoFamily.snapshot(now: Date().addingTimeInterval(-600))
        harness.requestArrived = { arrived.fulfill() }
        var dependencies = harness.dependencies
        dependencies.saveSnapshot = { _, _ in throw PhoneStorage.StorageError.appGroup }
        let store = FamilyStore(dependencies: dependencies)
        let task = Task { await store.refresh() }
        await fulfillment(of: [arrived], timeout: 2)
        let fresh = DemoFamily.snapshot()
        harness.requests[0].resume(returning: fresh); await task.value
        XCTAssertEqual(store.snapshot?.children.first?.capturedAt, fresh.children.first?.capturedAt)
        XCTAssertEqual(store.issue, .localStorage); XCTAssertFalse(store.issue!.usesLastKnownBalance)
    }
    func testConnectionRemovedDuringRefreshCannotRestoreItsData() async throws {
        let harness = Harness(), arrived = expectation(description: "refresh")
        harness.savedConnection = try PhoneConnection.parse(pairing()); harness.cached = DemoFamily.snapshot()
        harness.requestArrived = { arrived.fulfill() }
        let store = FamilyStore(dependencies: harness.dependencies)
        let task = Task { await store.refresh() }
        await fulfillment(of: [arrived], timeout: 2)
        harness.savedConnection = nil
        harness.requests[0].resume(returning: DemoFamily.snapshot()); await task.value
        XCTAssertNil(store.connection); XCTAssertNil(store.snapshot); XCTAssertEqual(store.issue, .notConnected)
    }
    func testCancelPairingKeepsExistingFamilyAndIgnoresLateResponse() async throws {
        let harness = Harness(), arrived = expectation(description: "pairing")
        harness.savedConnection = try PhoneConnection.parse(pairing("Old")); harness.cached = DemoFamily.snapshot()
        harness.requestArrived = { arrived.fulfill() }
        let store = FamilyStore(dependencies: harness.dependencies)
        let task = Task { try await store.connect(pairing("New")) }
        await fulfillment(of: [arrived], timeout: 2)
        store.cancelPairing()
        harness.requests[0].resume(returning: DemoFamily.snapshot())
        do { try await task.value; XCTFail("Dismissed pairing must not finish") } catch is CancellationError {}
        XCTAssertEqual(store.connection?.familyName, "Old"); XCTAssertEqual(harness.savedConnection?.familyName, "Old")
        XCTAssertNotNil(store.snapshot)
    }
    func testConnectionChangeDuringPairingSaveDoesNotPreventLaterRefresh() async throws {
        for removeConnection in [false, true] {
            let harness = Harness(), pairingArrived = expectation(description: "pairing"), refreshArrived = expectation(description: "refresh after connection change")
            let replacement = try PhoneConnection.parse(pairing("Replacement"))
            harness.requestArrived = { if harness.requests.count == 1 { pairingArrived.fulfill() } else { refreshArrived.fulfill() } }
            var dependencies = harness.dependencies
            let save = dependencies.saveSnapshot
            var changeDuringSave = true
            dependencies.saveSnapshot = { report, connection in
                if changeDuringSave {
                    changeDuringSave = false
                    harness.savedConnection = removeConnection ? nil : replacement
                    throw PhoneStorage.StorageError.changedConnection
                }
                return try save(report, connection)
            }
            let store = FamilyStore(dependencies: dependencies)
            let task = Task { try await store.connect(pairing("New")) }
            await fulfillment(of: [pairingArrived], timeout: 2)
            harness.requests[0].resume(returning: DemoFamily.snapshot())
            do { try await task.value; XCTFail("Changed connection must cancel pairing") } catch is CancellationError {}
            harness.savedConnection = replacement
            let refresh = Task { await store.refresh() }
            await fulfillment(of: [refreshArrived], timeout: 2)
            guard harness.requests.count == 2 else { refresh.cancel(); return }
            harness.requests[1].resume(returning: DemoFamily.snapshot()); await refresh.value
            XCTAssertEqual(store.connection, replacement); XCTAssertNotNil(store.snapshot); XCTAssertNil(store.issue)
        }
    }
}
