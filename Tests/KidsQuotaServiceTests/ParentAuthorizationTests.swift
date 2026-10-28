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
}
