import Foundation
import CoreFoundation
import KidsQuotaCore

public struct HTTPRequest {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data
    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method; self.path = path; self.headers = Dictionary(headers.map { ($0.key.lowercased(),$0.value) }, uniquingKeysWith: { _, b in b }); self.body = body
    }
}
public struct HTTPResponse {
    public var status: Int
    public var body: Data
    public var headers: [String: String] = ["Content-Type":"application/json", "Cache-Control":"no-store", "X-Content-Type-Options":"nosniff"]
    public init(status: Int = 200, json: Any) {
        self.status = status; body = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}
public enum JSONCodec {
    public static func object<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
    }
    public static func decode<T: Decodable>(_ type: T.Type, from value: Any) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: JSONSerialization.data(withJSONObject: value))
    }
}

private struct ForegroundReport {
    var pid: Int32
    var bundle: String
    var active: Bool
    var healthy: Bool
    var lastSeen: Double
}
private struct BrowserReport {
    var hostname: String?
    var focused: Bool
    var sequence: UInt64
    var sessionId: String
    var lastSeen: Double
}

/// All HTTP, native IPC, and timer access is serialized under this lock.
public final class ServiceController {
    private let lock = NSRecursiveLock()
    public let engine: QuotaEngine
    public let credentials: CredentialStore
    public let port: Int
    private let date: () -> Date
    private let monotonic: () -> Double
    private let consoleUID: () -> UInt32?
    private let verifyAccount: (String) throws -> MacOSAccountBinding
    private let verifyApplication: (String) throws -> ApplicationBinding
    private let processMatches: (Int32, String) -> Bool
    private let authorizeParent: (UInt32, String) -> Bool
    private var foreground: [UInt32: ForegroundReport] = [:]
    private var browsers: [String: BrowserReport] = [:]
    private var filterLastSeen: Double?
    private var filterGaps = 0
    private var sequence: UInt64 = 0
    private let collectorSession = UUID().uuidString
    private var rateBuckets: [String: (Double, Int)] = [:]
    private var accountChecks: [String: (time: Double, valid: Bool)] = [:]

    public init(directory: URL, port: Int = 48123, now: @escaping () -> Date = Date.init,
                monotonic: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
                consoleUID: @escaping () -> UInt32? = NativeIdentity.consoleUID,
                verifyAccount: @escaping (String) throws -> MacOSAccountBinding = NativeIdentity.account,
                verifyApplication: @escaping (String) throws -> ApplicationBinding = NativeIdentity.application,
                processMatches: @escaping (Int32, String) -> Bool = NativeIdentity.processMatches,
                authorizeParent: @escaping (UInt32, String) -> Bool = ParentAuthorization.validate) throws {
        self.port = port; date = now; self.monotonic = monotonic; self.consoleUID = consoleUID
        self.verifyAccount = verifyAccount; self.verifyApplication = verifyApplication; self.processMatches = processMatches
        self.authorizeParent = authorizeParent
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try QuotaStore(path: directory.appendingPathComponent("quota.sqlite").path)
        engine = try QuotaEngine(store: store, policy: try store.loadPolicy() ?? Policy.starter())
        credentials = try CredentialStore(directory: directory)
    }

    public func tick() throws {
        lock.lock(); defer { lock.unlock() }
        try reconcile()
        try engine.tick(now: date(), monotonic: monotonic())
    }
    public func stop() throws {
        lock.lock(); defer { lock.unlock() }
        try engine.stop(now: date(), monotonic: monotonic())
    }
    private func requireScope(_ client: ClientCredential, _ scope: String) throws {
        guard client.scopes.contains(scope), scope != "policy:write" || client.administrator else { throw APIError(403,"forbidden","This client lacks the required permission.") }
    }
    private func child(_ id: String, client: ClientCredential) throws -> Child {
        guard client.allows(id), let value = engine.policy.children.first(where: {$0.id == id}) else { throw APIError(404,"not_found","Child not found.") }
        return value
    }
    private func payload(_ request: HTTPRequest, keys: Set<String>) throws -> [String: Any] {
        guard request.body.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any], Set(object.keys).isSubset(of: keys) else {
            throw APIError(400,"bad_request","Invalid JSON request or unexpected fields.")
        }
        return object
    }
    private func requiredString(_ object: [String: Any], _ key: String) throws -> String {
        guard let text = object[key] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw APIError(422,"invalid_policy","Missing \(key).") }
        return text
    }
    private func requiredInteger(_ object: [String: Any], _ key: String) throws -> Int {
        guard let n = object[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue, n.doubleValue >= 0, n.doubleValue <= 604_800_000 else { throw APIError(422,"invalid_policy","Invalid \(key).") }
        return n.intValue
    }
    private func change(_ data: [String: Any], _ edit: (inout Policy) throws -> Void) throws -> Policy {
        guard let expected = data["expectedPolicyRevision"] as? NSNumber, CFGetTypeID(expected) != CFBooleanGetTypeID(), expected.doubleValue == Double(engine.policy.revision) else { throw APIError(409,"conflict","Policy changed; refresh before saving.") }
        var policy = engine.policy
        try edit(&policy)
        let result = try engine.replacePolicy(policy, expectedRevision: expected.intValue, now: date(), monotonic: monotonic())
        accountChecks.removeAll()
        return result
    }
    private func canonicalRules(_ value: Any) throws -> [DomainRule] {
        let rules = try JSONCodec.decode([DomainRule].self, from: value)
        return try rules.map { .init(hostname: try DomainMatcher.canonicalHostname($0.hostname), includeSubdomains: $0.includeSubdomains) }
    }
    public func handle(_ request: HTTPRequest) -> HTTPResponse {
        handle(request, administratorUID: nil)
    }
    /// Only native parent IPC can supply this context; no HTTP header sets it.
    func handle(_ request: HTTPRequest, administratorUID: UInt32?) -> HTTPResponse {
        lock.lock(); defer { lock.unlock() }
        do {
            let host = request.headers["host"] ?? ""
            guard ["127.0.0.1:\(port)","localhost:\(port)"].contains(host), request.headers["origin"] == nil else { throw APIError(403,"forbidden","Unexpected Host or Origin.") }
            let client = try credentials.authenticate(request.headers["authorization"])
            func requireParent() throws {
                try requireScope(client, "policy:write")
                guard administratorUID != nil else {
                    throw APIError(403,"administrator_required","Unlock Kids Quota with administrator credentials to configure it.")
                }
            }
            let m = monotonic(), bucket = rateBuckets[client.id] ?? (m,0)
            let fresh = m - bucket.0 >= 1 ? (m,1) : (bucket.0,bucket.1+1)
            rateBuckets[client.id] = fresh
            guard fresh.1 <= 60 else { throw APIError(429,"rate_limited","Too many requests.") }
            if request.method != "GET" && request.method != "DELETE" {
                guard request.headers["content-type"]?.split(separator:";").first?.lowercased() == "application/json" else { throw APIError(400,"bad_request","Content-Type must be application/json.") }
            }
            let path = request.path.split(separator:"?",maxSplits:1).first.map(String.init) ?? ""
            let parts = path.split(separator:"/").map(String.init)
            guard parts.count >= 2, parts.first == "v1", !path.contains("%"), !path.contains("..") else { throw APIError(404,"not_found","Resource not found.") }
            try tick()
            if request.method == "GET" && parts == ["v1","children"] {
                try requireScope(client,"children:read")
                return .init(json:["policyRevision":engine.policy.revision,"items":engine.policy.children.filter {client.allows($0.id)}.map {["id":$0.id,"displayName":$0.displayName]}])
            }
            if request.method == "GET" && parts == ["v1","services"] {
                try requireScope(client,"services:read")
                let allowed = Set(engine.policy.quotas.filter {client.allows($0.childId)}.map(\.serviceId))
                return .init(json:["policyRevision":engine.policy.revision,"items":try JSONCodec.object(engine.policy.services.filter {client.administrator || allowed.contains($0.id)})])
            }
            if parts.count >= 4 && parts[1] == "children" {
                let c = try child(parts[2],client:client)
                if parts.count == 4 && request.method == "GET" && parts[3] == "balances" {
                    try requireScope(client,"balances:read")
                    return .init(json:try JSONCodec.object(snapshot(childId:c.id)))
                }
                if parts.count == 4 && request.method == "GET" && parts[3] == "quotas" {
                    try requireScope(client,"quotas:read")
                    return .init(json:["policyRevision":engine.policy.revision,"childId":c.id,"items":try JSONCodec.object(engine.policy.quotas.filter {$0.childId == c.id})])
                }
                if parts[3] == "quotas" && request.method == "POST" && parts.count == 4 {
                    try requireParent()
                    let data = try payload(request,keys:["expectedPolicyRevision","serviceId","weeklyLimitSeconds"])
                    let service = try requiredString(data,"serviceId"), seconds = try requiredInteger(data,"weeklyLimitSeconds")
                    guard !engine.policy.quotas.contains(where: {$0.childId == c.id && $0.serviceId == service}) else { throw APIError(409,"conflict","This service is already assigned.") }
                    let quota = Quota(childId:c.id,serviceId:service,weeklyLimitSeconds:seconds)
                    let policy = try change(data) {$0.quotas.append(quota)}
                    return .init(status:201,json:["policyRevision":policy.revision,"quota":try JSONCodec.object(quota)])
                }
                if parts[3] == "quotas" && request.method == "PATCH" && parts.count == 5 {
                    try requireParent()
                    guard let index = engine.policy.quotas.firstIndex(where: {$0.childId == c.id && $0.id == parts[4]}) else { throw APIError(404,"not_found","Quota not found.") }
                    let data = try payload(request,keys:["expectedPolicyRevision","weeklyLimitSeconds"])
                    let seconds = try requiredInteger(data,"weeklyLimitSeconds")
                    let policy = try change(data) {$0.quotas[index].weeklyLimitSeconds = seconds}
                    return .init(json:["policyRevision":policy.revision,"quota":try JSONCodec.object(policy.quotas[index])])
                }
            }
            if parts[1] == "services" && ["POST","PATCH"].contains(request.method) {
                try requireParent()
                let data = try payload(request,keys:["expectedPolicyRevision","name","domains","applicationIds"])
                var service: ServiceDefinition
                var index: Int?
                if request.method == "POST" && parts.count == 2 {
                    service = .init(name:try requiredString(data,"name"))
                    guard data["domains"] != nil, data["applicationIds"] != nil else { throw APIError(422,"invalid_policy","Domains and applicationIds are required.") }
                } else if request.method == "PATCH", parts.count == 3, let i = engine.policy.services.firstIndex(where: {$0.id == parts[2]}) {
                    index = i; service = engine.policy.services[i]
                    guard data.count > 1 else { throw APIError(422,"invalid_policy","Specify a change.") }
                } else { throw APIError(404,"not_found","Service not found.") }
                if data["name"] != nil { service.name = try requiredString(data,"name") }
                if let domains = data["domains"] { service.domains = try canonicalRules(domains) }
                if let apps = data["applicationIds"] { service.applicationIds = try JSONCodec.decode([String].self,from:apps) }
                let policy = try change(data) { p in if let index {p.services[index] = service} else {p.services.append(service)} }
                return .init(status:index == nil ? 201 : 200,json:["policyRevision":policy.revision,"service":try JSONCodec.object(service)])
            }
            if parts.count >= 3 && parts[1] == "admin" {
                try requireParent()
                if request.method == "GET" && parts == ["v1","admin","state"] {
                    return .init(json:["policyRevision":engine.policy.revision,"policy":try JSONCodec.object(engine.policy),"clients":credentials.publicClients,"filterConnected":filterConnected,"unattributedFlows":filterGaps])
                }
                if request.method == "POST" && parts == ["v1","admin","children"] {
                    let data = try payload(request,keys:["expectedPolicyRevision","displayName","generatedUid","uid"])
                    let account = try verifyAccount(requiredString(data,"generatedUid"))
                    if let claimed = data["uid"] as? NSNumber, claimed.uint32Value != account.uid { throw APIError(422,"invalid_policy","Account identity changed; select it again.") }
                    let c = Child(displayName:try requiredString(data,"displayName"),macOSAccount:account)
                    let policy = try change(data) { p in
                        p.children.append(c)
                        for id in ["chesscom","chatgpt"] where p.services.contains(where: {$0.id == id}) {p.quotas.append(.init(childId:c.id,serviceId:id))}
                    }
                    return .init(status:201,json:["policyRevision":policy.revision,"child":["id":c.id,"displayName":c.displayName]])
                }
                if request.method == "POST", parts.count == 5, parts[2] == "children", parts[4] == "reset" {
                    let c = try child(parts[3],client:client)
                    let data = try payload(request,keys:["expectedPolicyRevision"])
                    guard let revision = data["expectedPolicyRevision"] as? NSNumber,
                          CFGetTypeID(revision) != CFBooleanGetTypeID(), revision.doubleValue == Double(engine.policy.revision) else {
                        throw APIError(409,"conflict","Policy changed; refresh before resetting usage.")
                    }
                    let policy = try engine.resetUsage(childId:c.id,expectedRevision:revision.intValue,actorUID:administratorUID!,now:date(),monotonic:monotonic())
                    return .init(json:["policyRevision":policy.revision,"balances":try JSONCodec.object(snapshot(childId:c.id))])
                }
                if request.method == "POST" && parts == ["v1","admin","applications"] {
                    let data = try payload(request,keys:["expectedPolicyRevision","path"])
                    let app = try verifyApplication(requiredString(data,"path"))
                    if let existing = engine.policy.applicationBindings.first(where: {$0.identity?.signingIdentifier == app.identity?.signingIdentifier && $0.identity?.teamIdentifier == app.identity?.teamIdentifier}) {
                        return .init(json:["policyRevision":engine.policy.revision,"application":try JSONCodec.object(existing)])
                    }
                    let policy = try change(data) {$0.applicationBindings.append(app)}
                    return .init(status:201,json:["policyRevision":policy.revision,"application":try JSONCodec.object(app)])
                }
                if request.method == "PUT" && parts == ["v1","admin","settings"] {
                    let data = try payload(request,keys:["expectedPolicyRevision","reset"])
                    guard let reset = data["reset"] else { throw APIError(422,"invalid_policy","Reset schedule required.") }
                    let schedule = try JSONCodec.decode(ResetSchedule.self,from:reset)
                    let policy = try change(data) {$0.reset = schedule}
                    return .init(json:["policyRevision":policy.revision,"policy":try JSONCodec.object(policy)])
                }
                if request.method == "POST" && parts == ["v1","admin","clients"] {
                    let data = try payload(request,keys:["name","scopes","childIds"])
                    let scopes = try JSONCodec.decode([String].self,from:data["scopes"] ?? []), children = try JSONCodec.decode([String].self,from:data["childIds"] ?? [])
                    guard Set(children).isSubset(of:Set(engine.policy.children.map(\.id))) else {throw APIError(422,"invalid_policy","Unknown child grant.")}
                    return .init(status:201,json:try credentials.issue(name:requiredString(data,"name"),scopes:scopes,childIds:children))
                }
                if request.method == "DELETE" && parts.count == 4 && parts[2] == "clients" {
                    try credentials.revoke(id:parts[3]); return .init(json:["revoked":true])
                }
            }
            throw APIError(404,"not_found","Resource not found.")
        } catch let error as APIError {
            return .init(status:error.status,json:["error":["code":error.code,"message":error.message]])
        } catch let error as QuotaError {
            let status: Int
            switch error {case .conflict: status=409;case .unknownChild:status=404;case .persistence:status=503;case .invalidPolicy:status=422}
            return .init(status:status,json:["error":["code":status == 409 ? "conflict" : status == 503 ? "unavailable" : "invalid_policy","message":status == 503 ? "Storage is unavailable." : error.localizedDescription]])
        } catch {
            return .init(status:400,json:["error":["code":"bad_request","message":"The request could not be processed."]])
        }
    }

    private var filterConnected: Bool { filterLastSeen.map {monotonic() - $0 < 5} ?? false }
    private func accountIsCurrent(_ child: Child) -> Bool {
        guard child.macOSAccount.status == "ready", let guid = child.macOSAccount.generatedUid, let uid = child.macOSAccount.uid else { return false }
        let key = guid + ":" + String(uid), clock = monotonic()
        if let check = accountChecks[key], clock - check.time >= 0, clock - check.time < 5 { return check.valid }
        let actual = try? verifyAccount(guid)
        let valid = actual?.generatedUid?.lowercased() == guid.lowercased() && actual?.uid == uid && actual?.status == "ready"
        accountChecks[key] = (clock,valid)
        return valid
    }
    private func snapshot(childId: String) throws -> BalanceSnapshot {
        let child = engine.policy.children.first {$0.id == childId}
        let uid = child?.macOSAccount.uid
        let active = uid.flatMap {foreground[$0]}.map {$0.healthy && monotonic() - $0.lastSeen < 15} ?? false
        let seenBrowser = uid.map {u in ["chrome","safari"].allSatisfy {browser in browsers.contains {$0.key.hasPrefix("\(u):\(browser):") && monotonic() - $0.value.lastSeen < 15}}} ?? false
        var coverage: [String:Bool] = [:]
        for service in engine.policy.services {
            let readyApps = service.applicationIds.allSatisfy {id in engine.policy.applicationBindings.contains {$0.id == id && $0.status == "ready" && $0.identity != nil}}
            coverage[service.id] = child.map {accountIsCurrent($0)} == true && active && (service.domains.isEmpty || seenBrowser) && (service.applicationIds.isEmpty || (filterConnected && filterGaps == 0 && readyApps))
        }
        return try engine.balances(childId:childId,now:date(),monotonic:monotonic(),coverage:coverage)
    }

    /// IPC identity comes from kernel peer credentials, never from payload child IDs.
    public func native(_ object: [String:Any], uid: UInt32, role: String) -> [String:Any] {
        lock.lock(); defer {lock.unlock()}
        do {
            guard let op = object["op"] as? String else {throw APIError(400,"bad_request","Missing operation.")}
            if op == "parentHTTP" {
                guard role == "parent", let proof = object["authorizationExternalForm"] as? String, authorizeParent(uid,proof) else {
                    return ["status":403,"body":["error":["code":"administrator_required","message":"Unlock Kids Quota with administrator credentials."]]]
                }
                guard let method = object["method"] as? String, let path = object["path"] as? String,
                      let authorization = object["authorization"] as? String else {throw APIError(400,"bad_request","Invalid parent request.")}
                let body = try object["body"].map {try JSONSerialization.data(withJSONObject:$0)} ?? Data()
                let response = handle(.init(method:method,path:path,headers:["host":"127.0.0.1:\(port)","authorization":authorization,"content-type":"application/json"],body:body),administratorUID:uid)
                return ["status":response.status,"body":try JSONSerialization.jsonObject(with:response.body)]
            }
            if op == "filterRules" {
                guard role == "filter" else {throw APIError(403,"forbidden","Filter identity required.")}
                filterLastSeen = monotonic(); filterGaps = max(0,object["unattributedFlows"] as? Int ?? 0)
                try tick()
                var rules: [[String:Any]] = []
                for child in engine.policy.children {
                    guard accountIsCurrent(child), let accountUID = child.macOSAccount.uid else {continue}
                    let freshAgent = foreground[accountUID].map {$0.healthy && monotonic() - $0.lastSeen < 15} ?? false
                    let balance = try snapshot(childId:child.id)
                    for item in balance.items {
                        guard let service = engine.policy.services.first(where: {$0.id == item.serviceId}) else {continue}
                        for appID in service.applicationIds {
                            guard let app = engine.policy.applicationBindings.first(where: {$0.id == appID}), let identity = app.identity else {continue}
                            rules.append(["uid":accountUID,"requirement":identity.designatedRequirement,"blocked":item.remainingSeconds == 0 || !freshAgent,"serviceId":service.id])
                        }
                    }
                }
                return ["revision":engine.policy.revision,"rules":rules,"childUIDs":engine.policy.children.filter {accountIsCurrent($0)}.compactMap {$0.macOSAccount.uid}]
            }
            guard let child = engine.policy.children.first(where: {$0.macOSAccount.uid == uid && accountIsCurrent($0)}) else {
                return ["type":"policy","revision":engine.policy.revision,"rules":[],"configured":false,"coverage":"incomplete","error":"This macOS account is not linked to a child."]
            }
            if op == "foreground" {
                guard role == "agent" else {throw APIError(403,"forbidden","Collector identity required.")}
                foreground[uid] = .init(pid:(object["pid"] as? NSNumber)?.int32Value ?? 0,bundle:object["bundleIdentifier"] as? String ?? "",active:object["active"] as? Bool == true,healthy:object["healthy"] as? Bool ?? true,lastSeen:monotonic())
                try reconcile()
                return ["ok":true]
            }
            if op == "browser" {
                guard ["bridge","safari"].contains(role), let state = object["payload"] as? [String:Any], state["type"] as? String == "browserState",
                      let browser = state["browser"] as? String, ["chrome","safari"].contains(browser),
                      (role == "safari") == (browser == "safari"), let session = state["sessionId"] as? String, session.count <= 100,
                      !session.isEmpty, let seq = state["sequence"] as? NSNumber, CFGetTypeID(seq) != CFBooleanGetTypeID(), seq.doubleValue.isFinite,
                      seq.doubleValue >= 0, seq.doubleValue.rounded() == seq.doubleValue, seq.doubleValue <= 9_007_199_254_740_991 else {throw APIError(400,"bad_request","Invalid browser state.")}
                let key = "\(uid):\(browser):\(session)"
                let old = browsers[key]
                if old == nil || old?.sessionId != session || seq.uint64Value > old!.sequence {
                    let hostname = (state["hostname"] as? String).flatMap {try? DomainMatcher.canonicalHostname($0)}
                    browsers[key] = .init(hostname:hostname,focused:state["focused"] as? Bool == true,sequence:seq.uint64Value,sessionId:session,lastSeen:monotonic())
                    if browsers.count > 256 {browsers = browsers.filter {monotonic() - $0.value.lastSeen < 15}}
                }
                try tick()
                let balance = try snapshot(childId:child.id)
                let freshAgent = foreground[uid].map {$0.healthy && monotonic() - $0.lastSeen < 15} ?? false
                let rules: [[String:Any]] = try balance.items.compactMap { item in
                    guard let service = engine.policy.services.first(where: {$0.id == item.serviceId}) else {return nil}
                    return ["serviceId":service.id,"name":service.name,"domains":try JSONCodec.object(service.domains),"blocked":item.remainingSeconds == 0 || !freshAgent,"remainingSeconds":item.remainingSeconds,"resetAt":ISO8601DateFormatter().string(from:item.periodEnd)]
                }
                return ["type":"policy","revision":engine.policy.revision,"rules":rules,"configured":true,"coverage":freshAgent ? "complete" : "incomplete","requestSequence":seq.uint64Value]
            }
            throw APIError(400,"bad_request","Unknown operation.")
        } catch {return ["error":"Service request failed.","configured":false,"coverage":"incomplete"]}
    }

    private func reconcile() throws {
        let now = date(), clock = monotonic()
        guard let uid = consoleUID(), let child = engine.policy.children.first(where: {$0.macOSAccount.uid == uid && accountIsCurrent($0)}),
              let report = foreground[uid], report.active, report.healthy, clock - report.lastSeen < 15 else {
            try engine.stop(now:now,monotonic:clock); return
        }
        var serviceID: String?
        let browser: String? = report.bundle == "com.apple.Safari" ? "safari" : ["com.google.Chrome","com.brave.Browser","org.chromium.Chromium"].contains(report.bundle) ? "chrome" : nil
        if let browser, let state = browsers.filter({$0.key.hasPrefix("\(uid):\(browser):") && $0.value.focused && clock - $0.value.lastSeen < 15}).max(by: {$0.value.lastSeen < $1.value.lastSeen})?.value, let hostname = state.hostname {
            serviceID = engine.policy.serviceID(forHostname:hostname,childId:child.id)
        } else if browser == nil {
            for app in engine.policy.applicationBindings {
                if let identity = app.identity, processMatches(report.pid,identity.designatedRequirement) {
                    serviceID = engine.policy.serviceID(forApplicationID:app.id,childId:child.id); break
                }
            }
        }
        sequence &+= 1
        guard serviceID != nil else {try engine.stop(now:now,monotonic:clock);return}
        try engine.reportActivity(childId:child.id,serviceId:serviceID,sessionId:collectorSession,sequence:sequence,isActive:true,now:now,monotonic:clock)
    }
}
