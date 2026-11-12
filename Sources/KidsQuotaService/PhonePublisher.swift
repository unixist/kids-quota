import Foundation
import CoreFoundation
import Darwin

/// A device write credential. This value is never returned by a status endpoint.
public struct PhoneConnection: Codable, Equatable {
    public let schemaVersion: Int
    public let endpoint: String
    public let deviceId: String
    public let deviceName: String
    public let writeToken: String

    public static func parse(_ data: Data) throws -> PhoneConnection {
        guard data.count <= 16_384,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["schemaVersion", "endpoint", "deviceId", "deviceName", "writeToken"],
              let version = object["schemaVersion"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              let endpoint = object["endpoint"] as? String, let deviceId = object["deviceId"] as? String,
              let deviceName = object["deviceName"] as? String, let token = object["writeToken"] as? String,
              validID(deviceId), validText(deviceName),
              token.range(of: "\\A[A-Za-z0-9_-]{32,512}\\z", options: .regularExpression) != nil,
              var url = URLComponents(string: endpoint), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", endpoint.count <= 2048,
              !endpoint.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              validPort(url), url.url != nil else {
            throw APIError(422, "invalid_phone_connection", "Use a complete Mac connection document with an HTTPS server address.")
        }
        url.path = ""
        return .init(schemaVersion: 1, endpoint: url.string!, deviceId: deviceId, deviceName: deviceName, writeToken: token)
    }

    static func validID(_ value: String) -> Bool {
        value.range(of: "\\A[A-Za-z0-9_-]{1,100}\\z", options: .regularExpression) != nil
    }
    static func validPort(_ components: URLComponents) -> Bool {
        guard let representation = components.string else { return false }
        if let range = components.rangeOfPort {
            let raw = representation[range]
            return !raw.isEmpty && raw.utf8.allSatisfy { (48...57).contains($0) }
                && Int(raw).map { (1...65535).contains($0) } == true
        }
        return !representation.trimmingCharacters(in: CharacterSet(charactersIn: "/")).hasSuffix(":")
    }
    static func validText(_ value: String) -> Bool {
        !value.isEmpty && value.utf16.count <= 100 && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

public enum PhonePublisherProblem: String, Encodable {
    case connection, authorization, endpoint
    case clockConflict = "clock_conflict", invalidUpdate = "invalid_update", localStorage = "local_storage"

    var message: String {
        switch self {
        case .connection: return "This Mac couldn't send updates to your phone dashboard. It will retry automatically. Local quotas still work."
        case .authorization: return "This Mac's connection is no longer accepted. Reconnect with a new Mac connection file."
        case .endpoint: return "The dashboard address is unavailable or has moved. Reconnect using the correct Mac connection file."
        case .clockConflict: return "Check this Mac's date and time, and make sure each Mac uses its own connection file. The last shared balances are unchanged."
        case .invalidUpdate: return "This update couldn't be shared. Check your dashboard setup and that Kids Quota is up to date. The last shared balances are unchanged."
        case .localStorage: return "This Mac's saved connection couldn't be read. Reconnect with its Mac connection file. Local quotas still work."
        }
    }
    static func response(_ code: Int) -> PhonePublisherProblem {
        if [408, 429].contains(code) || (500...599).contains(code) { return .connection }
        if [401, 403].contains(code) { return .authorization }
        if (300...399).contains(code) || code == 404 { return .endpoint }
        if code == 409 { return .clockConflict }
        return .invalidUpdate
    }
}

public struct PhonePublisherStatus: Encodable {
    public var configured = false
    public var endpoint: String?
    public var deviceName: String?
    public var uploading = false
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    public var lastError: String?
    public var problemKind: PhonePublisherProblem?
    public let intervalSeconds = 300
}

/// The daemon owns this file; atomic replacement never creates a readable token file.
final class PhoneConnectionStore {
    let file: URL
    private let owner: uid_t
    init(directory: URL) { file = directory.appendingPathComponent("phone-connection.json"); owner = getuid() }

    func load() throws -> PhoneConnection? {
        var info = stat()
        guard lstat(file.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw unavailable()
        }
        guard info.st_uid == owner, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600, info.st_size <= 16_384 else { throw unavailable() }
        guard let identity = try? LocalInstallTrust.filesystemIdentity(file.path), !identity.hasACL else { throw unavailable() }
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw unavailable() }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_ino == info.st_ino, opened.st_dev == info.st_dev else { throw unavailable() }
        var bytes = [UInt8](repeating: 0, count: 16_385)
        let count = Darwin.read(fd, &bytes, bytes.count)
        guard count >= 0, count <= 16_384 else { throw unavailable() }
        return try PhoneConnection.parse(Data(bytes.prefix(count)))
    }

    func save(_ connection: PhoneConnection) throws {
        let data = try JSONEncoder().encode(connection)
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".phone-connection-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw unavailable() }
        defer { close(fd); unlink(temporary.path) }
        guard fchmod(fd, 0o600) == 0 else { throw unavailable() }
        guard let emptyACL = acl_init(0) else { throw unavailable() }
        defer { acl_free(UnsafeMutableRawPointer(emptyACL)) }
        guard acl_set_fd(fd, emptyACL) == 0 else { throw unavailable() }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw unavailable() }
                offset += count
            }
        }
        guard fsync(fd) == 0, rename(temporary.path, file.path) == 0 else { throw unavailable() }
    }

    func remove() throws {
        guard unlink(file.path) == 0 || errno == ENOENT else { throw unavailable() }
    }
    private func unavailable() -> APIError { .init(503, "phone_storage_unavailable", "Phone connection settings could not be saved or read. Local quotas are unchanged.") }
}

protocol PhoneUploadTask { func cancel() }
extension URLSessionDataTask: PhoneUploadTask {}
enum PhoneUploadFailure: Error { case connection, rejected(Int) }
protocol PhoneUploadTransport {
    func send(_ request: URLRequest, completion: @escaping (Result<Void, PhoneUploadFailure>) -> Void) -> PhoneUploadTask
}

/// Response bodies are discarded as they arrive, never accumulated in the root
/// daemon. A misconfigured server cannot keep a large download alive until timeout.
final class PhoneHTTPSUploadTransport: NSObject, PhoneUploadTransport, URLSessionDataDelegate {
    static let responseByteLimit = 8 * 1024
    private struct PendingResponse {
        let session: URLSession
        let completion: (Result<Void, PhoneUploadFailure>) -> Void
        var status: Int?
        var bytesReceived = 0
        var oversized = false
    }
    private let lock = NSLock()
    private var pending: [ObjectIdentifier: PendingResponse] = [:]
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        super.init()
        self.configuration.timeoutIntervalForRequest = 20
        self.configuration.timeoutIntervalForResource = 20
        self.configuration.waitsForConnectivity = false
        self.configuration.httpShouldSetCookies = false
        self.configuration.urlCache = nil
    }
    func send(_ request: URLRequest, completion: @escaping (Result<Void, PhoneUploadFailure>) -> Void) -> PhoneUploadTask {
        // One session per infrequent update lets completion release the delegate
        // and all transport resources, including after a cancelled connection.
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request)
        lock.lock(); pending[ObjectIdentifier(task)] = .init(session: session, completion: completion); lock.unlock()
        task.resume(); return task
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        guard var state = pending[ObjectIdentifier(dataTask)] else { lock.unlock(); completionHandler(.cancel); return }
        state.status = (response as? HTTPURLResponse)?.statusCode
        state.oversized = response.expectedContentLength > Int64(Self.responseByteLimit)
        pending[ObjectIdentifier(dataTask)] = state
        lock.unlock()
        completionHandler(state.status != nil && !state.oversized ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard var state = pending[ObjectIdentifier(dataTask)] else { lock.unlock(); return }
        if data.count > Self.responseByteLimit - state.bytesReceived { state.oversized = true }
        else { state.bytesReceived += data.count }
        pending[ObjectIdentifier(dataTask)] = state
        lock.unlock()
        if state.oversized { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let state = pending.removeValue(forKey: ObjectIdentifier(task)); lock.unlock()
        guard let state else { return }
        state.session.finishTasksAndInvalidate()
        guard error == nil, !state.oversized, let status = state.status else { state.completion(.failure(.connection)); return }
        state.completion((200..<300).contains(status) ? .success(()) : .failure(.rejected(status)))
    }
    // Never forward a device bearer token to a redirected address.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// State locks never span snapshot production or networking. The quota controller
/// can read status/configure while this queue is waiting for its snapshot lock.
final class PhonePublisher {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.kidsquota.phone-publisher", qos: .utility)
    private let store: PhoneConnectionStore
    private let now: () -> Date
    private let transport: PhoneUploadTransport
    private let snapshot: (PhoneConnection) throws -> Data
    private var connection: PhoneConnection?
    private var current = PhonePublisherStatus()
    private var generation = UUID()
    private var running = false
    private var inFlight = false
    private var pending = false
    private var upload: PhoneUploadTask?
    private var timer: DispatchSourceTimer?

    init(directory: URL, now: @escaping () -> Date, transport: PhoneUploadTransport = PhoneHTTPSUploadTransport(),
         snapshot: @escaping (PhoneConnection) throws -> Data) {
        store = .init(directory: directory); self.now = now; self.transport = transport; self.snapshot = snapshot
        do {
            connection = try store.load()
            current.configured = connection != nil; current.endpoint = connection?.endpoint; current.deviceName = connection?.deviceName
        } catch { current.problemKind = .localStorage; current.lastError = PhonePublisherProblem.localStorage.message }
    }
    var status: PhonePublisherStatus { lock.lock(); defer { lock.unlock() }; return current }

    func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(300), leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.requestPublish() }
        self.timer = timer; timer.resume(); lock.unlock()
    }
    func stop() {
        lock.lock(); running = false; pending = false; generation = UUID()
        let timer = self.timer, upload = self.upload; self.timer = nil; current.uploading = false
        lock.unlock(); timer?.cancel(); upload?.cancel()
    }
    func configure(_ connection: PhoneConnection) throws {
        lock.lock()
        do { try store.save(connection) } catch { lock.unlock(); throw error }
        self.connection = connection; generation = UUID()
        current = PhonePublisherStatus(); current.configured = true
        current.endpoint = connection.endpoint; current.deviceName = connection.deviceName
        let upload = self.upload, shouldPublish = running
        lock.unlock(); upload?.cancel()
        if shouldPublish { requestPublish() }
    }
    func disconnect() throws {
        lock.lock()
        do { try store.remove() } catch { lock.unlock(); throw error }
        connection = nil; generation = UUID(); current = PhonePublisherStatus(); pending = false
        let upload = self.upload
        lock.unlock(); upload?.cancel()
    }
    func requestPublish() { queue.async { [weak self] in self?.begin() } }

    private func begin() {
        lock.lock()
        guard running, let connection else { lock.unlock(); return }
        guard !inFlight else { pending = true; lock.unlock(); return }
        inFlight = true; pending = false; current.uploading = true; current.lastAttempt = now()
        let attempt = generation
        lock.unlock()
        do {
            let body = try snapshot(connection)
            lock.lock(); let valid = running && generation == attempt; lock.unlock()
            guard valid else { finish(attempt, result: nil); return }
            var request = URLRequest(url: URL(string: connection.endpoint + "/v1/devices/" + connection.deviceId + "/snapshot")!)
            request.httpMethod = "PUT"; request.httpBody = body; request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + connection.writeToken, forHTTPHeaderField: "Authorization")
            let task = transport.send(request) { [weak self] result in
                self?.queue.async { [weak self] in self?.finish(attempt, result: result) }
            }
            lock.lock(); upload = task; let cancel = !running || generation != attempt; lock.unlock()
            if cancel { task.cancel() }
        } catch {
            finish(attempt, result: nil, snapshotFailed: true, snapshotTooLarge: (error as? APIError)?.code == "phone_snapshot_too_large")
        }
    }
    private func finish(_ attempt: UUID, result: Result<Void, PhoneUploadFailure>?, snapshotFailed: Bool = false, snapshotTooLarge: Bool = false) {
        lock.lock(); inFlight = false; upload = nil
        if generation == attempt {
            current.uploading = false
            if snapshotFailed { current.problemKind = .invalidUpdate }
            else if let result {
                switch result {
                case .success: current.lastSuccess = now(); current.problemKind = nil
                case .failure(.connection): current.problemKind = .connection
                case .failure(.rejected(let code)): current.problemKind = PhonePublisherProblem.response(code)
                }
            }
            current.lastError = snapshotTooLarge
                ? "This Mac has too much quota data for the phone dashboard. Check the number of children, allowances, and domains in setup. The last shared balances are unchanged."
                : current.problemKind?.message
        }
        let again = pending && running && connection != nil; pending = false
        lock.unlock()
        if again { requestPublish() }
    }
    deinit { timer?.cancel(); upload?.cancel() }
}
