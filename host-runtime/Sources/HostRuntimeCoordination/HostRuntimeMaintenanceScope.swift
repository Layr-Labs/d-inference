import Darwin
import Foundation

extension HostRuntimeAuthority {
    public static let maintenanceFileName = "maintenance.json"

    /// The exact protected intent is required before EX acquisition. This is
    /// exclusively for root recovery, never ordinary sandbox or inference use.
    public func recoverRootMaintenance(_ intent: HostRuntimeMaintenanceIntent) throws -> HostRuntimeMaintenanceScope {
        try requireMaintenanceOperator()
        _ = try intent.encoded()
        guard let lease = try acquire(exclusive: true, allowMissing: false, recovering: intent) else {
            throw HostRuntimeOwnershipError.authorityMissing
        }
        let scope = try HostRuntimeMaintenanceScope(lease: lease, intent: intent)
        try scope.validate()
        return scope
    }

    func requireMaintenanceOperator() throws {
        // The package-only test policy can act only for its own Unix identity;
        // it cannot impersonate root against the real authority directory.
        if testing, getuid() == ownerUID, geteuid() == ownerUID { return }
        guard !testing, getuid() == 0, geteuid() == 0, getegid() == 0 else {
            throw HostRuntimeOwnershipError.rootMaintenanceRequired
        }
    }

    var maintenanceOwnerGID: gid_t { testing ? (testGroupID ?? getegid()) : 0 }

    func checkMaintenance(parent: Int32, recovering intent: HostRuntimeMaintenanceIntent?) throws {
        if let intent {
            try requireMaintenanceOperator()
            try HostRuntimeMaintenanceStore.requireMatching(parent: parent, ownerUID: ownerUID,
                ownerGID: maintenanceOwnerGID, expected: intent.encoded())
        } else {
            try HostRuntimeMaintenanceStore.requireAbsent(parent: parent)
        }
    }
}

extension HostRuntimeLease {
    /// Publish the durable fence before beginning offline IO. Releasing this
    /// scope or crashing never clears it. The existing EX inode is unchanged.
    public func beginRootMaintenance(_ intent: HostRuntimeMaintenanceIntent) throws -> HostRuntimeMaintenanceScope {
        try authority.requireMaintenanceOperator()
        try validateExclusive()
        let store = try HostRuntimeMaintenanceStore(authority: authority)
        try store.publish(intent.encoded())
        let scope = try HostRuntimeMaintenanceScope(lease: self, intent: intent)
        try scope.validate()
        return scope
    }
}

/// Retains EX through root recovery. The operator must independently observe
/// cleanup and durably record its evidence before calling finishAfterVerifiedCleanup.
/// This library cannot infer device detach or stopped-state proof from an intent.
public final class HostRuntimeMaintenanceScope: @unchecked Sendable {
    public let runtimeLease: HostRuntimeLease
    public let intent: HostRuntimeMaintenanceIntent
    private let lock = NSLock()
    private let store: HostRuntimeMaintenanceStore
    private let identity: stat
    private var finished = false

    init(lease: HostRuntimeLease, intent: HostRuntimeMaintenanceIntent) throws {
        runtimeLease = lease; self.intent = intent
        store = try HostRuntimeMaintenanceStore(authority: lease.authority)
        identity = try store.pinMatchingRecord(intent.encoded())
    }

    public func validate() throws {
        try lock.withLock {
            guard !finished else { throw HostRuntimeOwnershipError.maintenanceFinished }
            try validateCurrent()
        }
    }

    public func finishAfterVerifiedCleanup() throws {
        try lock.withLock {
            guard !finished else { throw HostRuntimeOwnershipError.maintenanceFinished }
            try validateCurrent()
            try store.removeMatching(intent.encoded(), identity: identity)
            finished = true
            try runtimeLease.validateExclusive()
        }
    }

    private func validateCurrent() throws {
        try runtimeLease.authority.requireMaintenanceOperator()
        try runtimeLease.validateExclusive()
        try store.requireMatching(intent.encoded(), identity: identity)
    }
}
