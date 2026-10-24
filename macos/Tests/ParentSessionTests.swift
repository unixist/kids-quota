import XCTest

@MainActor final class ParentSessionTests: XCTestCase {
    func testLockedAppDoesNotReadCredentialsOrContactService() async throws {
        let store = ParentStore(isAdministrator: true, credentialReader: { XCTFail("Credentials read while locked"); return "" }, authorizationFactory: { XCTFail("Authorization must be explicit"); return TestGrant() }, transport: { _ in XCTFail("Network request while locked"); return Data() })
        XCTAssertFalse(store.isUnlocked); XCTAssertNil(store.state)
        await store.refresh()
        do { _ = try await store.raw("GET", "/admin/state"); XCTFail("Locked request accepted") } catch {}
        do { try await store.connect("ignored"); XCTFail("Locked credential change accepted") } catch {}
        XCTAssertNil(store.state); XCTAssertFalse(store.connected)
    }
    func testStandardLoginCannotInvokeAdministratorUnlock() async {
        let store = ParentStore(isAdministrator: false, credentialReader: { XCTFail("Standard login read credential"); return "" }, authorizationFactory: { XCTFail("Standard login invoked authorization"); return TestGrant() }, transport: { _ in XCTFail("Standard login contacted service"); return Data() })
        await store.unlock()
        XCTAssertFalse(store.isUnlocked); XCTAssertNil(store.state)
    }
    func testUnlockAttachesAuthorizationAndLockInvalidatesSession() async throws {
        let grant = TestGrant(), requests = RequestRecorder()
        var credentialReads = 0
        let store = ParentStore(isAdministrator: true, credentialReader: { credentialReads += 1; return "test-bearer" }, authorizationFactory: { grant }, transport: { data in requests.append(data); return Self.emptyState })
        XCTAssertEqual(credentialReads, 0)
        await store.unlock()
        XCTAssertTrue(store.isUnlocked); XCTAssertTrue(store.connected); XCTAssertNotNil(store.state)
        XCTAssertEqual(credentialReads, 1)
        let request = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(requests.values.first)) as? [String: Any])
        XCTAssertEqual(request["authorizationExternalForm"] as? String, grant.externalForm)
        XCTAssertEqual(request["authorization"] as? String, "Bearer test-bearer")
        store.lock()
        XCTAssertTrue(grant.invalidated); XCTAssertFalse(store.isUnlocked)
        XCTAssertNil(store.state); XCTAssertTrue(store.balances.isEmpty); XCTAssertEqual(store.selectedChild, "")
        await store.refresh()
        XCTAssertEqual(requests.values.count, 1)
    }
    func testDaemonAuthorizationExpiryRelocksAndClearsConfiguration() async {
        let grant = TestGrant()
        let denied = Data(#"{"status":403,"body":{"error":{"code":"administrator_required","message":"Unlock required"}}}"#.utf8)
        let store = ParentStore(isAdministrator: true, credentialReader: { "test" }, authorizationFactory: { grant }, transport: { _ in denied })
        await store.unlock()
        XCTAssertFalse(store.isUnlocked); XCTAssertNil(store.state); XCTAssertTrue(grant.invalidated)
        XCTAssertNotNil(store.error)
    }
    func testInFlightReplyCannotRestoreConfigurationAfterLock() async {
        let grant = TestGrant(), reply = DelayedReply()
        let store = ParentStore(isAdministrator: true, credentialReader: { "test" }, authorizationFactory: { grant }, transport: { _ in await reply.response() })
        let unlock = Task { await store.unlock() }
        await reply.waitForRequest()
        store.lock()
        await reply.finish(Self.emptyState)
        await unlock.value
        XCTAssertFalse(store.isUnlocked); XCTAssertNil(store.state); XCTAssertFalse(store.connected)
        XCTAssertTrue(grant.invalidated)
    }
    func testClosingDuringAuthorizationDiscardsLateGrant() async {
        let started = expectation(description: "Authorization began"), proceed = DispatchSemaphore(value: 0), grant = TestGrant()
        let store = ParentStore(isAdministrator: true, credentialReader: { XCTFail("Late authorization read credentials"); return "" }, authorizationFactory: { started.fulfill(); proceed.wait(); return grant }, transport: { _ in XCTFail("Late authorization contacted service"); return Data() })
        let unlock = Task { await store.unlock() }
        await fulfillment(of: [started], timeout: 2)
        store.lock(); proceed.signal()
        await unlock.value
        XCTAssertFalse(store.isUnlocked); XCTAssertNil(store.state); XCTAssertTrue(grant.invalidated)
    }
    nonisolated private static let emptyState = Data(#"{"status":200,"body":{"policyRevision":1,"policy":{"children":[],"services":[],"applicationBindings":[],"quotas":[],"reset":{"weekday":"monday","localTime":"00:00","timeZone":"America/Chicago"}},"clients":[]}}"#.utf8)
}

private final class TestGrant: ParentAuthorizationSession, @unchecked Sendable {
    let externalForm = Data("test-authorization".utf8).base64EncodedString()
    private let lock = NSLock(); private var ended = false
    var invalidated: Bool { lock.lock(); defer { lock.unlock() }; return ended }
    func invalidate() { lock.lock(); ended = true; lock.unlock() }
}
private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock(); private var storage: [Data] = []
    var values: [Data] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ data: Data) { lock.lock(); storage.append(data); lock.unlock() }
}
private actor DelayedReply {
    private var reply: CheckedContinuation<Data, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func response() async -> Data {
        await withCheckedContinuation { continuation in reply = continuation; started?.resume(); started = nil }
    }
    func waitForRequest() async {
        if reply != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(_ value: Data) { reply?.resume(returning: value); reply = nil }
}
