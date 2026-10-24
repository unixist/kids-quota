import Foundation

public enum QuotaError: Error, LocalizedError, Equatable {
    case invalidPolicy(String)
    case unknownChild
    case conflict
    case persistence(String)
    public var errorDescription: String? {
        switch self {
        case .invalidPolicy(let reason): return reason
        case .unknownChild: return "Child not found."
        case .conflict: return "Policy changed. Read the latest revision and try again."
        case .persistence(let reason): return "Storage error: \(reason)"
        }
    }
}

public struct ResetSchedule: Codable, Equatable {
    public var weekday: String
    public var localTime: String
    public var timeZone: String
    public init(weekday: String = "monday", localTime: String = "00:00", timeZone: String = TimeZone.current.identifier) {
        self.weekday = weekday; self.localTime = localTime; self.timeZone = timeZone
    }
}

public struct PendingReset: Codable, Equatable {
    public var schedule: ResetSchedule
    public var effectiveAt: Date
    public init(schedule: ResetSchedule, effectiveAt: Date) { self.schedule = schedule; self.effectiveAt = effectiveAt }
}

public struct MacOSAccountBinding: Codable, Equatable {
    public var status: String
    public var generatedUid: String?
    public var uid: UInt32?
    public init(status: String = "needs-selection", generatedUid: String? = nil, uid: UInt32? = nil) {
        self.status = status; self.generatedUid = generatedUid; self.uid = uid
    }
}

public struct Child: Codable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    public var macOSAccount: MacOSAccountBinding
    public init(id: String = UUID().uuidString, displayName: String, macOSAccount: MacOSAccountBinding = .init()) {
        self.id = id; self.displayName = displayName; self.macOSAccount = macOSAccount
    }
}

public struct DomainRule: Codable, Equatable, Hashable {
    public var hostname: String
    public var includeSubdomains: Bool
    public init(hostname: String, includeSubdomains: Bool = true) { self.hostname = hostname; self.includeSubdomains = includeSubdomains }
}

public struct AppIdentity: Codable, Equatable {
    public var signingIdentifier: String
    public var teamIdentifier: String?
    public var designatedRequirement: String
    public var executablePath: String?
    public init(signingIdentifier: String, teamIdentifier: String? = nil, designatedRequirement: String, executablePath: String? = nil) {
        self.signingIdentifier = signingIdentifier; self.teamIdentifier = teamIdentifier
        self.designatedRequirement = designatedRequirement; self.executablePath = executablePath
    }
}

public struct ApplicationBinding: Codable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    public var status: String
    public var identity: AppIdentity?
    public init(id: String = UUID().uuidString, displayName: String, status: String = "needs-selection", identity: AppIdentity? = nil) {
        self.id = id; self.displayName = displayName; self.status = status; self.identity = identity
    }
}

public struct ServiceDefinition: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var domains: [DomainRule]
    public var applicationIds: [String]
    public init(id: String = UUID().uuidString, name: String, domains: [DomainRule] = [], applicationIds: [String] = []) {
        self.id = id; self.name = name; self.domains = domains; self.applicationIds = applicationIds
    }
}

public struct Quota: Codable, Equatable, Identifiable {
    public var id: String
    public var childId: String
    public var serviceId: String
    public var weeklyLimitSeconds: Int
    public init(id: String = UUID().uuidString, childId: String, serviceId: String, weeklyLimitSeconds: Int = 21_600) {
        self.id = id; self.childId = childId; self.serviceId = serviceId; self.weeklyLimitSeconds = weeklyLimitSeconds
    }
}

public struct MeteringConfiguration: Codable, Equatable {
    public var mode = "foreground-activity"
    public var countPassiveViewing = true
    public var countBackgroundMedia = false
    public var pauseWhenLocked = true
    public var pauseWhenAsleep = true
    public init() {}
}
public struct EnforcementConfiguration: Codable, Equatable {
    public var websites = "browser-extension"
    public var applications = "network-content-filter"
    public init() {}
}
public struct APIConfiguration: Codable, Equatable {
    public var bindAddress = "127.0.0.1"
    public var port = 48123
    public var basePath = "/v1"
    public var authentication = "scoped-bearer-token"
    public var allowedBrowserOrigins: [String] = []
    public init() {}
}

public struct Policy: Codable, Equatable {
    public var schemaVersion: Int
    public var revision: Int
    public var reset: ResetSchedule
    public var pendingReset: PendingReset?
    public var metering: MeteringConfiguration
    public var enforcement: EnforcementConfiguration
    public var api: APIConfiguration
    public var children: [Child]
    public var applicationBindings: [ApplicationBinding]
    public var services: [ServiceDefinition]
    public var quotas: [Quota]

    public init(schemaVersion: Int = 2, revision: Int = 0, reset: ResetSchedule = .init(), pendingReset: PendingReset? = nil,
                metering: MeteringConfiguration = .init(), enforcement: EnforcementConfiguration = .init(), api: APIConfiguration = .init(),
                children: [Child] = [], applicationBindings: [ApplicationBinding] = [], services: [ServiceDefinition] = [], quotas: [Quota] = []) {
        self.schemaVersion = schemaVersion; self.revision = revision; self.reset = reset; self.pendingReset = pendingReset
        self.metering = metering; self.enforcement = enforcement; self.api = api
        self.children = children; self.applicationBindings = applicationBindings; self.services = services; self.quotas = quotas
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, revision, reset, pendingReset, metering, enforcement, api, children, applicationBindings, services, quotas }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(schemaVersion: try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 2,
                  revision: try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0,
                  reset: try c.decodeIfPresent(ResetSchedule.self, forKey: .reset) ?? .init(),
                  pendingReset: try c.decodeIfPresent(PendingReset.self, forKey: .pendingReset),
                  metering: try c.decodeIfPresent(MeteringConfiguration.self, forKey: .metering) ?? .init(),
                  enforcement: try c.decodeIfPresent(EnforcementConfiguration.self, forKey: .enforcement) ?? .init(),
                  api: try c.decodeIfPresent(APIConfiguration.self, forKey: .api) ?? .init(),
                  children: try c.decodeIfPresent([Child].self, forKey: .children) ?? [],
                  applicationBindings: try c.decodeIfPresent([ApplicationBinding].self, forKey: .applicationBindings) ?? [],
                  services: try c.decodeIfPresent([ServiceDefinition].self, forKey: .services) ?? [],
                  quotas: try c.decodeIfPresent([Quota].self, forKey: .quotas) ?? [])
    }

    public static func starter(timeZone: String = TimeZone.current.identifier) -> Policy {
        Policy(reset: .init(timeZone: timeZone), services: [
            .init(id: "chesscom", name: "Chess.com", domains: [.init(hostname: "chess.com")]),
            .init(id: "chatgpt", name: "ChatGPT", domains: [.init(hostname: "chatgpt.com")])
        ])
    }

    public func serviceID(forHostname hostname: String, childId: String) -> String? {
        guard let normalized = try? DomainMatcher.canonicalHostname(hostname) else { return nil }
        let assigned = Set(quotas.filter { $0.childId == childId }.map(\.serviceId))
        return services.first { assigned.contains($0.id) && $0.domains.contains { DomainMatcher.matches(hostname: normalized, rule: $0) } }?.id
    }

    public func serviceID(forApplicationID appID: String, childId: String) -> String? {
        let assigned = Set(quotas.filter { $0.childId == childId }.map(\.serviceId))
        return services.first { assigned.contains($0.id) && $0.applicationIds.contains(appID) }?.id
    }

    public func validate() throws {
        func reject(_ text: String) throws { throw QuotaError.invalidPolicy(text) }
        func ids(_ values: [String], label: String) throws {
            guard Set(values).count == values.count else { try reject("Duplicate \(label) ID."); return }
            for id in values where id.isEmpty || id.count > 128 || id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) == nil { try reject("Invalid \(label) ID.") }
        }
        guard schemaVersion == 2, revision >= 0 else { try reject("Unsupported policy version or revision."); return }
        _ = try WeeklyCalendar(schedule: reset)
        if let pendingReset { _ = try WeeklyCalendar(schedule: pendingReset.schedule) }
        guard api.bindAddress == "127.0.0.1", (1024...65535).contains(api.port), api.basePath == "/v1" else { try reject("The API must use a valid loopback endpoint."); return }
        guard metering.mode == "foreground-activity", !metering.countBackgroundMedia, metering.pauseWhenLocked, metering.pauseWhenAsleep,
              metering.countPassiveViewing else { try reject("Only foreground activity with lock/sleep pausing is supported."); return }
        try ids(children.map(\.id), label: "child"); try ids(services.map(\.id), label: "service")
        try ids(applicationBindings.map(\.id), label: "application"); try ids(quotas.map(\.id), label: "quota")
        let accountIDs = children.compactMap { $0.macOSAccount.generatedUid?.lowercased() }
        guard Set(accountIDs).count == accountIDs.count else { try reject("A macOS account may belong to only one child."); return }
        let numericUIDs = children.compactMap { $0.macOSAccount.uid }
        guard Set(numericUIDs).count == numericUIDs.count else { try reject("A macOS user ID may belong to only one child."); return }
        for child in children {
            guard !child.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, child.displayName.count <= 100 else { try reject("Child name is required."); return }
            guard ["needs-selection", "ready"].contains(child.macOSAccount.status) else { try reject("Unknown account binding status."); return }
            if child.macOSAccount.status == "ready" {
                guard let generatedUid = child.macOSAccount.generatedUid, !generatedUid.isEmpty,
                      let uid = child.macOSAccount.uid, uid >= 500 else { try reject("A ready child needs a verified account binding."); return }
            }
        }
        let appIDs = Set(applicationBindings.map(\.id))
        var identities = Set<String>()
        for app in applicationBindings {
            guard ["needs-selection", "ready"].contains(app.status) else { try reject("Unknown application binding status."); return }
            if let identity = app.identity {
                guard !identity.signingIdentifier.isEmpty, !identity.designatedRequirement.isEmpty else { try reject("Incomplete application identity."); return }
                let key = identity.signingIdentifier + ":" + (identity.teamIdentifier ?? "")
                guard identities.insert(key).inserted else { try reject("Duplicate application identity."); return }
            } else if app.status == "ready" { try reject("A ready application needs a verified identity.") }
        }
        for service in services {
            guard !service.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, service.name.count <= 100,
                  !service.domains.isEmpty || !service.applicationIds.isEmpty else { try reject("A service needs a name and website or app."); return }
            guard Set(service.applicationIds).isSubset(of: appIDs), Set(service.applicationIds).count == service.applicationIds.count else { try reject("Unknown or duplicate application binding."); return }
            for rule in service.domains {
                guard try DomainMatcher.canonicalHostname(rule.hostname) == rule.hostname else { try reject("Domains must be canonical hostnames."); return }
            }
            guard Set(service.domains).count == service.domains.count else { try reject("Duplicate domain rule."); return }
        }
        let childIDs = Set(children.map(\.id)), serviceIDs = Set(services.map(\.id))
        var pairs = Set<String>()
        for quota in quotas {
            guard childIDs.contains(quota.childId), serviceIDs.contains(quota.serviceId), (0...604_800_000).contains(quota.weeklyLimitSeconds) else { try reject("Invalid quota assignment or allowance."); return }
            guard pairs.insert(quota.childId + ":" + quota.serviceId).inserted else { try reject("Duplicate child/service quota."); return }
        }
        for child in children {
            let assigned = Set(quotas.filter { $0.childId == child.id }.map(\.serviceId))
            let groups = services.filter { assigned.contains($0.id) }
            for i in groups.indices { for j in groups.indices where j > i {
                if !Set(groups[i].applicationIds).isDisjoint(with: groups[j].applicationIds) || groups[i].domains.contains(where: { left in groups[j].domains.contains(where: { DomainMatcher.overlaps(left, $0) }) }) {
                    try reject("Overlapping services for \(child.displayName).")
                }
            } }
        }
    }
}

public struct Balance: Codable, Equatable {
    public var quotaId: String
    public var serviceId: String
    public var periodStart: Date
    public var periodEnd: Date
    public var limitSeconds: Int
    public var usedSeconds: Int
    public var remainingSeconds: Int
    public var quotaState: String
    public var coverage: String
}
public struct BalanceSnapshot: Codable, Equatable {
    public var asOf: Date
    public var policyRevision: Int
    public var childId: String
    public var items: [Balance]
}
