import XCTest
import QuotaKit

@MainActor final class FamilyStoreTests: XCTestCase {
    private final class Harness {
        var savedConnection: PhoneConnection?
        var cached: FamilySnapshot?
        var requests: [CheckedContinuation<FamilySnapshot, Error>] = []
        var requestArrived: (() -> Void)?
        var dependencies: FamilyStore.Dependencies {
            .init(connection: { self.savedConnection }, cached: { _ in self.cached },
                  saveConnection: { self.savedConnection = $0 },
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
        XCTAssertNotNil(store.errorMessage); XCTAssertFalse(store.isRefreshing)
    }
    func testCacheFailureCannotShowPreviousFamilyUnderNewConnection() async throws {
        let harness = Harness(), arrived = expectation(description: "pairing")
        harness.savedConnection = try PhoneConnection.parse(pairing("Old")); harness.cached = DemoFamily.snapshot()
        harness.requestArrived = { arrived.fulfill() }
        var dependencies = harness.dependencies
        dependencies.saveSnapshot = { _, _ in throw PhoneStorage.StorageError.appGroup }
        let store = FamilyStore(dependencies: dependencies)
        let task = Task { try await store.connect(pairing("New")) }
        await fulfillment(of: [arrived], timeout: 2)
        harness.requests[0].resume(returning: DemoFamily.snapshot())
        do { try await task.value; XCTFail("Cache error should be surfaced") } catch {}
        XCTAssertEqual(store.connection?.familyName, "New"); XCTAssertNil(store.snapshot)
    }
}
