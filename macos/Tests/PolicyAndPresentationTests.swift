import XCTest

final class PolicyAndPresentationTests: XCTestCase {
    func testLocalBuildCannotActivateNetworkFiltering() {
        let local = BuildFeatures(info: ["KidsQuotaLocalInstall": true])
        XCTAssertTrue(local.isLocalInstall)
        XCTAssertFalse(local.canActivateNetworkFilter)
        XCTAssertTrue(local.networkFilterNotice.contains("apps keep their internet access"))
        XCTAssertTrue(BuildFeatures(info: [:]).canActivateNetworkFilter)
        XCTAssertTrue(BuildFeatures(info: ["KidsQuotaLocalInstall": false]).canActivateNetworkFilter)
    }
    @MainActor func testLocalFilterActivationReturnsWithoutStartingAnOSRequest() {
        let filter = FilterActivation(features: BuildFeatures(info: ["KidsQuotaLocalInstall": true]))
        filter.enable()
        XCTAssertFalse(filter.working)
        XCTAssertEqual(filter.status, filter.features.networkFilterNotice)
    }
    func testAuditTokenUsesEffectiveUIDAndRejectsTruncation() {
        let words: [UInt32] = [501, 502, 20, 503, 20, 9999, 7, 1]
        let token = words.withUnsafeBytes { Data($0) }
        XCTAssertEqual(AuditIdentity.effectiveUID(token), 502)
        XCTAssertNil(AuditIdentity.effectiveUID(Data(token.prefix(28))))
        XCTAssertNil(AuditIdentity.effectiveUID(nil))
    }
    func testGeneratedSigningEntitlementsRetainRequiredCapabilities() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func plist(_ path: String) throws -> [String: Any] {
            try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent(path)), format: nil) as? [String: Any])
        }
        let parent = try plist("ParentApp/ParentApp.entitlements")
        XCTAssertEqual(parent["com.apple.developer.system-extension.install"] as? Bool, true)
        for value in [parent, try plist("NetworkFilter/NetworkFilter.entitlements")] {
            XCTAssertEqual(value["com.apple.developer.networking.networkextension"] as? [String], ["content-filter-provider-systemextension"])
        }
        let safari = try plist("SafariExtension/SafariExtension.entitlements")
        XCTAssertEqual(safari["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(safari["com.apple.security.network.client"] as? Bool, true)
        XCTAssertTrue((safari["com.apple.security.temporary-exception.files.absolute-path.read-write"] as? [String] ?? []).contains("/var/run/kids-quota.sock"))
    }
    func testSiblingAndParentIsolation() {
        let rules = FilterPolicy(rules: [.init(uid: 502, requirement: "chess", blocked: true, serviceId: "chess")], childUIDs: [502, 503])
        XCTAssertTrue(rules.blocks(uid: 502, isStale: false) { $0 == "chess" })
        XCTAssertFalse(rules.blocks(uid: 503, isStale: false) { $0 == "chess" })
        XCTAssertFalse(rules.blocks(uid: 501, isStale: true) { $0 == "chess" })
        XCTAssertFalse(rules.blocks(uid: 502, isStale: false) { $0 == "other-app" })
    }
    func testUnexhaustedSocketRemainsMonitoredAndFailsClosedOnlyForItsConfiguredApp() {
        let rules = FilterPolicy(rules: [.init(uid: 502, requirement: "chatgpt", blocked: false, serviceId: "chatgpt")], childUIDs: [502, 503])
        XCTAssertTrue(rules.monitors(502)); XCTAssertTrue(rules.monitors(503)); XCTAssertFalse(rules.monitors(501))
        XCTAssertFalse(rules.blocks(uid: 502, isStale: false) { $0 == "chatgpt" })
        XCTAssertTrue(rules.blocks(uid: 502, isStale: true) { $0 == "chatgpt" })
        XCTAssertFalse(rules.blocks(uid: 502, isStale: true) { $0 == "school" })
    }
    func testMalformedRuleSnapshotIsRejected() {
        let data = Data(#"{"revision":4,"rules":[{"uid":502,"blocked":true,"serviceId":"chess"}],"childUIDs":[502]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(FilterPolicy.self, from: data))
    }
    func testURLPreviewRejectsCredentialsAndUnsupportedSchemes() {
        XCTAssertEqual(Presentation.host("https://Chess.com/play?x=1"), "chess.com")
        XCTAssertEqual(Presentation.host("chatgpt.com"), "chatgpt.com")
        XCTAssertNil(Presentation.host("https://user:secret@example.com"))
        XCTAssertNil(Presentation.host("file:///Applications/Chess.app"))
        XCTAssertNil(Presentation.host(""))
    }
    func testTimeDisplayDoesNotClaimTimeRemainsAfterExhaustion() {
        XCTAssertEqual(Presentation.duration(-10), "0m")
        XCTAssertEqual(Presentation.duration(1), "Less than a minute")
        XCTAssertEqual(Presentation.duration(21_600), "6h 0m")
    }
}
