import Foundation
import MLXLMCommon

/// Synchronous native owner over the process ledger. The native Admission lock
/// precedes this revision lock. The only work below it is scalar accounting and
/// a bounded allocator snapshot; allocation, eval and retirement fences stay native.
final class EngineProcessMemoryOwner: CBv2ProcessMemoryOwner, @unchecked Sendable {
    private let lock = NSLock()
    private let ledger: ProcessMemoryLedger
    private var state: ProcessMemoryLedger.OwnerState

    init(ledger: ProcessMemoryLedger) {
        // Construction precedes native Admission and therefore every native
        // lock. First allocator/device access cannot occur in replaceCharge.
        ledger.prepareUsageReader()
        self.ledger = ledger
        state = ledger.createOwner()
    }

    func replaceCharge(_ bytes: UInt64) throws {
        try lock.withLock {
            // An actor policy push can race this native call. Retry only that
            // race once; capacity, ownership and closure failures remain failures.
            do {
                try replace(bytes)
            } catch ProcessMemoryLedger.Refusal.stalePolicy {
                try replace(bytes)
            }
        }
    }

    func recordMaterialization(_ bytes: UInt64) throws {
        try lock.withLock {
            state = try ledger.recordMaterialization(
                owner: state.owner, expectedRevision: state.revision,
                materializedBytes: bytes)
        }
    }

    func withdrawCoverage(_ bytes: UInt64) throws {
        try lock.withLock {
            state = try ledger.withdrawCoverage(owner: state.owner, bytes: bytes)
        }
    }

    func retire() {
        lock.withLock {
            _ = ledger.retire(state.owner)
            if let remaining = ledger.state(for: state.owner) { state = remaining }
        }
    }

    func snapshot() -> ProcessMemoryLedger.OwnerState? {
        lock.withLock { ledger.state(for: state.owner) }
    }

    private func replace(_ bytes: UInt64) throws {
        state = try ledger.replaceCharge(
            owner: state.owner, expectedRevision: state.revision,
            expectedPolicyEpoch: ledger.policySnapshot().epoch, chargedBytes: bytes)
    }
}
