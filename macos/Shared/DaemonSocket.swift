import Foundation
import Darwin

/// One bounded JSON request per connection. The daemon authenticates the kernel peer identity.
enum DaemonSocket {
    static var path: String {
        #if DEBUG
        if ProcessInfo.processInfo.environment["KIDS_QUOTA_DEVELOPMENT"] == "1", let custom = ProcessInfo.processInfo.environment["KIDS_QUOTA_SOCKET"] { return custom }
        #endif
        return "/var/run/kids-quota.sock"
    }
    private static var trustedServerUID: uid_t {
        #if DEBUG
        if ProcessInfo.processInfo.environment["KIDS_QUOTA_DEVELOPMENT"] == "1", ProcessInfo.processInfo.environment["KIDS_QUOTA_SOCKET"] != nil { return getuid() }
        #endif
        return 0
    }
    static func request(_ object: [String: Any]) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.failure("Could not create the service connection.") }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw SocketError.failure("Invalid service socket path.") }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { throw SocketError.failure("Kids Quota service is unavailable.") }
        // Do not trust a socket impersonated by another login account.
        var peerUID: uid_t = 0; var peerGID: gid_t = 0
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == trustedServerUID else { throw SocketError.failure("The service connection is not owned by root.") }
        var payload = try JSONSerialization.data(withJSONObject: object); payload.append(10)
        try payload.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let count = write(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent)
                guard count > 0 else { throw SocketError.failure("Could not send to the service.") }; sent += count
            }
        }
        var response = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
        while response.count <= 1_048_576 {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { throw SocketError.failure("The service did not respond.") }
            response.append(contentsOf: buffer.prefix(count))
            if let end = response.firstIndex(of: 10) {
                guard let value = try JSONSerialization.jsonObject(with: response.prefix(upTo: end)) as? [String: Any] else { throw SocketError.failure("Invalid service response.") }
                return value
            }
        }
        throw SocketError.failure("The service response was too large.")
    }
    enum SocketError: LocalizedError { case failure(String); var errorDescription: String? { if case .failure(let message) = self { return message }; return nil } }
}
