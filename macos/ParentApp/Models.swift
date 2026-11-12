import Foundation

struct BuildFeatures: Equatable {
    let isLocalInstall: Bool
    static var current: BuildFeatures { .init(info: Bundle.main.infoDictionary ?? [:]) }
    init(info: [String: Any]) { isLocalInstall = info["KidsQuotaLocalInstall"] as? Bool == true }
    var canActivateNetworkFilter: Bool { !isLocalInstall }
    var networkFilterNotice: String {
        "App network blocking is unavailable in this local build. Selected app usage can count toward the weekly allowance, but apps keep their internet access when time runs out."
    }
    static let chromeExtensionPath = "/Library/Application Support/KidsQuota/BrowserExtensions/Chrome"
}

struct ChildItem: Identifiable, Decodable { let id: String; let displayName: String }
struct DomainItem: Codable, Hashable { let hostname: String; let includeSubdomains: Bool }
struct ServiceItem: Identifiable, Decodable { let id: String; let name: String; let domains: [DomainItem]; let applicationIds: [String] }
struct AppItem: Identifiable, Decodable { let id: String; let displayName: String; let status: String }
struct QuotaItem: Identifiable, Decodable { let id: String; let childId: String; let serviceId: String; let weeklyLimitSeconds: Int }
struct BalanceItem: Decodable {
    let quotaId: String; let serviceId: String; let limitSeconds: Int; let usedSeconds: Int; let remainingSeconds: Int
    let quotaState: String; let coverage: String; let periodEnd: String
    let blockingReason: String?
    var trackingPaused: Bool { remainingSeconds > 0 && blockingReason == "collector_unavailable" }
}
struct ResetItem: Decodable { var weekday: String; var localTime: String; var timeZone: String }
struct PendingResetItem: Decodable { let schedule: ResetItem; let effectiveAt: String }
struct ClientItem: Decodable, Identifiable { let id: String; let name: String; let scopes: [String]; let childIds: [String]; let administrator: Bool? }
struct AdminState: Decodable {
    let policyRevision: Int
    let policy: HouseholdPolicy
    let clients: [ClientItem]
    let filterConnected: Bool?
    let unattributedFlows: Int?
    let phoneDashboard: PhoneDashboardStatus?
}
struct PhoneDashboardStatus: Decodable {
    let configured: Bool
    let endpoint: String?
    let deviceName: String?
    let uploading: Bool
    let lastAttempt: String?
    let lastSuccess: String?
    let lastError: String?
    let problemKind: String?
    let intervalSeconds: Int
    var lastSuccessDate: Date? { lastSuccess.flatMap { ISO8601DateFormatter().date(from: $0) } }
    var problem: PhoneDashboardProblem? { problemKind.flatMap(PhoneDashboardProblem.init(rawValue:)) }
    var needsAttention: Bool { problemKind != nil || lastError != nil }
    var title: String {
        if needsAttention { return "Sharing needs attention" }
        if !configured { return "Sharing is off" }
        return lastSuccessDate == nil ? "Connecting…" : "Sharing with your phone"
    }
    var recovery: PhoneDashboardRecovery? {
        if !needsAttention { return nil }
        switch problem {
        case .connection: return .retry
        case .authorization, .endpoint, .localStorage: return .reconnect
        default: return .checkSetup
        }
    }
}
enum PhoneDashboardProblem: String { case connection, authorization, endpoint, clockConflict = "clock_conflict", invalidUpdate = "invalid_update", localStorage = "local_storage" }
enum PhoneDashboardRecovery: Equatable { case retry, reconnect, checkSetup }

enum PhoneConnectionDocument {
    static func body(_ text: String) throws -> [String: Any] {
        let data = Data(text.utf8)
        guard data.count <= 16_384, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["schemaVersion", "endpoint", "deviceId", "deviceName", "writeToken"] else {
            throw ParentError.message("Import or paste the Mac connection document. An iPhone connection document cannot connect this Mac.")
        }
        return object
    }
}
struct HouseholdPolicy: Decodable {
    let children: [ChildItem]; let services: [ServiceItem]; let applicationBindings: [AppItem]; let quotas: [QuotaItem]; let reset: ResetItem; let pendingReset: PendingResetItem?
}
struct BalanceList: Decodable { let items: [BalanceItem] }

enum Presentation {
    static func duration(_ seconds: Int) -> String {
        let minutes = max(0, seconds) / 60
        if seconds > 0 && minutes == 0 { return "Less than a minute" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
    static func host(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let url = URLComponents(string: text.contains("://") ? text : "https://" + text),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasSuffix(".") ? String(host.dropLast()) : host
    }
}

struct ResetWeekTarget: Equatable {
    let childID: String
    let name: String
    let policyRevision: Int
    var title: String { "Reset \(name)'s time this week?" }
    var explanation: String { "Clear time used this week for all of \(name)'s services. Weekly allowances and the next scheduled reset stay the same. Other children's balances are unchanged." }
}
