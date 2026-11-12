import XCTest

@MainActor final class ParentSessionTests: XCTestCase {
    func testLockedAppDoesNotRequestAuthorizationOrContactService() async throws {
        let store = ParentStore(authorizationFactory: { XCTFail("Authorization must be explicit"); return TestGrant() }, transport: { _ in XCTFail("Network request while locked"); return Data() })
        XCTAssertFalse(store.isUnlocked); XCTAssertNil(store.state)
        await store.refresh()
        do { _ = try await store.raw("GET", "/admin/state"); XCTFail("Locked request accepted") } catch {}
        XCTAssertNil(store.state); XCTAssertFalse(store.connected)
    }
    func testCanceledOrDeniedParentAuthorizationLeavesAnyLoginLocked() async {
        for failure in ["Unlock canceled.", "Administrator credentials were denied."] {
            let store = ParentStore(authorizationFactory: { throw ParentError.message(failure) }, transport: { _ in XCTFail("Denied authorization contacted service"); return Data() })
            await store.unlock()
            XCTAssertFalse(store.isUnlocked); XCTAssertNil(store.state); XCTAssertFalse(store.busy)
            XCTAssertEqual(store.error, failure)
        }
    }
    func testAnyLoginCanUnlockWithParentGrantAndSendsNoBearer() async throws {
        let grant = TestGrant(), requests = RequestRecorder()
        // There is intentionally no current-login administrator gate or saved token.
        let store = ParentStore(authorizationFactory: { grant }, transport: { data in requests.append(data); return Self.emptyState })
        await store.unlock()
        XCTAssertTrue(store.isUnlocked); XCTAssertTrue(store.connected); XCTAssertNotNil(store.state)
        let request = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(requests.values.first)) as? [String: Any])
        XCTAssertEqual(request["authorizationExternalForm"] as? String, grant.externalForm)
        XCTAssertEqual(Set(request.keys), Set(["op", "method", "path", "authorizationExternalForm"]))
        XCTAssertEqual(request["op"] as? String, "parentHTTP")
        XCTAssertEqual(request["method"] as? String, "GET")
        XCTAssertEqual(request["path"] as? String, "/v1/admin/state")
        XCTAssertNil(request["authorization"])
        store.lock()
        XCTAssertTrue(grant.invalidated); XCTAssertFalse(store.isUnlocked)
        XCTAssertNil(store.state); XCTAssertTrue(store.balances.isEmpty); XCTAssertEqual(store.selectedChild, "")
        await store.refresh()
        XCTAssertEqual(requests.values.count, 1)
    }
    func testDaemonAuthorizationExpiryRelocksAndClearsConfiguration() async {
        let grant = TestGrant()
        let denied = Data(#"{"status":403,"body":{"error":{"code":"administrator_required","message":"Unlock required"}}}"#.utf8)
        let store = ParentStore(authorizationFactory: { grant }, transport: { _ in denied })
        await store.unlock()
        XCTAssertFalse(store.isUnlocked); XCTAssertNil(store.state); XCTAssertTrue(grant.invalidated)
        XCTAssertNotNil(store.error)
    }
    func testInFlightReplyCannotRestoreConfigurationAfterLock() async {
        let grant = TestGrant(), reply = DelayedReply()
        let store = ParentStore(authorizationFactory: { grant }, transport: { _ in await reply.response() })
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
        let store = ParentStore(authorizationFactory: { started.fulfill(); proceed.wait(); return grant }, transport: { _ in XCTFail("Late authorization contacted service"); return Data() })
        let unlock = Task { await store.unlock() }
        await fulfillment(of: [started], timeout: 2)
        store.lock(); proceed.signal()
        await unlock.value
        XCTAssertFalse(store.isUnlocked); XCTAssertNil(store.state); XCTAssertTrue(grant.invalidated)
    }
    func testSystemAuthorizationTakingFocusDoesNotCancelUnlock() async {
        let started = expectation(description: "Authorization began"), proceed = DispatchSemaphore(value: 0), grant = TestGrant()
        let store = ParentStore(authorizationFactory: { started.fulfill(); proceed.wait(); return grant }, transport: { _ in Self.emptyState })
        let unlock = Task { await store.unlock() }
        await fulfillment(of: [started], timeout: 2)
        store.applicationDidResignActive()
        XCTAssertTrue(store.busy)
        proceed.signal()
        await unlock.value
        XCTAssertTrue(store.isUnlocked); XCTAssertTrue(store.connected); XCTAssertFalse(grant.invalidated)
        store.lock()
    }
    func testSwitchingAppsAfterUnlockClearsConfigurationAndInvalidatesGrant() async {
        let grant = TestGrant()
        let store = ParentStore(authorizationFactory: { grant }, transport: { _ in Self.emptyState })
        await store.unlock()
        XCTAssertTrue(store.isUnlocked)
        store.applicationDidResignActive()
        XCTAssertFalse(store.isUnlocked); XCTAssertNil(store.state); XCTAssertFalse(store.connected)
        XCTAssertTrue(grant.invalidated)
    }
    func testSwitchingChildrenDiscardsPreviousChildsDelayedBalance() async throws {
        let replies = RefreshReplies()
        let store = ParentStore(authorizationFactory: { TestGrant() }, transport: { try await replies.response($0) })
        await store.unlock()
        XCTAssertEqual(store.balances.first?.remainingSeconds, 21600)
        await replies.pause("/v1/children/alice/balances")
        let older = Task { await store.refresh() }
        await replies.waitForPending(1)
        store.selectedChild = "bob"
        XCTAssertTrue(store.balances.isEmpty, "Do not display Alice's balance under Bob's name while loading")
        await store.refresh()
        XCTAssertEqual(store.balances.first?.remainingSeconds, 1800)
        await replies.finish(0, with: Self.balance("alice", remaining: 0))
        await older.value
        XCTAssertEqual(store.selectedChild, "bob")
        XCTAssertEqual(store.balances.first?.remainingSeconds, 1800)
        store.lock()
    }
    func testOlderRefreshCannotRestoreBalanceAfterNewerRefresh() async throws {
        let replies = RefreshReplies()
        let store = ParentStore(authorizationFactory: { TestGrant() }, transport: { try await replies.response($0) })
        await store.unlock()
        await replies.pause("/v1/children/alice/balances")
        let older = Task { await store.refresh() }
        await replies.waitForPending(1)
        let newer = Task { await store.refresh() }
        await replies.waitForPending(2)
        await replies.finish(1, with: Self.balance("alice", remaining: 30))
        await newer.value
        await replies.finish(0, with: Self.balance("alice", remaining: 21600))
        await older.value
        XCTAssertEqual(store.balances.first?.remainingSeconds, 30)
        store.lock()
    }
    func testOlderRefreshFailureDoesNotDisconnectRecoveredView() async throws {
        let replies = RefreshReplies()
        let store = ParentStore(authorizationFactory: { TestGrant() }, transport: { try await replies.response($0) })
        await store.unlock()
        await replies.pause("/v1/children/alice/balances")
        let older = Task { await store.refresh() }
        await replies.waitForPending(1)
        let newer = Task { await store.refresh() }
        await replies.waitForPending(2)
        await replies.finish(1, with: Self.balance("alice", remaining: 30))
        await newer.value
        await replies.finish(0, with: Data(#"{"status":503,"body":{"message":"Old connection failed"}}"#.utf8))
        await older.value
        XCTAssertTrue(store.connected)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.balances.first?.remainingSeconds, 30)
        store.lock()
    }
    func testMutationReturnsSavedRevisionWhenAnotherRefreshSupersedesItsRefresh() async throws {
        let replies = RefreshReplies()
        let store = ParentStore(authorizationFactory: { TestGrant() }, transport: { try await replies.response($0) })
        await store.unlock()
        await replies.pause("/v1/admin/state")
        let save = Task { try await store.mutate("PUT", "/admin/settings", [:], expectedRevision: 1) }
        await replies.waitForPending(1)
        let latest = Task { await store.refresh() }
        await replies.waitForPending(2)
        await replies.finish(0, with: Self.household)
        let saved = try await save.value
        // Editors must take their next expected revision from the save reply,
        // even while the asynchronously refreshed household still has old data.
        XCTAssertEqual(saved["policyRevision"] as? Int, 2)
        XCTAssertEqual(store.state?.policyRevision, 1)
        await replies.finish(1, with: Data(String(decoding: Self.household, as: UTF8.self).replacingOccurrences(of: "\"policyRevision\":1", with: "\"policyRevision\":2").utf8))
        await latest.value
        XCTAssertEqual(store.state?.policyRevision, 2)
        store.lock()
    }
    func testPhoneStatusPollsOnlyItsEndpointAndCannotOverlap() async {
        let replies = PhoneReplies()
        let store = ParentStore(authorizationFactory: { TestGrant() }, transport: { try await replies.response($0) })
        await store.unlock(); await replies.pause(["GET"])
        let first = Task { await store.refreshPhoneDashboard() }
        await replies.waitForPending(1)
        await store.refreshPhoneDashboard()
        let count = await replies.phoneRequestCount
        XCTAssertEqual(count, 1)
        await replies.finish(0, with: Self.phoneState())
        await first.value
        XCTAssertEqual(store.phoneStatus?.title, "Connecting…")
        XCTAssertFalse(store.phoneServiceUnavailable)
        let stateReads = await replies.stateReads
        XCTAssertEqual(stateReads, 1, "Phone polling must not refresh policy and child balances.")
        store.lock(); await store.refreshPhoneDashboard()
        let afterLock = await replies.phoneRequestCount
        XCTAssertEqual(afterLock, 1)
    }
    func testLatePhoneStatusCannotRestoreSharingAfterDisconnectOrLock() async throws {
        let replies = PhoneReplies()
        let store = ParentStore(authorizationFactory: { TestGrant() }, transport: { try await replies.response($0) })
        await store.unlock(); await replies.pause(["GET"])
        let first = Task { await store.refreshPhoneDashboard() }
        await replies.waitForPending(1)
        try await store.disconnectPhoneDashboard()
        await replies.finish(0, with: Self.phoneState())
        await first.value
        XCTAssertEqual(store.phoneStatus?.configured, false)
        let second = Task { await store.refreshPhoneDashboard() }
        await replies.waitForPending(2)
        store.lock()
        await replies.finish(1, with: Self.phoneState())
        await second.value
        XCTAssertNil(store.phoneStatus); XCTAssertFalse(store.phoneServiceUnavailable)
    }
    func testPhoneStatusSeparatesLocalServiceFailureFromCloudFailure() async {
        let replies = PhoneReplies()
        let store = ParentStore(authorizationFactory: { TestGrant() }, transport: { try await replies.response($0) })
        await store.unlock(); await replies.failLocalRead(true)
        await store.refreshPhoneDashboard()
        XCTAssertTrue(store.phoneServiceUnavailable)
        XCTAssertNil(store.phoneStatus)
        await replies.failLocalRead(false)
        await store.refreshPhoneDashboard()
        XCTAssertFalse(store.phoneServiceUnavailable)
        XCTAssertEqual(store.phoneStatus?.problem, .connection)
        XCTAssertEqual(store.phoneStatus?.recovery, .retry)
        store.lock()
    }
    func testCancelledPhonePollCannotChangeDisplayedStatus() async {
        let replies = PhoneReplies()
        let store = ParentStore(authorizationFactory: { TestGrant() }, transport: { try await replies.response($0) })
        await store.unlock(); await replies.pause(["GET"])
        let refresh = Task { await store.refreshPhoneDashboard() }
        await replies.waitForPending(1); refresh.cancel()
        await replies.finish(0, with: Self.phoneState())
        await refresh.value
        XCTAssertNil(store.phoneStatus); XCTAssertFalse(store.phoneServiceUnavailable)
        store.lock()
    }
    func testPollStartedDuringConnectionCannotOverwriteTheSavedConnection() async throws {
        let replies = PhoneReplies()
        let store = ParentStore(authorizationFactory: { TestGrant() }, transport: { try await replies.response($0) })
        await store.unlock(); await replies.pause(["PUT", "GET"])
        let document = #"{"schemaVersion":1,"endpoint":"https://quota.example.org","deviceId":"mac-1","deviceName":"Kids Mac","writeToken":"test-token"}"#
        let connect = Task { try await store.connectPhoneDashboard(document) }
        await replies.waitForPending(1)
        let refresh = Task { await store.refreshPhoneDashboard() }
        await replies.waitForPending(2)
        await replies.finish(0, with: Self.phoneState())
        try await connect.value
        await replies.finish(1, with: Self.phoneState(configured: false))
        await refresh.value
        XCTAssertEqual(store.phoneStatus?.configured, true)
        XCTAssertEqual(store.phoneStatus?.title, "Connecting…")
        store.lock()
    }
    nonisolated fileprivate static func phoneState(configured: Bool = true, cloudProblem: Bool = false) -> Data {
        var body: [String: Any] = ["configured": configured, "uploading": false, "intervalSeconds": 300]
        if cloudProblem { body["problemKind"] = "connection"; body["lastError"] = "Dashboard unreachable" }
        return try! JSONSerialization.data(withJSONObject: ["status": 200, "body": body])
    }
    nonisolated fileprivate static let household = Data(#"{"status":200,"body":{"policyRevision":1,"policy":{"children":[{"id":"alice","displayName":"Alice"},{"id":"bob","displayName":"Bob"}],"services":[],"applicationBindings":[],"quotas":[],"reset":{"weekday":"monday","localTime":"00:00","timeZone":"America/Chicago"}},"clients":[]}}"#.utf8)
    nonisolated fileprivate static func balance(_ child: String, remaining: Int) -> Data {
        try! JSONSerialization.data(withJSONObject: ["status": 200, "body": ["items": [["quotaId": "\(child)-chess", "serviceId": "chesscom", "limitSeconds": 21600, "usedSeconds": 21600 - remaining, "remainingSeconds": remaining, "quotaState": remaining == 0 ? "exhausted" : "available", "coverage": "complete", "periodEnd": "2026-11-16T06:00:00Z"]]]])
    }
    nonisolated fileprivate static let emptyState = Data(#"{"status":200,"body":{"policyRevision":1,"policy":{"children":[],"services":[],"applicationBindings":[],"quotas":[],"reset":{"weekday":"monday","localTime":"00:00","timeZone":"America/Chicago"}},"clients":[]}}"#.utf8)
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

private actor RefreshReplies {
    private var pausedPath: String?
    private var pending: [CheckedContinuation<Data, Never>?] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func pause(_ path: String) { pausedPath = path }
    func response(_ data: Data) async throws -> Data {
        let request = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let path = request["path"] as! String
        if request["method"] as? String == "PUT" { return Data(#"{"status":200,"body":{"policyRevision":2}}"#.utf8) }
        if path == pausedPath {
            return await withCheckedContinuation { continuation in
                pending.append(continuation)
                let ready = waiters.filter { $0.0 <= pending.count }
                waiters.removeAll { $0.0 <= pending.count }
                ready.forEach { $0.1.resume() }
            }
        }
        if path == "/v1/admin/state" { return ParentSessionTests.household }
        return ParentSessionTests.balance(path.contains("/bob/") ? "bob" : "alice", remaining: path.contains("/bob/") ? 1800 : 21600)
    }
    func waitForPending(_ count: Int) async {
        if pending.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func finish(_ index: Int, with data: Data) { pending[index]?.resume(returning: data); pending[index] = nil }
}

private actor PhoneReplies {
    private var pausedMethods: Set<String> = []
    private var failRead = false
    private var pending: [CheckedContinuation<Data, Never>?] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var stateReads = 0
    private(set) var phoneRequestCount = 0
    func pause(_ methods: Set<String>) { pausedMethods = methods }
    func failLocalRead(_ value: Bool) { failRead = value }
    func response(_ data: Data) async throws -> Data {
        let request = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        if request["path"] as? String == "/v1/admin/state" { stateReads += 1; return ParentSessionTests.emptyState }
        phoneRequestCount += 1
        let method = request["method"] as! String
        if method == "GET" && failRead { throw ParentError.message("Local service unavailable") }
        if pausedMethods.contains(method) {
            return await withCheckedContinuation { continuation in
                pending.append(continuation)
                let ready = waiters.filter { $0.0 <= pending.count }
                waiters.removeAll { $0.0 <= pending.count }; ready.forEach { $0.1.resume() }
            }
        }
        return ParentSessionTests.phoneState(configured: method != "DELETE", cloudProblem: method == "GET")
    }
    func waitForPending(_ count: Int) async {
        if pending.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func finish(_ index: Int, with data: Data) { pending[index]?.resume(returning: data); pending[index] = nil }
}
