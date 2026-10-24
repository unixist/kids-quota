import XCTest
import Foundation
import Security
import KidsQuotaCore
@testable import KidsQuotaService

final class ControllerTests: XCTestCase {
    private final class Context {
        var now = ISO8601DateFormatter().date(from: "2026-10-21T12:00:00Z")!
        var monotonic: Double = 1_000
        var console: UInt32? = 501
        var accounts: [String: MacOSAccountBinding] = [
            "alice-guid": .init(status: "ready", generatedUid: "alice-guid", uid: 501),
            "bob-guid": .init(status: "ready", generatedUid: "bob-guid", uid: 502),
            "cara-guid": .init(status: "ready", generatedUid: "cara-guid", uid: 503)
        ]
        var matchingPIDs: Set<Int32> = [80]
        var inspectedPaths: [String] = []
        var parentAuthorized = true
        func advance(_ seconds: Double) { now.addTimeInterval(seconds); monotonic += seconds }
    }

    private final class Fixture {
        let directory: URL
        let context = Context()
        let controller: ServiceController
        let administrator: String
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("kids-quota-controller-" + UUID().uuidString)
            let context = self.context
            controller = try ServiceController(directory: directory, now: { context.now }, monotonic: { context.monotonic }, consoleUID: { context.console }, verifyAccount: { guid in
                guard let account = context.accounts[guid] else { throw APIError(422,"invalid_policy","Account no longer exists.") }
                return account
            }, verifyApplication: { path in
                context.inspectedPaths.append(path)
                return .init(id: "verified-app", displayName: "Verified app", status: "ready", identity: .init(signingIdentifier: "verified.application", teamIdentifier: "VERIFIEDTEAM", designatedRequirement: "identifier verified.application"))
            }, processMatches: { pid, requirement in context.matchingPIDs.contains(pid) && requirement == "identifier chess.application" },
               authorizeParent: {uid,proof in context.parentAuthorized && uid == 900 && proof == "test-administrator-grant"})
            administrator = try String(contentsOf: directory.appendingPathComponent("admin.token"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            var policy = controller.engine.policy
            policy.children = [
                .init(id: "alice", displayName: "Alice", macOSAccount: context.accounts["alice-guid"]!),
                .init(id: "bob", displayName: "Bob", macOSAccount: context.accounts["bob-guid"]!)
            ]
            policy.applicationBindings = [.init(id: "chess-app", displayName: "Chess app", status: "ready", identity: .init(signingIdentifier: "chess.application", teamIdentifier: "CHESSTEAM", designatedRequirement: "identifier chess.application"))]
            policy.services[0].applicationIds = ["chess-app"]
            policy.quotas = [.init(id: "alice-chess", childId: "alice", serviceId: "chesscom", weeklyLimitSeconds: 100),
                             .init(id: "bob-chess", childId: "bob", serviceId: "chesscom", weeklyLimitSeconds: 200),
                             .init(id: "bob-chat", childId: "bob", serviceId: "chatgpt", weeklyLimitSeconds: 300)]
            try controller.engine.replacePolicy(policy, expectedRevision: policy.revision, now: context.now, monotonic: context.monotonic)
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        var revision: Int { controller.engine.policy.revision }
        func request(_ method: String = "GET", _ path: String = "/v1/children", token: String? = nil, body: [String:Any]? = nil, headers: [String:String] = [:], authorizedParent: Bool = true) throws -> HTTPResponse {
            var fields = ["Host":"127.0.0.1:48123", "Authorization":"Bearer " + (token ?? administrator), "Content-Type":"application/json"]
            fields.merge(headers, uniquingKeysWith: { _, new in new })
            return controller.handle(.init(method: method, path: path, headers: fields, body: try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()),administratorUID:authorizedParent ? 900 : nil)
        }
        func grant(children: [String] = ["alice"], scopes: [String] = CredentialStore.readScopes) throws -> (String,String) {
            let response = try request("POST", "/v1/admin/clients", body: ["name":"Widget", "childIds":children, "scopes":scopes])
            guard response.status == 201, let object = try JSONSerialization.jsonObject(with: response.body) as? [String:Any], let token = object["token"] as? String, let id = object["id"] as? String else { throw APIError(500,"test_fixture","Failed to issue test grant.") }
            return (token,id)
        }
        @discardableResult func foreground(uid: UInt32 = 501, bundle: String = "com.google.Chrome", pid: Int32 = 40, active: Bool = true, role: String = "agent") -> [String:Any] {
            controller.native(["op":"foreground","bundleIdentifier":bundle,"pid":pid,"active":active], uid:uid, role:role)
        }
        @discardableResult func browser(uid: UInt32 = 501, name: String = "chrome", hostname: String = "chess.com", sequence: Any = 1, focused: Bool = true, session: String = "browser-session", role: String = "bridge") -> [String:Any] {
            controller.native(["op":"browser","payload":["type":"browserState","browser":name,"hostname":hostname,"focused":focused,"sequence":sequence,"sessionId":session]], uid:uid, role:role)
        }
        func used(_ child: String = "alice", service: String = "chesscom") throws -> Int {
            let snapshot = try controller.engine.balances(childId:child, now:context.now, monotonic:context.monotonic)
            return try XCTUnwrap(snapshot.items.first { $0.serviceId == service }).usedSeconds
        }
    }
    private func object(_ response: HTTPResponse) throws -> [String:Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String:Any]) }
    private func items(_ response: HTTPResponse) throws -> [[String:Any]] { try XCTUnwrap(object(response)["items"] as? [[String:Any]]) }

    func testUnhealthyCollectorBlocksKnownServiceAndStopsMetering() throws {
        let f = try Fixture()
        f.foreground();f.browser()
        f.context.advance(2)
        _ = f.controller.native(["op":"foreground","pid":40,"bundleIdentifier":"com.google.Chrome","active":true,"healthy":false],uid:501,role:"agent")
        let policy = f.browser(sequence:2)
        XCTAssertTrue((policy["rules"] as? [[String:Any]])?.first?["blocked"] as? Bool == true)
        XCTAssertEqual(policy["coverage"] as? String,"incomplete")
        let before = try f.used()
        f.context.advance(10);try f.controller.tick()
        XCTAssertEqual(try f.used(),before)
    }

    func testFailedCredentialBootstrapDoesNotCommitUnrecoverableAdminDigest() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("kids-quota-bootstrap-"+UUID().uuidString)
        let bootstrap=directory.appendingPathComponent("admin.token")
        try FileManager.default.createDirectory(at:bootstrap,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:directory)}
        XCTAssertThrowsError(try CredentialStore(directory:directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.appendingPathComponent("clients.json").path))
        try FileManager.default.removeItem(at:bootstrap)
        let store=try CredentialStore(directory:directory)
        let token=try String(contentsOf:bootstrap,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)
        XCTAssertTrue(try store.authenticate("Bearer "+token).administrator)
    }

    func testHTTPRequiresBearerAndExactLoopbackHostAndRejectsBrowserOrigins() throws {
        let f = try Fixture()
        XCTAssertEqual(try f.request(headers:["Authorization":""]).status,401)
        XCTAssertEqual(try f.request(token:"wrong").status,401)
        XCTAssertEqual(try f.request(headers:["Host":"attacker.example:48123"]).status,403)
        XCTAssertEqual(try f.request(headers:["Origin":"http://localhost:48123"]).status,403)
        XCTAssertEqual(try f.request(headers:["Host":"localhost:48123"]).status,200)
    }

    func testReadGrantSeesOnlyAssignedChildAndServices() throws {
        let f = try Fixture(); let (token,_) = try f.grant()
        XCTAssertEqual(try items(f.request(token:token)).compactMap { $0["id"] as? String },["alice"])
        XCTAssertEqual(try items(f.request("GET","/v1/services",token:token)).compactMap { $0["id"] as? String },["chesscom"])
        XCTAssertEqual(try f.request("GET","/v1/children/alice/balances",token:token).status,200)
        XCTAssertEqual(try f.request("GET","/v1/children/bob/balances",token:token).status,404)
        XCTAssertEqual(try f.request("GET","/v1/children/bob/quotas",token:token).status,404)
    }

    func testScopeAndAdministrativeBoundariesAreIndependentOfChildGrant() throws {
        let f = try Fixture(); let (token,_) = try f.grant(scopes:["balances:read"])
        XCTAssertEqual(try f.request(token:token).status,403)
        XCTAssertEqual(try f.request("GET","/v1/children/alice/balances",token:token).status,200)
        XCTAssertEqual(try f.request("GET","/v1/admin/state",token:token).status,403)
        XCTAssertEqual(try f.request("PATCH","/v1/children/alice/quotas/alice-chess",token:token,body:["expectedPolicyRevision":f.revision,"weeklyLimitSeconds":999]).status,403)
        XCTAssertEqual(try f.request("POST","/v1/admin/clients",token:token,body:["name":"elevate","scopes":["balances:read"],"childIds":["alice"]]).status,403)
    }

    func testRevocationIsImmediateAndPersistsAcrossCredentialReload() throws {
        let f = try Fixture();let (token,id) = try f.grant()
        XCTAssertEqual(try f.request(token:token).status,200)
        XCTAssertEqual(try f.request("DELETE","/v1/admin/clients/" + id).status,200)
        XCTAssertEqual(try f.request(token:token).status,401)
        let reload = try CredentialStore(directory:f.directory)
        XCTAssertThrowsError(try reload.authenticate("Bearer " + token))
        XCTAssertTrue(try reload.authenticate("Bearer " + f.administrator).administrator)
    }

    func testClientCreationCannotGrantWritesUnknownChildrenOrEmptyScope() throws {
        let f = try Fixture()
        let cases: [[String:Any]] = [
            ["name":"bad","scopes":["policy:write"],"childIds":["alice"]],
            ["name":"bad","scopes":["balances:read"],"childIds":["not-a-child"]],
            ["name":"bad","scopes":[],"childIds":["alice"]]
        ]
        for body in cases { XCTAssertEqual(try f.request("POST","/v1/admin/clients",body:body).status,422) }
    }

    func testCredentialListsNeverReturnTokensOrDigestsAndAdministratorCannotBeRevoked() throws {
        let f = try Fixture();let (token,_) = try f.grant()
        let state = try object(f.request("GET","/v1/admin/state"))
        let clients = try XCTUnwrap(state["clients"] as? [[String:Any]])
        for client in clients { XCTAssertNil(client["token"]);XCTAssertNil(client["digest"]) }
        let admin = try XCTUnwrap(clients.first { $0["administrator"] as? Bool == true }?["id"] as? String)
        XCTAssertEqual(try f.request("DELETE","/v1/admin/clients/" + admin).status,404)
        let persisted = try String(contentsOf:f.directory.appendingPathComponent("clients.json"),encoding:.utf8)
        XCTAssertFalse(persisted.contains(token));XCTAssertFalse(persisted.contains(f.administrator))
    }

    func testStalePolicyWriteCannotOverwriteNewAllowance() throws {
        let f = try Fixture();let revision = f.revision
        XCTAssertEqual(try f.request("PATCH","/v1/children/alice/quotas/alice-chess",body:["expectedPolicyRevision":revision,"weeklyLimitSeconds":180]).status,200)
        XCTAssertEqual(try f.request("PATCH","/v1/children/alice/quotas/alice-chess",body:["expectedPolicyRevision":revision,"weeklyLimitSeconds":500]).status,409)
        XCTAssertEqual(f.controller.engine.policy.quotas.first { $0.id == "alice-chess" }?.weeklyLimitSeconds,180)
        XCTAssertEqual(f.revision,revision + 1)
    }

    func testWritesRejectUnknownFieldsNonintegersAndBooleanNumbers() throws {
        let f = try Fixture();let revision = f.revision
        for seconds in [true,2.5,-1] as [Any] {
            XCTAssertEqual(try f.request("PATCH","/v1/children/alice/quotas/alice-chess",body:["expectedPolicyRevision":revision,"weeklyLimitSeconds":seconds]).status,422)
        }
        XCTAssertEqual(try f.request("PATCH","/v1/children/alice/quotas/alice-chess",body:["expectedPolicyRevision":true,"weeklyLimitSeconds":10]).status,409)
        XCTAssertEqual(try f.request("PATCH","/v1/children/alice/quotas/alice-chess",body:["expectedPolicyRevision":revision,"weeklyLimitSeconds":10,"childId":"bob"]).status,400)
        XCTAssertEqual(f.revision,revision)
    }

    func testParentCreatesCustomDomainServiceAndAssignsItToChild() throws {
        let f = try Fixture()
        let response = try f.request("POST","/v1/services",body:["expectedPolicyRevision":f.revision,"name":"Learning","domains":[["hostname":"HTTPS://Learn.Example.org/lesson","includeSubdomains":false]],"applicationIds":[]])
        XCTAssertEqual(response.status,201)
        let service = try XCTUnwrap(object(response)["service"] as? [String:Any]);let id = try XCTUnwrap(service["id"] as? String)
        XCTAssertEqual((service["domains"] as? [[String:Any]])?.first?["hostname"] as? String,"learn.example.org")
        XCTAssertEqual(try f.request("POST","/v1/children/alice/quotas",body:["expectedPolicyRevision":f.revision,"serviceId":id,"weeklyLimitSeconds":3600]).status,201)
        XCTAssertEqual(f.controller.engine.policy.serviceID(forHostname:"learn.example.org",childId:"alice"),id)
        XCTAssertNil(f.controller.engine.policy.serviceID(forHostname:"other.learn.example.org",childId:"alice"))
    }

    func testChildCreationUsesVerifiedAccountAndRejectsMismatchedUID() throws {
        let f = try Fixture()
        XCTAssertEqual(try f.request("POST","/v1/admin/children",body:["expectedPolicyRevision":f.revision,"displayName":"Cara","generatedUid":"cara-guid","uid":599]).status,422)
        XCTAssertEqual(f.controller.engine.policy.children.count,2)
        XCTAssertEqual(try f.request("POST","/v1/admin/children",body:["expectedPolicyRevision":f.revision,"displayName":"Cara","generatedUid":"cara-guid","uid":503]).status,201)
        let child = try XCTUnwrap(f.controller.engine.policy.children.last)
        XCTAssertEqual(child.macOSAccount.generatedUid,"cara-guid");XCTAssertEqual(child.macOSAccount.uid,503)
        XCTAssertEqual(f.controller.engine.policy.quotas.filter { $0.childId == child.id }.map(\.weeklyLimitSeconds),[21600,21600])
    }

    func testApplicationSelectionUsesVerifiedSignerRatherThanClientSuppliedIdentity() throws {
        let f = try Fixture()
        let result = try f.request("POST","/v1/admin/applications",body:["expectedPolicyRevision":f.revision,"path":"/Applications/Verified.app"])
        XCTAssertEqual(result.status,201);XCTAssertEqual(f.context.inspectedPaths,["/Applications/Verified.app"])
        XCTAssertEqual(f.controller.engine.policy.applicationBindings.last?.identity?.teamIdentifier,"VERIFIEDTEAM")
        XCTAssertEqual(try f.request("POST","/v1/admin/applications",body:["expectedPolicyRevision":f.revision,"path":"/Applications/Other.app","teamIdentifier":"forged"]).status,400)
    }

    func testNativeOperationsRejectOtherRolesWithoutRecordingActivity() throws {
        let f = try Fixture()
        XCTAssertNotNil(f.foreground(role:"bridge")["error"])
        XCTAssertNotNil(f.browser(role:"agent")["error"])
        XCTAssertNotNil(f.browser(name:"safari",role:"bridge")["error"])
        XCTAssertNotNil(f.controller.native(["op":"filterRules"],uid:501,role:"bridge")["error"])
        f.context.advance(10);try f.controller.tick();XCTAssertEqual(try f.used(),0)
    }

    func testParentNativeTunnelRequiresSignedRoleAndStillChecksBearerScopes() throws {
        let f = try Fixture();let (readToken,_) = try f.grant()
        let request: [String:Any] = ["op":"parentHTTP","method":"GET","path":"/v1/admin/state","authorization":"Bearer " + f.administrator,"authorizationExternalForm":"test-administrator-grant"]
        XCTAssertEqual(f.controller.native(request,uid:900,role:"bridge")["status"] as? Int,403)
        XCTAssertEqual(f.controller.native(request,uid:501,role:"parent")["status"] as? Int,403)
        XCTAssertEqual(f.controller.native(["op":"parentHTTP","method":"GET","path":"/v1/admin/state"],uid:900,role:"parent")["status"] as? Int,403)
        var invalid = request;invalid["authorization"] = "Bearer invalid"
        XCTAssertEqual(f.controller.native(invalid,uid:900,role:"parent")["status"] as? Int,401)
        invalid["authorization"] = "Bearer " + readToken
        XCTAssertEqual(f.controller.native(invalid,uid:900,role:"parent")["status"] as? Int,403)
        let response = f.controller.native(request,uid:900,role:"parent")
        XCTAssertEqual(response["status"] as? Int,200)
        XCTAssertNotNil((response["body"] as? [String:Any])?["policy"])
        f.context.parentAuthorized = false
        XCTAssertEqual(f.controller.native(request,uid:900,role:"parent")["status"] as? Int,403)
    }

    func testPublicHTTPIsReadOnlyEvenWithAdministratorBearerAndForgedHeaders() throws {
        let f = try Fixture()
        XCTAssertEqual(try f.request(authorizedParent:false).status,200)
        XCTAssertEqual(try f.request("GET","/v1/admin/state",authorizedParent:false).status,403)
        let revision=f.revision
        let body:[String:Any]=["expectedPolicyRevision":revision,"weeklyLimitSeconds":999]
        XCTAssertEqual(try f.request("PATCH","/v1/children/alice/quotas/alice-chess",body:body,headers:["X-Administrator-UID":"900","AuthorizationExternalForm":"test-administrator-grant"],authorizedParent:false).status,403)
        XCTAssertEqual(try f.request("POST","/v1/admin/children/alice/reset",body:["expectedPolicyRevision":revision],authorizedParent:false).status,403)
        XCTAssertEqual(f.revision,revision)
    }

    func testResetRestoresOnlySelectedChildAndRejectsStaleOrReadOnlyRequests() throws {
        let f=try Fixture();f.foreground();f.browser()
        f.context.advance(5);try f.controller.tick()
        f.context.console=502;f.foreground(uid:502);f.browser(uid:502)
        f.context.advance(4);try f.controller.tick()
        let revision=f.revision
        let limits=f.controller.engine.policy.quotas.map(\.weeklyLimitSeconds)
        let (readToken,_)=try f.grant()
        XCTAssertEqual(try f.request("POST","/v1/admin/children/alice/reset",token:readToken,body:["expectedPolicyRevision":revision]).status,403)
        let response=try f.request("POST","/v1/admin/children/alice/reset",body:["expectedPolicyRevision":revision])
        XCTAssertEqual(response.status,200)
        XCTAssertEqual(try f.used(),0);XCTAssertEqual(try f.used("bob"),4)
        XCTAssertEqual(f.controller.engine.policy.quotas.map(\.weeklyLimitSeconds),limits)
        XCTAssertEqual(f.revision,revision+1)
        let balances=try XCTUnwrap(object(response)["balances"] as? [String:Any])
        XCTAssertEqual((balances["items"] as? [[String:Any]])?.first?["remainingSeconds"] as? Int,100)
        XCTAssertEqual(try f.request("POST","/v1/admin/children/alice/reset",body:["expectedPolicyRevision":revision]).status,409)
    }

    func testMalformedAdministratorProofFailsWithoutPrompting() {
        for proof in ["", "invalid", Data(repeating:0,count:31).base64EncodedString(), String(repeating:"A",count:1024)] {
            XCTAssertFalse(ParentAuthorization.validate(uid:0,externalForm:proof))
        }
    }

    func testEmptyAuthorizationReferenceCannotUnlockConfiguration() throws {
        var reference: AuthorizationRef?
        let status=AuthorizationCreate(nil,nil,[],&reference)
        if status == errAuthorizationInternal {throw XCTSkip("Authorization Services is unavailable in this sandbox/headless test session.")}
        XCTAssertEqual(status,errAuthorizationSuccess)
        let authorization=try XCTUnwrap(reference)
        defer {AuthorizationFree(authorization,[.destroyRights])}
        var form=AuthorizationExternalForm()
        XCTAssertEqual(AuthorizationMakeExternalForm(authorization,&form),errAuthorizationSuccess)
        let proof=withUnsafeBytes(of:&form){Data($0).base64EncodedString()}
        XCTAssertFalse(ParentAuthorization.validate(uid:0,externalForm:proof))
    }

    func testBrowserAndNativeApplicationConsumeOneSharedServiceBalance() throws {
        let f = try Fixture();f.foreground();f.browser()
        f.context.advance(5);try f.controller.tick();XCTAssertEqual(try f.used(),5)
        f.foreground(bundle:"chess.application",pid:80)
        f.context.advance(7);try f.controller.tick();XCTAssertEqual(try f.used(),12)
        XCTAssertEqual(try f.used("bob"),0)
        let reply = f.browser(sequence:2);let rules = try XCTUnwrap(reply["rules"] as? [[String:Any]])
        XCTAssertEqual(rules.first?["remainingSeconds"] as? Int,88)
    }

    func testBackgroundBrowserAndWrongApplicationSignerDoNotConsumeTime() throws {
        let f = try Fixture();f.foreground(bundle:"unrelated.application",pid:999);f.browser()
        f.context.advance(5);try f.controller.tick();XCTAssertEqual(try f.used(),0)
        f.foreground();f.browser(sequence:2,focused:false)
        f.context.advance(5);try f.controller.tick();XCTAssertEqual(try f.used(),0)
    }

    func testFastUserSwitchChargesOnlyCurrentConsoleChild() throws {
        let f = try Fixture();f.foreground();f.browser()
        f.context.advance(5);try f.controller.tick()
        f.context.console = 502;f.foreground(uid:502);f.browser(uid:502)
        f.context.advance(4);try f.controller.tick()
        f.foreground(uid:501);f.browser(uid:501,sequence:2)
        f.context.advance(3);try f.controller.tick()
        XCTAssertEqual(try f.used("alice"),5);XCTAssertEqual(try f.used("bob"),7)
    }

    func testSwitchingToAnotherChildsUnmeteredWebsiteStopsPreviousChildsUsage() throws {
        let f = try Fixture();f.foreground();f.browser()
        f.context.advance(5);try f.controller.tick()
        f.context.console = 502;f.foreground(uid:502);f.browser(uid:502,hostname:"example.org")
        f.context.advance(5);try f.controller.tick()
        XCTAssertEqual(try f.used("alice"),5);XCTAssertEqual(try f.used("bob"),0)
    }

    func testLockReportStopsAccountingAndDoesNotCountUnobservedTime() throws {
        let f = try Fixture();f.foreground();f.browser()
        f.context.advance(5);f.foreground(active:false)
        f.context.advance(40);try f.controller.tick();XCTAssertEqual(try f.used(),5)
        f.context.console = nil;f.foreground();f.browser(sequence:2)
        f.context.advance(5);try f.controller.tick();XCTAssertEqual(try f.used(),5)
    }

    func testExpiredAgentStopsUsageAndBrowserPolicyFailsClosedDespiteAvailableBalance() throws {
        let f = try Fixture();f.foreground();f.browser()
        f.context.advance(30);try f.controller.tick();XCTAssertEqual(try f.used(),15)
        let response = f.browser(sequence:2)
        XCTAssertEqual(response["coverage"] as? String,"incomplete")
        XCTAssertEqual((response["rules"] as? [[String:Any]])?.first?["blocked"] as? Bool,true)
        f.context.advance(10);try f.controller.tick();XCTAssertEqual(try f.used(),15)
    }

    func testOldBrowserSequenceCannotReplaceCurrentInactiveState() throws {
        let f = try Fixture();f.foreground();f.browser(sequence:2,focused:false)
        f.browser(sequence:1,focused:true)
        f.context.advance(5);try f.controller.tick();XCTAssertEqual(try f.used(),0)
        f.browser(sequence:1,session:"new-session")
        f.context.advance(5);try f.controller.tick();XCTAssertEqual(try f.used(),5)
    }

    func testInactiveChromeProfileCannotReplaceAnotherProfilesActiveSession() throws {
        let f = try Fixture();f.foreground();f.browser(sequence:2,session:"foreground-profile")
        f.browser(hostname:"example.org",sequence:100,focused:false,session:"background-profile")
        f.context.advance(5);try f.controller.tick();XCTAssertEqual(try f.used(),5)
        f.browser(sequence:3,session:"foreground-profile")
        f.context.advance(5);try f.controller.tick();XCTAssertEqual(try f.used(),10)
    }

    func testMalformedBrowserSequencesAreRejected() throws {
        let f = try Fixture();f.foreground()
        for value in [true,1.5,-1] as [Any] { XCTAssertNotNil(f.browser(sequence:value)["error"],"Invalid sequence \(value) was accepted") }
        f.context.advance(5);try f.controller.tick();XCTAssertEqual(try f.used(),0)
    }

    func testReusedNumericUIDCannotContinueMeteringAnOldGeneratedUID() throws {
        let f = try Fixture();f.foreground();f.browser()
        f.context.advance(5);try f.controller.tick()
        f.context.accounts.removeValue(forKey:"alice-guid")
        f.context.advance(5) // Expire the bounded account-verification cache.
        f.foreground();let response = f.browser(sequence:2)
        XCTAssertTrue(response["error"] != nil || (response["rules"] as? [[String:Any]])?.allSatisfy { $0["blocked"] as? Bool == true } == true)
        try f.controller.tick();let before = try f.used()
        f.context.advance(5);try f.controller.tick();XCTAssertEqual(try f.used(),before)
    }

    func testFilterRulesArePerUIDAndOneChildExhaustionDoesNotBlockAnother() throws {
        let f = try Fixture();var policy = f.controller.engine.policy
        policy.quotas[0].weeklyLimitSeconds = 0
        try f.controller.engine.replacePolicy(policy,expectedRevision:f.revision,now:f.context.now,monotonic:f.context.monotonic)
        f.foreground(uid:501);f.foreground(uid:502)
        let response = f.controller.native(["op":"filterRules","unattributedFlows":0],uid:0,role:"filter")
        let rules = try XCTUnwrap(response["rules"] as? [[String:Any]])
        XCTAssertEqual(rules.count,2)
        XCTAssertEqual(rules.first { ($0["uid"] as? UInt32) == 501 }?["blocked"] as? Bool,true)
        XCTAssertEqual(rules.first { ($0["uid"] as? UInt32) == 502 }?["blocked"] as? Bool,false)
        XCTAssertTrue(rules.allSatisfy { $0["requirement"] as? String == "identifier chess.application" })
    }

    func testUnattributedFilterFlowsMakeCoverageIncomplete() throws {
        let f = try Fixture();f.foreground();f.browser()
        f.browser(name:"safari",focused:false,role:"safari")
        _ = f.controller.native(["op":"filterRules","unattributedFlows":0],uid:0,role:"filter")
        XCTAssertEqual(try items(f.request("GET","/v1/children/alice/balances")).first?["coverage"] as? String,"complete")
        _ = f.controller.native(["op":"filterRules","unattributedFlows":1],uid:0,role:"filter")
        XCTAssertEqual(try items(f.request("GET","/v1/children/alice/balances")).first?["coverage"] as? String,"incomplete")
        f.context.advance(5)
        XCTAssertEqual(try items(f.request("GET","/v1/children/alice/balances")).first?["coverage"] as? String,"incomplete")
    }

    func testRateLimitIsPerCredentialAndRecoversInNextWindow() throws {
        let f = try Fixture();let (token,_) = try f.grant()
        for _ in 0..<60 { XCTAssertEqual(try f.request(token:token).status,200) }
        XCTAssertEqual(try f.request(token:token).status,429)
        XCTAssertEqual(try f.request().status,200)
        f.context.advance(1.1);XCTAssertEqual(try f.request(token:token).status,200)
    }
}
