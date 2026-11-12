import XCTest
import Foundation
import Darwin
@testable import KidsQuotaService

/// Local URL loading fixture; no request reaches a network socket.
private final class PhoneResponseURLProtocol: URLProtocol {
    struct Response {
        var status = 200
        var headers: [String: String] = [:]
        var chunks: [Data] = []
        var keepOpen = false
        var started: (() -> Void)?
    }
    private static let lock = NSLock()
    private static var responses: [URL: Response] = [:]
    static func request(_ response: Response) -> URLRequest {
        let url = URL(string: "https://phone-publisher.invalid/" + UUID().uuidString)!
        lock.lock(); responses[url] = response; lock.unlock()
        var request = URLRequest(url: url); request.httpMethod = "PUT"; request.httpBody = Data("{}".utf8)
        return request
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "phone-publisher.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let response = request.url.flatMap { Self.responses.removeValue(forKey: $0) }; Self.lock.unlock()
        guard let response, let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!, cacheStoragePolicy: .notAllowed)
        for chunk in response.chunks { client?.urlProtocol(self, didLoad: chunk) }
        response.started?()
        if !response.keepOpen { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}

final class PhonePublisherTests: XCTestCase {
    private let token = String(repeating: "s", count: 43)
    private func object(_ overrides: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = ["schemaVersion":1,"endpoint":"https://quota.example.org/","deviceId":"mac-1","deviceName":"Kids Mac","writeToken":token]
        value.merge(overrides) { _, new in new }; return value
    }
    private func connection(_ overrides: [String: Any] = [:]) throws -> PhoneConnection {
        try PhoneConnection.parse(JSONSerialization.data(withJSONObject: object(overrides)))
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kids-quota-phone-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private final class FakeTask: PhoneUploadTask {
        var cancelled = false
        func cancel() { cancelled = true }
    }
    private final class FakeTransport: PhoneUploadTransport {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        private var completions: [(Result<Void, PhoneUploadFailure>) -> Void] = []
        var onSend: (() -> Void)?
        let task = FakeTask()
        func send(_ request: URLRequest, completion: @escaping (Result<Void, PhoneUploadFailure>) -> Void) -> PhoneUploadTask {
            lock.lock(); requests.append(request); completions.append(completion); let notify = onSend; lock.unlock()
            notify?(); return task
        }
        var sent: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
        func complete(_ index: Int, _ result: Result<Void, PhoneUploadFailure>) {
            lock.lock(); let completion = completions[index]; lock.unlock(); completion(result)
        }
    }
    private func eventually(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testPairingNormalizesOriginAndRejectsCredentialLeaksAndWrongDocuments() throws {
        XCTAssertEqual(try connection().endpoint, "https://quota.example.org")
        for endpoint in ["http://quota.example.org", "https://user:secret@quota.example.org", "https://quota.example.org/path", "https://quota.example.org?token=secret", "https://quota.example.org#secret", "file:///tmp/secret"] {
            XCTAssertThrowsError(try connection(["endpoint":endpoint])) { error in
                XCTAssertFalse((error as? APIError)?.message.contains(endpoint) ?? true)
            }
        }
        for value: Any in [true, 0, 2, "1"] { XCTAssertThrowsError(try connection(["schemaVersion":value])) }
        for id in ["", "mac/other", "../device", "space id", "mac\n", String(repeating:"a",count:101)] { XCTAssertThrowsError(try connection(["deviceId":id])) }
        for name in ["", "  ", " Space ", "Bad\nName", String(repeating:"n",count:101)] { XCTAssertThrowsError(try connection(["deviceName":name])) }
        for token in ["short", "Bearer secret", String(repeating:"a",count:513), token + "\n"] { XCTAssertThrowsError(try connection(["writeToken":token])) }
        XCTAssertThrowsError(try connection(["readToken":token]))
        XCTAssertThrowsError(try PhoneConnection.parse(Data(repeating:32,count:16_385)))
    }
    func testStoredConnectionIsPrivateReloadableAndRemovable() throws {
        let store = PhoneConnectionStore(directory: try directory())
        XCTAssertNil(try store.load())
        let original = try connection(); try store.save(original)
        var info = stat(); XCTAssertEqual(lstat(store.file.path,&info),0)
        XCTAssertEqual(info.st_mode & 0o777,0o600); XCTAssertEqual(info.st_uid,getuid())
        XCTAssertEqual(try store.load(),original)
        let replacement = try connection(["deviceName":"New Mac"]); try store.save(replacement)
        XCTAssertEqual(try store.load(),replacement)
        try store.remove(); XCTAssertNil(try store.load()); try store.remove()
    }
    func testPairingRejectsEmptyOverflowAndMalformedPorts() throws {
        for port in ["1", "443", "8443", "65535"] {
            XCTAssertEqual(try connection(["endpoint": "https://quota.example.org:" + port]).endpoint, "https://quota.example.org:" + port)
        }
        for port in ["", "0", "-1", "65536", "999999999999999999999", "abc", "443.5"] {
            for suffix in ["", "/"] {
                XCTAssertThrowsError(try connection(["endpoint": "https://quota.example.org:" + port + suffix]))
            }
        }
    }
    func testUnsafeStoredPermissionsAndSymlinksAreRejected() throws {
        let dir = try directory(), store = PhoneConnectionStore(directory: dir)
        try store.save(connection()); XCTAssertEqual(chmod(store.file.path,0o644),0)
        XCTAssertThrowsError(try store.load())
        let publisher = PhonePublisher(directory:dir,now:Date.init,snapshot:{_ in Data()})
        XCTAssertFalse(publisher.status.configured); XCTAssertNotNil(publisher.status.lastError)
        XCTAssertFalse(String(describing:publisher.status).contains(token))
        try store.remove()
        let target = dir.appendingPathComponent("other"); try Data(token.utf8).write(to:target)
        XCTAssertEqual(symlink(target.path,store.file.path),0); XCTAssertThrowsError(try store.load())
        try store.save(connection())
        XCTAssertEqual(try String(contentsOf:target),token, "Atomic save must replace the link without modifying its target.")
        XCTAssertNotNil(try store.load())
    }
    func testExtendedACLIsRejectedAndReconnectionWritesAnACLFreeFile() throws {
        let store = PhoneConnectionStore(directory:try directory()); try store.save(connection())
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/bin/chmod")
        process.arguments = ["+a","everyone allow read",store.file.path]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus,0)
        XCTAssertThrowsError(try store.load())
        try store.save(connection()); XCTAssertNotNil(try store.load())
        XCTAssertFalse(try LocalInstallTrust.filesystemIdentity(store.file.path).hasACL)
    }
    func testPublisherStartsOnlyWhenConfiguredAndKeepsTokenOutOfStatus() throws {
        let transport = FakeTransport(), noSend = expectation(description:"no requests")
        noSend.isInverted = true; transport.onSend = { noSend.fulfill() }
        let publisher = PhonePublisher(directory:try directory(),now:Date.init,transport:transport,snapshot:{_ in Data("{}".utf8)})
        publisher.start(); wait(for:[noSend],timeout:0.05)
        transport.onSend = nil
        try publisher.configure(connection())
        eventually { transport.sent.count == 1 }
        XCTAssertEqual(transport.sent[0].url?.absoluteString,"https://quota.example.org/v1/devices/mac-1/snapshot")
        XCTAssertEqual(transport.sent[0].httpMethod,"PUT")
        XCTAssertEqual(transport.sent[0].value(forHTTPHeaderField:"Authorization"),"Bearer " + token)
        XCTAssertEqual(transport.sent[0].timeoutInterval,20)
        let status = String(decoding:try JSONEncoder().encode(publisher.status),as:UTF8.self)
        XCTAssertFalse(status.contains(token)); XCTAssertFalse(status.contains("writeToken"))
        transport.complete(0,.success(()))
        eventually { publisher.status.lastSuccess != nil }
        XCTAssertNil(publisher.status.lastError); publisher.stop()
    }
    func testConcurrentRefreshesCoalesceAndFailureRetriesWithoutLosingLastSuccess() throws {
        let transport = FakeTransport()
        let publisher = PhonePublisher(directory:try directory(),now:Date.init,transport:transport,snapshot:{_ in Data("{}".utf8)})
        try publisher.configure(connection()); publisher.start()
        eventually { transport.sent.count == 1 }
        for _ in 0..<20 { publisher.requestPublish() }
        Thread.sleep(forTimeInterval:0.02)
        XCTAssertEqual(transport.sent.count,1)
        transport.complete(0,.success(()))
        eventually { transport.sent.count == 2 }
        let success = publisher.status.lastSuccess
        transport.complete(1,.failure(.connection))
        eventually { publisher.status.lastError != nil }
        XCTAssertEqual(publisher.status.lastSuccess,success)
        publisher.requestPublish(); eventually { transport.sent.count == 3 }
        transport.complete(2,.success(())); eventually { publisher.status.lastError == nil }
        publisher.stop()
    }
    func testDisconnectCancelsOutstandingRequestAndIgnoresItsLateSuccess() throws {
        let dir = try directory(), transport = FakeTransport()
        let publisher = PhonePublisher(directory:dir,now:Date.init,transport:transport,snapshot:{_ in Data("{}".utf8)})
        try publisher.configure(connection()); publisher.start()
        eventually { transport.sent.count == 1 }
        publisher.requestPublish(); try publisher.disconnect()
        XCTAssertTrue(transport.task.cancelled); XCTAssertFalse(publisher.status.configured)
        transport.complete(0,.success(())); Thread.sleep(forTimeInterval:0.03)
        XCTAssertNil(publisher.status.lastSuccess); XCTAssertNil(publisher.status.lastError)
        XCTAssertEqual(transport.sent.count,1); XCTAssertNil(try PhoneConnectionStore(directory:dir).load())
        publisher.stop()
    }
    func testFailedReconfigurationPreservesCurrentConnection() throws {
        let dir = try directory(), transport = FakeTransport()
        let publisher = PhonePublisher(directory:dir,now:Date.init,transport:transport,snapshot:{_ in Data("{}".utf8)})
        try publisher.configure(connection())
        try FileManager.default.removeItem(at:dir)
        try Data().write(to:dir)
        XCTAssertThrowsError(try publisher.configure(connection(["deviceName":"Replacement"])))
        XCTAssertEqual(publisher.status.deviceName,"Kids Mac")
    }
    func testReplacingConnectionIgnoresOldFailureAndWaitsForItsCancellation() throws {
        let transport = FakeTransport()
        let publisher = PhonePublisher(directory:try directory(),now:Date.init,transport:transport,snapshot:{_ in Data("{}".utf8)})
        try publisher.configure(connection()); publisher.start(); eventually { transport.sent.count == 1 }
        let replacement = String(repeating:"n",count:43)
        try publisher.configure(connection(["writeToken":replacement,"deviceId":"mac-2"]))
        XCTAssertTrue(transport.task.cancelled)
        Thread.sleep(forTimeInterval:0.02); XCTAssertEqual(transport.sent.count,1)
        transport.complete(0,.failure(.rejected(401)))
        eventually { transport.sent.count == 2 }
        XCTAssertNil(publisher.status.lastError)
        XCTAssertEqual(transport.sent[1].value(forHTTPHeaderField:"Authorization"),"Bearer " + replacement)
        XCTAssertTrue(transport.sent[1].url!.absoluteString.contains("/mac-2/"))
        transport.complete(1,.success(())); eventually { publisher.status.lastSuccess != nil }; publisher.stop()
    }
    func testSnapshotFailureDoesNotUploadPartialDataAndCanRecover() throws {
        let transport = FakeTransport(); var fail = true
        let publisher = PhonePublisher(directory:try directory(),now:Date.init,transport:transport,snapshot:{_ in
            if fail { throw APIError(422,"invalid_snapshot","Invalid private secret") }; return Data("{}".utf8)
        })
        try publisher.configure(connection()); publisher.start()
        eventually { publisher.status.lastError != nil }
        XCTAssertEqual(transport.sent.count,0); XCTAssertFalse(publisher.status.lastError!.contains("secret"))
        fail = false; publisher.requestPublish(); eventually { transport.sent.count == 1 }
        transport.complete(0,.success(())); eventually { publisher.status.lastSuccess != nil }; publisher.stop()
    }
    func testHTTPRedirectIsNeverFollowed() throws {
        let transport = PhoneHTTPSUploadTransport()
        let session = URLSession(configuration:.ephemeral), original = URL(string:"https://quota.example.org")!
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with:original)
        let response = HTTPURLResponse(url:original,statusCode:302,httpVersion:nil,headerFields:["Location":"https://other.example.org"])!
        var request = URLRequest(url:URL(string:"https://other.example.org")!)
        request.setValue("Bearer " + token,forHTTPHeaderField:"Authorization")
        var called = false
        transport.urlSession(session,task:task,willPerformHTTPRedirection:response,newRequest:request) { redirected in called = true; XCTAssertNil(redirected) }
        XCTAssertTrue(called)
    }
    private func streamingTransport() -> PhoneHTTPSUploadTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PhoneResponseURLProtocol.self]
        return PhoneHTTPSUploadTransport(configuration: configuration)
    }
    private func upload(_ response: PhoneResponseURLProtocol.Response, using transport: PhoneHTTPSUploadTransport,
                        file: StaticString = #filePath, line: UInt = #line) -> Result<Void, PhoneUploadFailure>? {
        let completed = expectation(description: "upload finishes once")
        completed.assertForOverFulfill = true
        var result: Result<Void, PhoneUploadFailure>?
        _ = transport.send(PhoneResponseURLProtocol.request(response)) { result = $0; completed.fulfill() }
        wait(for: [completed], timeout: 2)
        XCTAssertNotNil(result, file: file, line: line)
        return result
    }
    func testStreamingTransportRejectsUnknownLengthOversizeForSuccessAndErrorAndRecovers() {
        let transport = streamingTransport()
        for status in [200, 503] {
            let result = upload(.init(status: status, chunks: [Data(repeating: 32, count: 4096), Data(repeating: 32, count: 4096), Data([32])]), using: transport)
            guard case .failure(.connection)? = result else { XCTFail("Oversized streamed bodies must cancel even for HTTP \(status)."); continue }
        }
        guard case .success? = upload(.init(status: 204), using: transport) else { return XCTFail("The next upload must recover after an oversized response.") }
    }
    func testStreamingTransportRejectsDeclaredOversizeWithoutDownloadingBody() {
        let result = upload(.init(headers: ["Content-Length": String(PhoneHTTPSUploadTransport.responseByteLimit + 1)]), using: streamingTransport())
        guard case .failure(.connection)? = result else { return XCTFail("An oversized Content-Length must fail before body delivery.") }
    }
    func testStreamingTransportAcceptsBoundedBodiesAndPreservesHTTPFailures() {
        let transport = streamingTransport()
        let bounded = Data(repeating: 32, count: PhoneHTTPSUploadTransport.responseByteLimit)
        guard case .success? = upload(.init(headers: ["Content-Length": String(bounded.count)], chunks: [bounded]), using: transport) else { return XCTFail("An allowed response should succeed.") }
        for status in [302, 401, 403, 503] {
            let result = upload(.init(status: status, chunks: [Data("error".utf8)]), using: transport)
            guard case .failure(.rejected(let actual))? = result else { XCTFail("HTTP failure must preserve its status."); continue }
            XCTAssertEqual(actual, status)
        }
    }
    func testStreamingTransportCancellationCompletesOnceAndAllowsAnotherUpload() {
        let transport = streamingTransport()
        let started = expectation(description: "response started"), completed = expectation(description: "cancel finishes once")
        completed.assertForOverFulfill = true
        let request = PhoneResponseURLProtocol.request(.init(keepOpen: true, started: { started.fulfill() }))
        let task = transport.send(request) { result in
            guard case .failure(.connection) = result else { XCTFail("Cancelled request must fail."); completed.fulfill(); return }
            completed.fulfill()
        }
        wait(for: [started], timeout: 2); task.cancel(); task.cancel()
        wait(for: [completed], timeout: 2)
        guard case .success? = upload(.init(status: 204), using: transport) else { return XCTFail("A cancelled connection must not block the next upload.") }
    }
}
