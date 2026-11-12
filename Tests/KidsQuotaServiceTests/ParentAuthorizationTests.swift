import XCTest
import Security
@testable import KidsQuotaService

final class ParentAuthorizationTests: XCTestCase {
    func testRuleRegistrationRejectsNonRootBeforeWritingDatabase() {
        var wrote = false
        XCTAssertThrowsError(try ParentAuthorization.registerAdministratorRight(uid:501) { _ in
            wrote = true
            return errAuthorizationSuccess
        })
        XCTAssertFalse(wrote)
    }

    func testRuleRegistrationPropagatesAuthorizationDatabaseFailure() {
        XCTAssertThrowsError(try ParentAuthorization.registerAdministratorRight(uid:0) { _ in errAuthorizationDenied })
        XCTAssertThrowsError(try ParentAuthorization.registerAdministratorRight(uid:0) { _ in errAuthorizationInternal })
    }

    func testRegistrationReplacesWeakRuleWithExpiringAdministratorAuthentication() throws {
        var databaseRule: [String:Any] = ["class":"allow","session-owner":true,"group":"staff","shared":true]
        try ParentAuthorization.registerAdministratorRight(uid:0) { databaseRule = $0;return errAuthorizationSuccess }
        XCTAssertEqual(databaseRule["class"] as? String,"user")
        XCTAssertEqual(databaseRule["group"] as? String,"admin")
        XCTAssertEqual(databaseRule["authenticate-user"] as? Bool,true)
        XCTAssertEqual(databaseRule["session-owner"] as? Bool,false)
        XCTAssertEqual(databaseRule["shared"] as? Bool,false)
        XCTAssertEqual(databaseRule["timeout"] as? Int,300)
        XCTAssertEqual(databaseRule["allow-root"] as? Bool,true)
    }

    func testMissingPermissiveAndMalformedRulesCannotReachGrantValidation() throws {
        var installed: [String: Any] = [:]
        try ParentAuthorization.registerAdministratorRight(uid: 0) { installed = $0; return errAuthorizationSuccess }
        var invalid: [[String: Any]?] = [nil, [:], ["class": "allow"], ["class": "rule", "rule": "default"]]
        for (key, value) in [("class", "allow" as Any), ("group", "staff"), ("authenticate-user", false),
                             ("session-owner", true), ("shared", true), ("allow-root", false),
                             ("authenticate-user", 1), ("shared", "false"),
                             ("entitled", true), ("entitled-group", true), ("vpn-entitled-group", true),
                             ("entitled", "false"), ("entitled-group", 0), ("vpn-entitled-group", "false"),
                             ("timeout", 301), ("timeout", NSNumber(value: 300.5)), ("timeout", true), ("timeout", "300")] {
            var rule = installed; rule[key] = value; invalid.append(rule)
        }
        for key in ["class", "group", "authenticate-user", "session-owner", "shared", "allow-root", "timeout"] {
            var rule = installed; rule.removeValue(forKey: key); invalid.append(rule)
        }
        for definition in invalid {
            var checkedGrant = false
            XCTAssertFalse(ParentAuthorization.validateInstalledRule(definition) { checkedGrant = true; return true })
            XCTAssertFalse(checkedGrant, "Machine fallback or a permissive rule must never authorize a parent request.")
        }
    }

    func testInstalledNonsharedRuleStillRequiresAnActualCurrentGrant() throws {
        var installed: [String: Any] = [:]
        try ParentAuthorization.registerAdministratorRight(uid: 0) { installed = $0; return errAuthorizationSuccess }
        var checks = 0
        XCTAssertFalse(ParentAuthorization.validateInstalledRule(installed) { checks += 1; return false })
        XCTAssertTrue(ParentAuthorization.validateInstalledRule(installed) { checks += 1; return true })
        XCTAssertEqual(checks, 2)
        for key in ["entitled", "entitled-group", "vpn-entitled-group"] { installed[key] = false }
        XCTAssertTrue(ParentAuthorization.validateInstalledRule(installed) { true })
    }
}
