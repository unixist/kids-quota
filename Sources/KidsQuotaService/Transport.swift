import Foundation
import Darwin
import Security

public enum TransportError: Error { case invalidRequest, tooLarge, disconnected, system(String), unauthorized }

/// One request per connection; strict framing prevents ambiguous HTTP body parsing.
public enum HTTPParser {
    public static let maximumBody = 65_536
    public static func parse(_ data: Data) throws -> HTTPRequest? {
        guard data.count <= maximumBody + 16_384 else { throw TransportError.tooLarge }
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 16_384 { throw TransportError.tooLarge }; return nil
        }
        guard boundary.lowerBound <= 16_384,
              let head = String(data: data[..<boundary.lowerBound], encoding: .utf8) else { throw TransportError.invalidRequest }
        let lines = head.components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard start.count == 3, start[2] == "HTTP/1.1", start[1].hasPrefix("/"),
              ["GET","POST","PATCH","PUT","DELETE"].contains(String(start[0])) else { throw TransportError.invalidRequest }
        var headers: [String:String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { throw TransportError.invalidRequest }
            let name = String(line[..<colon]).lowercased()
            guard name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }), headers[name] == nil else { throw TransportError.invalidRequest }
            let value = line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces)
            guard !value.unicodeScalars.contains(where: {$0.value < 32 || $0.value == 127}) else { throw TransportError.invalidRequest }
            headers[name] = value
        }
        guard headers["host"] != nil, headers["transfer-encoding"] == nil, headers["expect"] == nil else { throw TransportError.invalidRequest }
        let length: Int
        if let value = headers["content-length"] {
            guard !value.isEmpty, value.utf8.allSatisfy({(48...57).contains($0)}), let n = Int(value), n <= maximumBody else { throw TransportError.tooLarge }; length = n
        } else {
            guard ["GET","DELETE"].contains(String(start[0])) else { throw TransportError.invalidRequest }; length = 0
        }
        let available = data.count - boundary.upperBound
        guard available <= length else { throw TransportError.invalidRequest }
        guard available == length else { return nil }
        return HTTPRequest(method:String(start[0]),path:String(start[1]),headers:headers,body:Data(data[boundary.upperBound...]))
    }
    public static func encode(_ response: HTTPResponse) -> Data {
        let reason: [Int:String] = [200:"OK",201:"Created",400:"Bad Request",401:"Unauthorized",403:"Forbidden",404:"Not Found",409:"Conflict",413:"Content Too Large",422:"Unprocessable Content",429:"Too Many Requests",503:"Service Unavailable"]
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count); headers["Connection"] = "close"
        var data = Data("HTTP/1.1 \(response.status) \(reason[response.status] ?? "Error")\r\n".utf8)
        for key in headers.keys.sorted() { data.append(Data("\(key): \(headers[key]!)\r\n".utf8)) }
        data.append(Data("\r\n".utf8)); data.append(response.body); return data
    }
}

public enum SocketIO {
    public static func configure(_ fd: Int32) {
        var timeout = timeval(tv_sec:3,tv_usec:0), one: Int32 = 1
        setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,socklen_t(MemoryLayout<Int32>.size))
    }
    public static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < data.count {
                let n = Darwin.write(fd,bytes.baseAddress!.advanced(by:sent),data.count-sent)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw TransportError.disconnected }; sent += n
            }
        }
    }
    public static func readLine(_ fd: Int32) throws -> Data {
        var result = Data(), buffer = [UInt8](repeating:0,count:4096)
        while result.count <= 65_536 {
            let count = Darwin.read(fd,&buffer,buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw TransportError.disconnected }
            result.append(contentsOf:buffer.prefix(count))
            guard result.count <= 65_536 else {throw TransportError.tooLarge}
            if let newline = result.firstIndex(of:10) {
                guard newline == result.count-1 else {throw TransportError.invalidRequest}
                return Data(result[..<newline])
            }
        }
        throw TransportError.tooLarge
    }
    public static func unixAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue:address.sun_path) else { throw TransportError.system("Socket path is too long.") }
        withUnsafeMutableBytes(of:&address.sun_path) {$0.copyBytes(from:bytes)}
        return address
    }
    public static func request(_ object: [String:Any], path: String = "/var/run/kids-quota.sock", development: Bool = false) throws -> [String:Any] {
        if !development {
            var info = stat()
            guard lstat(path,&info) == 0, info.st_uid == 0, (info.st_mode & S_IFMT) == S_IFSOCK else {throw TransportError.unauthorized}
        }
        let fd = socket(AF_UNIX,SOCK_STREAM,0); guard fd >= 0 else {throw TransportError.disconnected}
        defer {close(fd)}; configure(fd)
        var address = try unixAddress(path)
        let connected = withUnsafePointer(to:&address) {p in p.withMemoryRebound(to:sockaddr.self,capacity:1) {Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
        guard connected == 0 else {throw TransportError.disconnected}
        var peerUID: uid_t = 0, peerGID: gid_t = 0
        guard getpeereid(fd,&peerUID,&peerGID) == 0, peerUID == (development ? getuid() : 0) else {throw TransportError.unauthorized}
        var data = try JSONSerialization.data(withJSONObject:object); data.append(10)
        guard data.count <= 65_536 else {throw TransportError.tooLarge}
        try write(data,to:fd)
        guard let reply = try JSONSerialization.jsonObject(with:readLine(fd)) as? [String:Any] else {throw TransportError.invalidRequest}
        return reply
    }
}

public struct PeerIdentity { public let uid: UInt32; public let role: String }
public enum PeerVerifier {
    public static func verify(fd: Int32, team: String?, development: Bool) throws -> PeerIdentity {
        var uid: uid_t = 0, gid: gid_t = 0, pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getpeereid(fd,&uid,&gid) == 0, getsockopt(fd,SOL_LOCAL,LOCAL_PEERPID,&pid,&size) == 0 else {throw TransportError.unauthorized}
        var path = [CChar](repeating:0,count:4096)
        guard proc_pidpath(pid,&path,UInt32(path.count)) > 0 else {throw TransportError.unauthorized}
        let executable = String(cString:path), basename = URL(fileURLWithPath:executable).lastPathComponent
        let roles = ["kids-quota-agent":"agent","kids-quota-bridge":"bridge","KidsQuotaSafari":"safari","com.kidsquota.app.networkfilter":"filter","Kids Quota":"parent"]
        if development {
            guard uid == getuid(), let role = roles[basename] else {throw TransportError.unauthorized}
            return .init(uid:uid,role:role)
        }
        guard let team else {throw TransportError.unauthorized}
        var info = stat()
        guard stat(executable,&info) == 0, info.st_uid == 0, info.st_mode & 0o022 == 0 else {throw TransportError.unauthorized}
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid as String:pid] as CFDictionary,[],&code) == errSecSuccess, let code else {throw TransportError.unauthorized}
        var identity: CFDictionary?; var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code,[],&staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode,SecCSFlags(rawValue:kSecCSSigningInformation),&identity) == errSecSuccess,
              let signing = identity as? [String:Any], signing[kSecCodeInfoTeamIdentifier as String] as? String == team,
              let identifier = signing[kSecCodeInfoIdentifier as String] as? String else {throw TransportError.unauthorized}
        let identifiers = ["com.kidsquota.agent":"agent","com.kidsquota.bridge":"bridge","com.kidsquota.app.safari":"safari","com.kidsquota.app.networkfilter":"filter","com.kidsquota.app":"parent"]
        guard let role = identifiers[identifier], role != "filter" || uid == 0,
              SecCodeCheckValidity(code,SecCSFlags(rawValue:kSecCSStrictValidate),nil) == errSecSuccess else {throw TransportError.unauthorized}
        if role == "bridge" {
            // A child must not be able to run our signed host directly and forge
            // tab reports. Chrome launches native hosts from its browser process.
            var process = proc_bsdinfo()
            let length = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&process,length) == length,
                  NativeIdentity.processMatches(pid:Int32(process.pbi_ppid),requirement:"anchor apple generic and identifier \"com.google.Chrome\" and certificate leaf[subject.OU] = \"EQHXZ8M8AV\"") else {throw TransportError.unauthorized}
        }
        return .init(uid:uid,role:role)
    }
}

public final class LocalServers {
    private let controller: ServiceController
    private let path: String
    private let development: Bool
    private let team: String?
    private var listeners: [Int32] = []
    private var ownsSocket = false
    private let slots = DispatchSemaphore(value:32)
    public init(controller: ServiceController, socketPath: String, development: Bool) {
        self.controller=controller; path=socketPath; self.development=development; team=NativeIdentity.ownTeam()
    }
    public func start() throws {
        try startHTTP(); do {try startUnix()} catch {stop(); throw error}
    }
    public func stop() {for fd in listeners {shutdown(fd,SHUT_RDWR);close(fd)};listeners=[]; if ownsSocket {unlink(path);ownsSocket=false}}
    private func serve(_ fd: Int32, handler: @escaping (Int32) -> Void) throws {
        guard listen(fd,32) == 0 else {close(fd);throw TransportError.system("Could not listen.")}
        listeners.append(fd)
        DispatchQueue.global(qos:.utility).async { [self] in
            while true {
                let client = accept(fd,nil,nil)
                if client < 0 {if errno == EINTR {continue};return}
                guard slots.wait(timeout:.now()) == .success else {close(client);continue}
                SocketIO.configure(client)
                DispatchQueue.global(qos:.utility).async { [self] in defer {close(client);slots.signal()};handler(client) }
            }
        }
    }
    private func startHTTP() throws {
        let fd=socket(AF_INET,SOCK_STREAM,0);guard fd >= 0 else {throw TransportError.system("Socket failed.")}
        var one:Int32=1;setsockopt(fd,SOL_SOCKET,SO_REUSEADDR,&one,socklen_t(MemoryLayout<Int32>.size))
        var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family=sa_family_t(AF_INET)
        address.sin_port=UInt16(controller.port).bigEndian;address.sin_addr=in_addr(s_addr:inet_addr("127.0.0.1"))
        let bound=withUnsafePointer(to:&address) {$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}
        guard bound==0 else {close(fd);throw TransportError.system("Cannot bind localhost port \(controller.port).")}
        try serve(fd) { [controller] client in
            do {
                var data=Data(),buffer=[UInt8](repeating:0,count:8192)
                while true {
                    let n=Darwin.read(client,&buffer,buffer.count)
                    if n<0 && errno==EINTR {continue};guard n>0 else {return}
                    data.append(contentsOf:buffer.prefix(n))
                    if let request=try HTTPParser.parse(data) {try SocketIO.write(HTTPParser.encode(controller.handle(request)),to:client);return}
                }
            } catch {try? SocketIO.write(HTTPParser.encode(.init(status:400,json:["error":["code":"bad_request","message":"Malformed HTTP request."]])),to:client)}
        }
    }
    private func startUnix() throws {
        // Recover only our own stale socket after a crash, never an active server or a file.
        var info = stat()
        if lstat(path,&info) == 0 {
            guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK else {throw TransportError.system("Socket path is occupied by an unexpected object.")}
            let probe=socket(AF_UNIX,SOCK_STREAM,0)
            guard probe>=0 else {throw TransportError.disconnected}
            var destination=try SocketIO.unixAddress(path)
            let result=withUnsafePointer(to:&destination){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.connect(probe,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
            let failure=errno;close(probe)
            guard result != 0, failure == ECONNREFUSED else {throw TransportError.system("A service already owns this socket.")}
            guard unlink(path)==0 else {throw TransportError.system("Cannot remove stale socket.")}
        }
        let fd=socket(AF_UNIX,SOCK_STREAM,0);guard fd>=0 else {throw TransportError.system("Socket failed.")}
        var address=try SocketIO.unixAddress(path)
        let bound=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
        guard bound==0 else {close(fd);throw TransportError.system("Cannot bind native socket.")}
        ownsSocket=true
        chmod(path,development ? 0o600 : 0o666)
        try serve(fd) { [self] client in
            do {
                let peer=try PeerVerifier.verify(fd:client,team:team,development:development)
                guard let object=try JSONSerialization.jsonObject(with:SocketIO.readLine(client)) as? [String:Any] else {throw TransportError.invalidRequest}
                var reply=try JSONSerialization.data(withJSONObject:controller.native(object,uid:peer.uid,role:peer.role));reply.append(10)
                try SocketIO.write(reply,to:client)
            } catch {try? SocketIO.write(Data("{\"error\":\"Native connection rejected.\",\"configured\":false}\n".utf8),to:client)}
        }
    }
}

public enum NativeFrame {
    public static func read(from handle: FileHandle) throws -> Data? {
        var header=Data()
        while header.count<4 {
            guard let bytes=try handle.read(upToCount:4-header.count),!bytes.isEmpty else {
                if header.isEmpty {return nil};throw TransportError.invalidRequest
            }
            header.append(bytes)
        }
        let length=header.enumerated().reduce(UInt32(0)) {$0 | UInt32($1.element) << (8*$1.offset)}
        guard length>0,length<=65_536 else {throw TransportError.tooLarge}
        var result=Data()
        while result.count<Int(length) {
            guard let bytes=try handle.read(upToCount:Int(length)-result.count),!bytes.isEmpty else {throw TransportError.disconnected};result.append(bytes)
        }
        return result
    }
    public static func encode(_ data: Data) throws -> Data {
        guard data.count<=65_536 else {throw TransportError.tooLarge}
        var size=UInt32(data.count).littleEndian
        var result=withUnsafeBytes(of:&size){Data($0)};result.append(data);return result
    }
}
