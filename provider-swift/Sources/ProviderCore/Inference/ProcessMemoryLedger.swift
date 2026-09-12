import Foundation

/// Synchronous process admission. One engine owner supplies its complete native
/// charge C, including private preparations and stages BEFORE allocation.
/// Host-only buffers and pending model loads use separate owners.
///
/// Native Admission owns the geometry, allocation permits and lifecycle. While
/// holding its lock, it projects its complete C, obtains this ledger's acceptance,
/// then commits already validated native metadata. Allocation/eval runs off-lock.
/// Rollback recomputes current native C after aliases drain; it never restores an
/// obsolete process reservation. This ledger has no second preparation formula.
///
/// Materialized M is exact, exclusively owned backing already included in the
/// allocator snapshot. Admission subtracts sum(C - M) from current headroom.
/// Native ownership must prove M; process-wide before/after deltas cannot do so.
///
/// Lock order is native Admission -> this ledger -> allocator counters. The
/// reader must capture coherent active/cache counters, initialize its allocator
/// outside this lock, and never perform I/O, GPU work, actor waits or callbacks.
final class ProcessMemoryLedger: @unchecked Sendable {
    struct Owner: Hashable, Sendable {
        fileprivate let id = UUID()
    }

    struct Revision: Equatable, Sendable {
        fileprivate let id = UUID()
    }

    struct Policy: Equatable, Sendable {
        let epoch: UInt64
        /// Already resolved by the existing unified cap/operator policy.
        let capBytes: UInt64
        let reserveBytes: UInt64
    }

    struct Usage: Equatable, Sendable {
        let activeBytes: UInt64
        let cacheBytes: UInt64
        let systemAvailableBytes: UInt64
    }

    struct OwnerState: Equatable, Sendable {
        let owner: Owner
        let revision: Revision
        let chargedBytes: UInt64
        let materializedBytes: UInt64
        let closing: Bool
    }

    struct Snapshot: Equatable, Sendable {
        let policy: Policy
        let usage: Usage
        let ownerCount: Int
        let closingOwnerCount: Int
        let chargedBytes: UInt64
        let materializedBytes: UInt64
        let unmaterializedBytes: UInt64
        let remainingBytes: UInt64
        /// Outstanding commitments in excess of current policy headroom.
        /// Physical usage can independently exceed the cap with no commitments.
        let commitmentDebtBytes: UInt64
    }

    enum Refusal: Error, Equatable {
        case unknownOwner
        case ownerClosing
        case staleRevision
        case stalePolicy
        case invalidCoverage
        case arithmeticOverflow
        case insufficientCapacity
    }

    enum Retirement: Equatable {
        case retired
        case alreadyRetired
        /// Closing is accepted. Native children still own these bytes; their
        /// final explicit charge reduction removes the owner automatically.
        case draining(chargedBytes: UInt64, materializedBytes: UInt64)
    }

    private struct Record {
        var revision = Revision()
        var charged: UInt64 = 0
        var materialized: UInt64 = 0
        var closing = false

        func state(_ owner: Owner) -> OwnerState {
            OwnerState(
                owner: owner, revision: revision, chargedBytes: charged,
                materializedBytes: materialized, closing: closing)
        }
    }

    private let lock = NSLock()
    private let prepareUsage: @Sendable () -> Void
    private let readUsage: @Sendable () -> Usage
    private var policy: Policy
    private var owners: [Owner: Record] = [:]
    private var charged: UInt64 = 0
    private var materialized: UInt64 = 0

    init(
        policy: Policy, prepareUsage: @escaping @Sendable () -> Void = {},
        readUsage: @escaping @Sendable () -> Usage
    ) {
        self.policy = policy
        self.prepareUsage = prepareUsage
        self.readUsage = readUsage
    }

    /// Initialization can create the allocator/device, so it must happen before
    /// a transaction takes this lock. Production supplies a lazy once-only hook;
    /// native owner construction also calls this before Admission can exist.
    func prepareUsageReader() { prepareUsage() }

    func createOwner() -> OwnerState {
        lock.withLock {
            let owner = Owner()
            let record = Record()
            owners[owner] = record
            return record.state(owner)
        }
    }

    func state(for owner: Owner) -> OwnerState? {
        lock.withLock { owners[owner]?.state(owner) }
    }

    func policySnapshot() -> Policy { lock.withLock { policy } }

    @discardableResult
    func updatePolicy(_ newPolicy: Policy) -> Bool {
        lock.withLock {
            guard newPolicy.epoch > policy.epoch else { return false }
            policy = newPolicy
            return true
        }
    }

    /// Accepts the complete native aggregate C, preserving materialized M.
    /// Every disjoint private candidate must already appear in this projection;
    /// two allocations cannot spend the same still-unmaterialized promise.
    /// Only growth requires the current policy and fresh headroom. Reductions
    /// follow native alias retirement and remain available while closing/in debt.
    @discardableResult
    func replaceCharge(
        owner: Owner, expectedRevision: Revision, expectedPolicyEpoch: UInt64,
        chargedBytes: UInt64, additionalSystemReserveBytes: UInt64 = 0
    ) throws -> OwnerState {
        prepareUsageReader()
        return try lock.withLock {
            var record = try currentRecord(owner, expectedRevision)
            guard chargedBytes >= record.materialized else { throw Refusal.invalidCoverage }
            if chargedBytes == record.charged { return record.state(owner) }
            let growing = chargedBytes > record.charged
            if growing {
                guard !record.closing else { throw Refusal.ownerClosing }
                guard expectedPolicyEpoch == policy.epoch else { throw Refusal.stalePolicy }
            }
            record.charged = chargedBytes
            record.revision = Revision()
            try install(
                record, for: owner, checkCapacity: growing,
                additionalSystemReserveBytes: additionalSystemReserveBytes)
            return record.state(owner)
        }
    }

    /// Rechecks an already held allocation permit after asynchronous setup.
    /// Unlike an unchanged charge replacement, this always verifies the current
    /// policy and fresh usage. The optional extra OS reserve is an admission-time
    /// constraint; it does not alter the policy used by ordinary runtime claims.
    func recheckCharge(
        owner: Owner, expectedRevision: Revision, expectedPolicyEpoch: UInt64,
        additionalSystemReserveBytes: UInt64 = 0
    ) throws {
        prepareUsageReader()
        try lock.withLock {
            let record = try currentRecord(owner, expectedRevision)
            guard !record.closing else { throw Refusal.ownerClosing }
            guard expectedPolicyEpoch == policy.epoch else { throw Refusal.stalePolicy }
            guard charged - materialized <= headroom(
                readUsage(), additionalSystemReserveBytes: additionalSystemReserveBytes)
            else { throw Refusal.insufficientCapacity }
        }
    }

    /// Records the complete owner-proven M after evaluated backing exists.
    /// This only converts an existing commitment, including while closing or in
    /// policy debt; it never grants new charge. Explicit withdrawal is separate.
    @discardableResult
    func recordMaterialization(
        owner: Owner, expectedRevision: Revision, materializedBytes: UInt64
    ) throws -> OwnerState {
        try lock.withLock {
            var record = try currentRecord(owner, expectedRevision)
            guard materializedBytes >= record.materialized,
                materializedBytes <= record.charged
            else { throw Refusal.invalidCoverage }
            if materializedBytes == record.materialized { return record.state(owner) }
            record.materialized = materializedBytes
            record.revision = Revision()
            try install(record, for: owner, checkCapacity: false)
            return record.state(owner)
        }
    }

    /// Must run before represented backing can disappear. This can create
    /// conservative debt; capacity, policy and closing cannot refuse it.
    @discardableResult
    func withdrawCoverage(owner: Owner, bytes: UInt64) throws -> OwnerState {
        try lock.withLock {
            guard var record = owners[owner] else { throw Refusal.unknownOwner }
            guard bytes <= record.materialized else { throw Refusal.invalidCoverage }
            if bytes == 0 { return record.state(owner) }
            record.materialized -= bytes
            record.revision = Revision()
            try install(record, for: owner, checkCapacity: false)
            return record.state(owner)
        }
    }

    /// Closes this generation to new charge growth. Previously reserved native
    /// allocations can still complete or retire. Charge and coverage survive
    /// until actual native children drain; neither time nor deinit refunds them.
    @discardableResult
    func retire(_ owner: Owner) -> Retirement {
        lock.withLock {
            guard var record = owners[owner] else { return .alreadyRetired }
            if record.charged == 0 {
                owners.removeValue(forKey: owner)
                return .retired
            }
            if !record.closing {
                record.closing = true
                record.revision = Revision()
                owners[owner] = record
            }
            return .draining(chargedBytes: record.charged, materializedBytes: record.materialized)
        }
    }

    func snapshot() -> Snapshot {
        prepareUsageReader()
        return lock.withLock {
            let usage = readUsage()
            let outstanding = charged - materialized
            let headroom = headroom(usage)
            return Snapshot(
                policy: policy, usage: usage, ownerCount: owners.count,
                closingOwnerCount: owners.values.filter(\.closing).count,
                chargedBytes: charged, materializedBytes: materialized,
                unmaterializedBytes: outstanding,
                remainingBytes: Self.subtract(headroom, outstanding),
                commitmentDebtBytes: Self.subtract(outstanding, headroom))
        }
    }

    private func currentRecord(_ owner: Owner, _ revision: Revision) throws -> Record {
        guard let record = owners[owner] else { throw Refusal.unknownOwner }
        guard record.revision == revision else { throw Refusal.staleRevision }
        return record
    }

    /// Only this method publishes charge/coverage and aggregate changes, after
    /// all checks. Materialization and fresh admission reads share the same lock.
    private func install(
        _ record: Record, for owner: Owner, checkCapacity: Bool,
        additionalSystemReserveBytes: UInt64 = 0
    ) throws {
        guard let previous = owners[owner] else { throw Refusal.unknownOwner }
        let nextCharged = try Self.add(charged - previous.charged, record.charged)
        let nextMaterialized = try Self.add(
            materialized - previous.materialized, record.materialized)
        if checkCapacity && nextCharged - nextMaterialized > headroom(
            readUsage(), additionalSystemReserveBytes: additionalSystemReserveBytes)
        {
            throw Refusal.insufficientCapacity
        }
        charged = nextCharged
        materialized = nextMaterialized
        if record.closing && record.charged == 0 {
            owners.removeValue(forKey: owner)
        } else {
            owners[owner] = record
        }
    }

    private func headroom(
        _ usage: Usage, additionalSystemReserveBytes: UInt64 = 0
    ) -> UInt64 {
        let (used, overflow) = usage.activeBytes.addingReportingOverflow(usage.cacheBytes)
        guard !overflow else { return 0 }
        let capRemainder = Self.subtract(policy.capBytes, used)
        let systemRemainder = Self.subtract(usage.systemAvailableBytes, additionalSystemReserveBytes)
        return Self.subtract(min(capRemainder, systemRemainder), policy.reserveBytes)
    }

    private static func add(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw Refusal.arithmeticOverflow }
        return sum
    }

    private static func subtract(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs > rhs ? lhs - rhs : 0
    }
}
