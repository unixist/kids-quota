import Foundation

public enum DemoFamily {
    public static func snapshot(now: Date = Date()) -> FamilySnapshot {
        let start = now.addingTimeInterval(-86_400), end = now.addingTimeInterval(5 * 86_400)
        func balance(_ name: String, _ used: Int, paused: Bool = false) -> QuotaBalance {
            QuotaBalance(quotaId: name.lowercased().replacingOccurrences(of: ".", with: "-"), serviceId: name.lowercased().replacingOccurrences(of: ".", with: "-"), serviceName: name, domains: [name.lowercased()], limitSeconds: 21_600, usedSeconds: used, remainingSeconds: max(0, 21_600 - used), periodStart: start, periodEnd: end, quotaState: used >= 21_600 ? "exhausted" : "available", coverage: paused ? "incomplete" : "complete", blockingReason: paused ? "collector_unavailable" : used >= 21_600 ? "exhausted" : "available")
        }
        let children = [QuotaChild(id: "alex", name: "Alex", balances: [balance("Chess.com", 8_100), balance("ChatGPT", 3_600)]),
                        QuotaChild(id: "sam", name: "Sam", balances: [balance("Chess.com", 18_900), balance("ChatGPT", 5_400)])]
        let mac = MacSnapshot(schemaVersion: 1, deviceId: "demo-mac", deviceName: "Family Mac", capturedAt: now.addingTimeInterval(-120), resetTimeZone: "America/Chicago", children: children)
        return FamilySnapshot(schemaVersion: 1, familyName: "Our family", servedAt: now, devices: [DeviceSnapshot(deviceId: "demo-mac", deviceName: "Family Mac", receivedAt: now.addingTimeInterval(-119), snapshot: mac)])
    }
}
