import Foundation

/// The service must serialize calls. Browser/native transports select foreground
/// ownership; this class owns elapsed accounting and shares one ledger per child.
public final class QuotaEngine {
    public private(set) var policy: Policy
    public let store: QuotaStore
    public let heartbeatTimeout: TimeInterval
    private var floor: Date?
    private var active: Active?
    private var sequences: [String: UInt64] = [:]
    private var lastWall: Date?
    private var lastMonotonic: Double?

    private struct Active {
        var childId: String
        var serviceId: String
        var quotaId: String
        var sessionId: String
        var heartbeat: Double
    }

    public init(store: QuotaStore, policy: Policy, heartbeatTimeout: TimeInterval = 15) throws {
        try policy.validate()
        guard heartbeatTimeout > 0, heartbeatTimeout.isFinite else { throw QuotaError.invalidPolicy("Invalid heartbeat timeout.") }
        self.store = store; self.policy = policy; self.heartbeatTimeout = heartbeatTimeout
        floor = try store.periodFloor()
        try store.savePolicy(policy)
    }

    private func period(at date: Date) throws -> WeekPeriod {
        if let pending = policy.pendingReset, date >= pending.effectiveAt {
            floor = max(floor ?? pending.effectiveAt, pending.effectiveAt)
            policy.reset = pending.schedule; policy.pendingReset = nil
            policy.revision += 1
        }
        let effectiveDate = max(date, floor ?? date)
        let candidate = try WeeklyCalendar(schedule: policy.reset).period(containing: effectiveDate)
        let start = max(candidate.start, floor ?? candidate.start)
        floor = start
        return WeekPeriod(start: start, end: candidate.end)
    }

    public func reportActivity(childId: String, serviceId: String?, sessionId: String, sequence: UInt64,
                               isActive: Bool, now: Date, monotonic: Double) throws {
        guard policy.children.contains(where: { $0.id == childId }) else { throw QuotaError.unknownChild }
        guard monotonic.isFinite, monotonic >= 0, !sessionId.isEmpty, sessionId.count <= 256 else { throw QuotaError.invalidPolicy("Invalid activity report.") }
        let key = childId + ":" + sessionId
        if let previous = sequences[key], sequence <= previous { return }
        try tick(now: now, monotonic: monotonic)
        sequences[key] = sequence
        // A late inactive report from a different child/session must not erase a
        // newer foreground owner. The trusted collector arbitrates active reports.
        if !isActive || serviceId == nil {
            if active?.childId == childId && active?.sessionId == sessionId { active = nil }
            return
        }
        guard let quota = policy.quotas.first(where: { $0.childId == childId && $0.serviceId == serviceId }) else {
            if active?.childId == childId { active = nil }
            return
        }
        active = Active(childId: childId, serviceId: quota.serviceId, quotaId: quota.id, sessionId: sessionId, heartbeat: monotonic)
        lastWall = now; lastMonotonic = monotonic
        if sequences.count > 4096 { sequences = [key: sequence] }
    }

    public func stop(now: Date, monotonic: Double) throws {
        try tick(now: now, monotonic: monotonic)
        active = nil
    }

    public func tick(now: Date, monotonic: Double) throws {
        guard monotonic.isFinite, monotonic >= 0 else { throw QuotaError.invalidPolicy("Invalid monotonic time.") }
        let previousPolicy = policy, previousFloor = floor
        var increments: [UsageIncrement] = []
        if let previousWall = lastWall, let previousMonotonic = lastMonotonic, let activity = active {
            let elapsed = monotonic - previousMonotonic
            let wallElapsed = now.timeIntervalSince(previousWall)
            let expiresAt = activity.heartbeat + heartbeatTimeout
            let boundedElapsed = max(0, min(monotonic, expiresAt) - previousMonotonic)
            if elapsed < 0 {
                // A monotonic clock reset can indicate a new boot. Never charge
                // time inferred across the clock discontinuity.
                active = nil
            } else if boundedElapsed > 0 {
                if wallElapsed >= 0 && abs(wallElapsed - elapsed) <= 2 {
                    var cursor = previousWall
                    var remaining = boundedElapsed
                    while remaining > 0.000_001 {
                        let current = try period(at: cursor)
                        var untilBoundary = current.end.timeIntervalSince(cursor)
                        if let pending = policy.pendingReset { untilBoundary = min(untilBoundary, pending.effectiveAt.timeIntervalSince(cursor)) }
                        let amount = min(remaining, max(0.000_001, untilBoundary))
                        increments.append(.init(childId: activity.childId, quotaId: activity.quotaId, periodStart: current.start, seconds: amount))
                        cursor = cursor.addingTimeInterval(amount); remaining -= amount
                    }
                } else if wallElapsed < 0 && elapsed <= heartbeatTimeout {
                    // A wall-clock rollback doesn't refund usage. Monotonic time
                    // is charged to the current high-water period.
                    let current = try period(at: previousWall)
                    increments.append(.init(childId: activity.childId, quotaId: activity.quotaId, periodStart: current.start, seconds: boundedElapsed))
                } else {
                    // Sleep or a large forward wall-clock jump: activity needs a
                    // fresh report; do not bill the unobserved interval.
                    active = nil
                }
            }
            if monotonic >= expiresAt { active = nil }
        }
        _ = try period(at: now)
        do {
            if !increments.isEmpty || floor != previousFloor || policy != previousPolicy {
                try store.recordUsage(increments, periodFloor: floor, policy: policy != previousPolicy ? policy : nil)
            }
            lastWall = now; lastMonotonic = monotonic
        } catch {
            policy = previousPolicy; floor = previousFloor
            throw error
        }
    }

    public func balances(childId: String, now: Date, monotonic: Double, coverage: [String: Bool] = [:]) throws -> BalanceSnapshot {
        guard policy.children.contains(where: { $0.id == childId }) else { throw QuotaError.unknownChild }
        try tick(now: now, monotonic: monotonic)
        let current = try period(at: now)
        let items = try policy.quotas.filter { $0.childId == childId }.map { quota -> Balance in
            let used = Int(ceil(try store.usageSeconds(childId: childId, quotaId: quota.id, periodStart: current.start)))
            let remaining = max(0, quota.weeklyLimitSeconds - used)
            return Balance(quotaId: quota.id, serviceId: quota.serviceId, periodStart: current.start, periodEnd: current.end,
                           limitSeconds: quota.weeklyLimitSeconds, usedSeconds: used, remainingSeconds: remaining,
                           quotaState: remaining == 0 ? "exhausted" : "available", coverage: coverage[quota.serviceId] == true ? "complete" : "incomplete")
        }
        return BalanceSnapshot(asOf: now, policyRevision: policy.revision, childId: childId, items: items)
    }

    @discardableResult
    public func replacePolicy(_ proposed: Policy, expectedRevision: Int, now: Date, monotonic: Double) throws -> Policy {
        guard expectedRevision == policy.revision else { throw QuotaError.conflict }
        try tick(now: now, monotonic: monotonic)
        guard expectedRevision == policy.revision else { throw QuotaError.conflict }
        var next = proposed
        next.revision = policy.revision + 1
        // Editing an allowance or domain list must never redirect an existing
        // ledger ID to a different child/service.
        for old in policy.quotas {
            if let replacement = next.quotas.first(where: { $0.id == old.id }), replacement.childId != old.childId || replacement.serviceId != old.serviceId {
                throw QuotaError.invalidPolicy("An existing quota's child and service cannot be changed.")
            }
        }
        if next.reset != policy.reset {
            let boundary = try period(at: now).end
            next.pendingReset = .init(schedule: next.reset, effectiveAt: boundary)
            next.reset = policy.reset
        } else { next.pendingReset = policy.pendingReset }
        try next.validate()
        try store.savePolicy(next)
        policy = next
        if let activity = active, !next.quotas.contains(where: { $0.id == activity.quotaId && $0.childId == activity.childId }) { active = nil }
        return next
    }
}
