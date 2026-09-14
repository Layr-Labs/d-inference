import Foundation

/// Static fleet grants exclude an unpublished replacement's assistant/KV and
/// any original target retained after concurrent unload. Actual allocation is
/// guarded separately by the process ledger and pending-load lease.
struct MTPStagingReservations {
    private struct Entry {
        let target: ObjectIdentifier
        let targetBytes: UInt64
        let replacementBytes: UInt64
    }
    private var entries: [ProcessMemoryLedger.Owner: Entry] = [:]
    private var preparingTargets: [UUID: (target: ObjectIdentifier, bytes: UInt64)] = [:]
    private(set) var generation: UInt64 = 0

    var hasRetainedTargets: Bool { !entries.isEmpty || !preparingTargets.isEmpty }

    func retains(_ target: ObjectIdentifier) -> Bool {
        entries.values.contains { $0.target == target }
            || preparingTargets.values.contains { $0.target == target }
    }

    /// Protect the strong target reference before the first preparation await,
    /// including catalog lookup and pending-load admission before a lease exists.
    mutating func retainPreparingTarget(_ target: ObjectIdentifier, bytes: UInt64) -> UUID {
        let id = UUID()
        preparingTargets[id] = (target, bytes)
        generation &+= 1
        return id
    }

    mutating func releasePreparingTarget(_ id: UUID) {
        if preparingTargets.removeValue(forKey: id) != nil { generation &+= 1 }
    }

    func extraBytes(residentTargets: Set<ObjectIdentifier>) -> UInt64 {
        var total: UInt64 = 0
        var countedTargets = residentTargets
        for entry in entries.values {
            total = Self.adding(total, entry.replacementBytes)
            if countedTargets.insert(entry.target).inserted {
                total = Self.adding(total, entry.targetBytes)
            }
        }
        for entry in preparingTargets.values where countedTargets.insert(entry.target).inserted {
            total = Self.adding(total, entry.bytes)
        }
        return total
    }

    mutating func reserve(_ lease: PendingModelLoadLease,
                         target: ObjectIdentifier, targetBytes: UInt64,
                         assistantBytes: UInt64, kvBytes: UInt64) {
        entries[lease.owner] = Entry(target: target, targetBytes: targetBytes,
            replacementBytes: Self.adding(assistantBytes, kvBytes))
        generation &+= 1
    }

    mutating func release(_ lease: PendingModelLoadLease) {
        if entries.removeValue(forKey: lease.owner) != nil { generation &+= 1 }
    }

    static func adding(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}
