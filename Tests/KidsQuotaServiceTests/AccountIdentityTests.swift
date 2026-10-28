import XCTest
import Darwin
import OpenDirectory
@testable import KidsQuotaService

final class AccountIdentityTests: XCTestCase {
    func testLocalAccountValidationPreservesGUIDAndUIDRegardlessOfAdministratorMembership() throws {
        let guid = "ABCDEF12-3456-7890-ABCD-EF1234567890"
        let account = try NativeIdentity.verifiedLocalAccount(generatedUid: guid.lowercased(), entries: [(uid: "501", guid: guid)])
        XCTAssertEqual(account.status, "ready")
        XCTAssertEqual(account.generatedUid, guid)
        XCTAssertEqual(account.uid, 501)
    }

    func testUnknownAmbiguousMismatchedAndSystemAccountsCannotBeBound() {
        let guid = "ABCDEF12-3456-7890-ABCD-EF1234567890"
        let invalid: [[(uid: String?, guid: String?)]] = [
            [],
            [(uid: "501", guid: guid), (uid: "502", guid: guid)],
            [(uid: "499", guid: guid)],
            [(uid: nil, guid: guid)],
            [(uid: "invalid", guid: guid)],
            [(uid: "501", guid: nil)],
            [(uid: "501", guid: "")],
            [(uid: "501", guid: "OTHER-GUID")]
        ]
        for entries in invalid {
            XCTAssertThrowsError(try NativeIdentity.verifiedLocalAccount(generatedUid: guid, entries: entries))
        }
        XCTAssertThrowsError(try NativeIdentity.verifiedLocalAccount(generatedUid: "", entries: [(uid: "501", guid: "")]))
    }

    func testRealCurrentLocalAdministratorAccountCanBeBound() throws {
        let uid = getuid()
        guard uid >= 500, NativeIdentity.isAdministrator(uid: uid) else {
            throw XCTSkip("The test runner is not a local administrator account.")
        }
        let node = try ODNode(session: ODSession.default(), type: UInt32(kODNodeTypeLocalNodes))
        let query = try ODQuery(node: node, forRecordTypes: kODRecordTypeUsers, attribute: kODAttributeTypeUniqueID,
                                matchType: UInt32(kODMatchEqualTo), queryValues: String(uid),
                                returnAttributes: [kODAttributeTypeGUID], maximumResults: 2)
        let records = try XCTUnwrap(query.resultsAllowingPartial(false) as? [ODRecord])
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        let guid = try XCTUnwrap(try record.values(forAttribute: kODAttributeTypeGUID).first as? String)
        let account = try NativeIdentity.account(generatedUid: guid)
        XCTAssertEqual(account.status, "ready")
        XCTAssertEqual(account.uid, uid)
        XCTAssertEqual(account.generatedUid?.lowercased(), guid.lowercased())

        // Exercise the real local-directory verifier at registration and at the
        // runtime status lookup, using isolated data and a stubbed parent grant.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kids-quota-admin-account-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try ServiceController(directory: directory, authorizeParent: { _, proof in proof == "verified-parent-grant" })
        var request: [String: Any] = ["op": "parentHTTP", "method": "POST", "path": "/v1/admin/children",
                                      "authorizationExternalForm": "forged-grant",
                                      "body": ["expectedPolicyRevision": controller.engine.policy.revision,
                                               "displayName": "Limited account", "generatedUid": guid, "uid": uid]]
        XCTAssertEqual(controller.native(request, uid: uid, role: "parent")["status"] as? Int, 403)
        request["authorizationExternalForm"] = "verified-parent-grant"
        var wrongBody = try XCTUnwrap(request["body"] as? [String: Any]); wrongBody["uid"] = uid + 1
        var wrongRequest = request; wrongRequest["body"] = wrongBody
        XCTAssertEqual(controller.native(wrongRequest, uid: uid, role: "parent")["status"] as? Int, 422)
        XCTAssertEqual(controller.native(request, uid: uid, role: "parent")["status"] as? Int, 201)
        let status = controller.native(["op": "childStatus"], uid: uid, role: "agent")
        XCTAssertEqual(status["configured"] as? Bool, true)
        XCTAssertEqual(status["childName"] as? String, "Limited account")
    }
}
