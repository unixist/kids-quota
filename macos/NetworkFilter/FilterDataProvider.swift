import Foundation
import NetworkExtension
import Security
import os

final class FilterDataProvider: NEFilterDataProvider {
    private let lock = NSLock()
    private let pollQueue = DispatchQueue(label: "com.kidsquota.filter.policy")
    private var timer: DispatchSourceTimer?
    private var policy = FilterPolicy()
    private var lastPolicy: TimeInterval = 0
    private var tracked: [UUID: (NEFilterSocketFlow, SourceIdentity)] = [:]
    private var unattributedFlows = 0
    private let log = Logger(subsystem: "com.kidsquota.app.networkfilter", category: "filter")

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        refreshPolicy()
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.refreshPolicy() }
        self.timer = timer; timer.resume(); completionHandler(nil)
    }
    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        timer?.cancel(); timer = nil
        lock.lock(); tracked.removeAll(); lock.unlock(); completionHandler()
    }
    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        guard let socket = flow as? NEFilterSocketFlow else { return .allow() }
        // Exclude known parent/system flows before signature lookup, so unrelated OS services
        // do not create a false attribution warning for the children.
        if let uid = AuditIdentity.effectiveUID(flow.sourceAppAuditToken) {
            lock.lock(); let monitored = policy.monitors(uid); lock.unlock()
            if !monitored { return .allow() }
        }
        guard let source = SourceIdentity(auditData: flow.sourceAppAuditToken) else {
            lock.lock(); unattributedFlows += 1; lock.unlock()
            return .allow()
        }
        lock.lock()
        defer { lock.unlock() }
        guard policy.monitors(source.uid) else { return .allow() }
        source.prime(policy.rules.filter { $0.uid == source.uid }.map(\.requirement))
        if blocked(source) { return .drop() }
        tracked[flow.identifier] = (socket, source)
        // Never issue a terminal allow for monitored sockets. Keep callbacks after the first byte.
        let verdict = NEFilterNewFlowVerdict.filterDataVerdict(withFilterInbound: true, peekInboundBytes: 1, filterOutbound: true, peekOutboundBytes: 1)
        verdict.shouldReport = true
        return verdict
    }
    override func handleInboundData(from flow: NEFilterFlow, readBytesStartOffset offset: Int, readBytes: Data) -> NEFilterDataVerdict { dataVerdict(flow, count: readBytes.count) }
    override func handleOutboundData(from flow: NEFilterFlow, readBytesStartOffset offset: Int, readBytes: Data) -> NEFilterDataVerdict { dataVerdict(flow, count: readBytes.count) }
    override func handleInboundDataComplete(for flow: NEFilterFlow) -> NEFilterDataVerdict { dataVerdict(flow, count: 0) }
    override func handleOutboundDataComplete(for flow: NEFilterFlow) -> NEFilterDataVerdict { dataVerdict(flow, count: 0) }
    override func handle(_ report: NEFilterReport) {
        if report.event == .flowClosed, let id = report.flow?.identifier { lock.lock(); tracked.removeValue(forKey: id); lock.unlock() }
    }
    private func dataVerdict(_ flow: NEFilterFlow, count: Int) -> NEFilterDataVerdict {
        lock.lock(); defer { lock.unlock() }
        guard let (_, source) = tracked[flow.identifier] else { return .drop() }
        return blocked(source) ? .drop() : NEFilterDataVerdict(passBytes: count, peekBytes: 1)
    }
    /// Caller holds lock. A lost daemon blocks only previously configured native app identities.
    private func blocked(_ source: SourceIdentity) -> Bool {
        policy.blocks(uid: source.uid, isStale: ProcessInfo.processInfo.systemUptime - lastPolicy > 15, matches: source.matches)
    }
    private func refreshPolicy() {
        lock.lock(); let unknown = unattributedFlows; lock.unlock()
        do {
            let value = try DaemonSocket.request(["op": "filterRules", "unattributedFlows": unknown])
            let next = try JSONDecoder().decode(FilterPolicy.self, from: JSONSerialization.data(withJSONObject: value))
            lock.lock(); policy = next; lastPolicy = ProcessInfo.processInfo.systemUptime
            for (_, source) in tracked.values { source.prime(next.rules.filter { $0.uid == source.uid }.map(\.requirement)) }
            let toDrop = tracked.values.filter { blocked($0.1) }.map(\.0)
            lock.unlock()
            for flow in toDrop { update(flow, using: .drop(), for: .any) }
        } catch {
            log.error("Policy refresh failed: \(error.localizedDescription, privacy: .public)")
            lock.lock(); let toDrop = tracked.values.filter { blocked($0.1) }.map(\.0); lock.unlock()
            for flow in toDrop { update(flow, using: .drop(), for: .any) }
        }
    }
}

private final class SourceIdentity {
    let uid: UInt32
    private let code: SecCode
    private var matchesByRequirement: [String: Bool] = [:]
    init?(auditData: Data?) {
        guard let data = auditData, let effectiveUID = AuditIdentity.effectiveUID(data) else { return nil }
        uid = effectiveUID
        var reference: SecCode?
        let attributes = [kSecGuestAttributeAudit as String: data] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &reference) == errSecSuccess, let reference else { return nil }
        code = reference
    }
    // Prime even unexhausted rules while the originating process is alive. A retained
    // flow keeps its authenticated identity if that process exits before exhaustion.
    // Provider serializes access with its lock.
    func prime(_ requirements: [String]) { for text in requirements { _ = matches(text) } }
    func matches(_ text: String) -> Bool {
        if let result = matchesByRequirement[text] { return result }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        let result = SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
        matchesByRequirement[text] = result
        return result
    }
}
