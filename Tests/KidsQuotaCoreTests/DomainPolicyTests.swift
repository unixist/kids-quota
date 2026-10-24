import XCTest
@testable import KidsQuotaCore

final class DomainPolicyTests: XCTestCase {
    func testCanonicalizesURLCaseTrailingDotAndPort() throws {
        XCTAssertEqual(try DomainMatcher.canonicalHostname(" https://WWW.Chess.COM.:443/play "), "www.chess.com")
        XCTAssertEqual(try DomainMatcher.canonicalHostname("CHATGPT.com"), "chatgpt.com")
    }

    func testInternationalizedDomainIsASCII() throws {
        XCTAssertEqual(try DomainMatcher.canonicalHostname("bücher.de"), "xn--bcher-kva.de")
    }

    func testRejectsIPsAndInvalidInputs() {
        for input in ["127.0.0.1", "https://[::1]/", "localhost", "*.chess.com", "https://user:pass@chess.com/", "ftp://chess.com", "-bad.com", "bad-.com", "bad..com", "chess.com\\evil.com"] {
            XCTAssertThrowsError(try DomainMatcher.canonicalHostname(input), input)
        }
    }

    func testRejectsPublicAndPrivateSuffixes() {
        for input in ["com", "co.uk", "com.au", "github.io", "blogspot.com", "appspot.com", "foo.ck"] {
            XCTAssertThrowsError(try DomainMatcher.canonicalHostname(input), input)
        }
    }

    func testPublicSuffixExceptionsAndRegistrableDomains() throws {
        for input in ["www.ck", "school.co.uk", "child.github.io", "child.blogspot.com"] {
            XCTAssertEqual(try DomainMatcher.canonicalHostname(input), input)
        }
    }

    func testMatchingRespectsDomainLabelBoundary() {
        let rule = DomainRule(hostname: "chess.com")
        XCTAssertTrue(DomainMatcher.matches(hostname: "chess.com", rule: rule))
        XCTAssertTrue(DomainMatcher.matches(hostname: "www.chess.com", rule: rule))
        XCTAssertFalse(DomainMatcher.matches(hostname: "notchess.com", rule: rule))
        XCTAssertFalse(DomainMatcher.matches(hostname: "chess.com.evil.org", rule: rule))
        XCTAssertFalse(DomainMatcher.matches(hostname: "www.chess.com", rule: .init(hostname: "chess.com", includeSubdomains: false)))
    }

    func testOverlapsHonorsExactOnlyRules() {
        XCTAssertTrue(DomainMatcher.overlaps(.init(hostname: "chess.com"), .init(hostname: "play.chess.com", includeSubdomains: false)))
        XCTAssertFalse(DomainMatcher.overlaps(.init(hostname: "chess.com", includeSubdomains: false), .init(hostname: "play.chess.com")))
    }

    func testStarterPolicyHasNoInventedIdentity() throws {
        let policy = Policy.starter(timeZone: "America/Chicago")
        try policy.validate()
        XCTAssertEqual(policy.services.map(\.id), ["chesscom", "chatgpt"])
        XCTAssertTrue(policy.children.isEmpty)
        XCTAssertTrue(policy.applicationBindings.isEmpty)
    }

    func testSchemaExampleLoadsWithDefaultRevision() throws {
        let url = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("config/example-policy.json")
        let policy = try JSONDecoder().decode(Policy.self, from: Data(contentsOf: url))
        try policy.validate()
        XCTAssertEqual(policy.revision, 0)
        XCTAssertFalse(policy.quotas.isEmpty)
        XCTAssertTrue(policy.quotas.allSatisfy { $0.weeklyLimitSeconds == 21_600 })
    }

    func testOverlappingAssignmentsRejectedForSameChild() {
        var policy = fixturePolicy()
        policy.services[1].domains = [.init(hostname: "play.chess.com")]
        XCTAssertThrowsError(try policy.validate())
    }

    func testOverlappingServicesAllowedForDifferentChildren() throws {
        var policy = fixturePolicy()
        policy.services[1].domains = [.init(hostname: "play.chess.com")]
        policy.quotas = [.init(id: "a-chess", childId: "alice", serviceId: "chesscom"), .init(id: "b-chat", childId: "bob", serviceId: "chatgpt")]
        try policy.validate()
    }

    func testWebsiteAndAppMapToOneAssignedService() throws {
        var policy = fixturePolicy()
        policy.applicationBindings = [.init(id: "chess-app", displayName: "Chess", identity: .init(signingIdentifier: "org.example.chess", designatedRequirement: "identifier org.example.chess"))]
        policy.services[0].applicationIds = ["chess-app"]
        try policy.validate()
        XCTAssertEqual(policy.serviceID(forHostname: "https://play.chess.com/game", childId: "alice"), "chesscom")
        XCTAssertEqual(policy.serviceID(forApplicationID: "chess-app", childId: "alice"), "chesscom")
        XCTAssertNil(policy.serviceID(forApplicationID: "other-app", childId: "alice"))
        XCTAssertNil(policy.serviceID(forHostname: "chess.com", childId: "unknown"))
    }

    func testDuplicateAccountsAndUnknownReferencesRejected() {
        var policy = fixturePolicy()
        policy.children[0].macOSAccount.generatedUid = "SAME"
        policy.children[1].macOSAccount.generatedUid = "same"
        XCTAssertThrowsError(try policy.validate())
        policy = fixturePolicy()
        policy.services[0].applicationIds = ["missing"]
        XCTAssertThrowsError(try policy.validate())
        policy = fixturePolicy()
        policy.quotas[0].weeklyLimitSeconds = -1
        XCTAssertThrowsError(try policy.validate())
    }

    func testReadyBindingsNeedIdentityAndLoopbackAPI() {
        var policy = fixturePolicy()
        policy.children[0].macOSAccount.status = "ready"
        XCTAssertThrowsError(try policy.validate())
        policy = fixturePolicy()
        policy.applicationBindings = [.init(id: "app", displayName: "App", status: "ready")]
        XCTAssertThrowsError(try policy.validate())
        policy = fixturePolicy()
        policy.api.bindAddress = "0.0.0.0"
        XCTAssertThrowsError(try policy.validate())
    }

    func testNumericUIDsAreUniqueAndReadyAccountsAreNormalUsers() throws {
        var policy = fixturePolicy()
        policy.children[0].macOSAccount = .init(status: "ready", generatedUid: "alice-guid", uid: 501)
        policy.children[1].macOSAccount = .init(status: "ready", generatedUid: "bob-guid", uid: 502)
        try policy.validate()
        policy.children[1].macOSAccount.uid = 501
        XCTAssertThrowsError(try policy.validate())
        policy.children[1].macOSAccount.uid = 0
        XCTAssertThrowsError(try policy.validate())
        policy.children[1].macOSAccount.uid = nil
        XCTAssertThrowsError(try policy.validate())
        policy.children[1].macOSAccount.status = "invented"
        XCTAssertThrowsError(try policy.validate())
    }
}

func fixturePolicy() -> Policy {
    var policy = Policy.starter(timeZone: "UTC")
    policy.children = [.init(id: "alice", displayName: "Alice"), .init(id: "bob", displayName: "Bob")]
    policy.quotas = [
        .init(id: "a-chess", childId: "alice", serviceId: "chesscom"),
        .init(id: "a-chat", childId: "alice", serviceId: "chatgpt"),
        .init(id: "b-chess", childId: "bob", serviceId: "chesscom")
    ]
    return policy
}

func instant(_ string: String) -> Date { ISO8601DateFormatter().date(from: string)! }
