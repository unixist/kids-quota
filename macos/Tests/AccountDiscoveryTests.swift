import XCTest

final class AccountDiscoveryTests: XCTestCase {
    private func account(_ uid: UInt32 = 501, _ name: String = "alex", _ admin: Bool? = nil, _ guid: String = "stable-guid") -> LocalAccount? {
        AccountDiscovery.selectableAccount(name: name, displayName: "Alex", uid: uid, generatedUID: guid, isAdministrator: admin)
    }

    func testBothStandardAndAdministratorAccountsAreSelectableAndClearlyLabeled() throws {
        let standard = try XCTUnwrap(account(501, "alex", false))
        let administrator = try XCTUnwrap(account(502, "sam", true, "another-guid"))
        XCTAssertEqual(standard.accountType, "Standard")
        XCTAssertEqual(administrator.accountType, "Administrator")
        XCTAssertEqual(administrator.id, "another-guid")
        XCTAssertEqual(administrator.uid, 502)
    }

    func testUnknownMembershipDoesNotHideOrMislabelAnAccount() throws {
        XCTAssertEqual(try XCTUnwrap(account(501, "alex", nil)).accountType, "Account type unavailable")
    }

    func testSystemAndMalformedAccountsAreExcluded() {
        XCTAssertNil(account(0, "root", true))
        XCTAssertNil(account(499, "daemon", false))
        XCTAssertNil(account(600, "_service", true))
        XCTAssertNil(account(501, "", false))
        XCTAssertNil(account(501, "alex", true, ""))
        XCTAssertNotNil(account(500, "login", true))
    }

    func testMissingDisplayNameFallsBackToAccountName() throws {
        let account = try XCTUnwrap(AccountDiscovery.selectableAccount(name: "sam", displayName: nil, uid: 501, generatedUID: "stable-guid", isAdministrator: true))
        XCTAssertEqual(account.displayName, "sam")
    }
}
