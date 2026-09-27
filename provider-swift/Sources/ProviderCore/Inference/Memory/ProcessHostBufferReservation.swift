import Foundation

/// A fixed host-buffer allowance over the same ledger as native engine owners.
/// Callers reserve before creating Data/crypto buffers, then explicitly close
/// only after every covered buffer has left its owning scope. No deinit refund
/// can silently run before an asynchronous I/O operation drops its aliases.
final class ProcessHostBufferReservation: @unchecked Sendable {
    private let lock = NSLock()
    private let ledger: ProcessMemoryLedger
    private var state: ProcessMemoryLedger.OwnerState?
    let bytes: UInt64

    init?(ledger: ProcessMemoryLedger, bytes: UInt64) {
        guard bytes > 0 else { return nil }
        self.ledger = ledger
        self.bytes = bytes
        let empty = ledger.createOwner()
        do {
            func claim() throws -> ProcessMemoryLedger.OwnerState {
                try ledger.replaceCharge(
                    owner: empty.owner, expectedRevision: empty.revision,
                    expectedPolicyEpoch: ledger.policySnapshot().epoch, chargedBytes: bytes)
            }
            do { state = try claim() }
            catch ProcessMemoryLedger.Refusal.stalePolicy { state = try claim() }
        } catch {
            _ = ledger.retire(empty.owner)
            return nil
        }
    }

    func closeAfterDroppingBuffers() {
        lock.withLock {
            guard let state else { return }
            do {
                _ = try ledger.replaceCharge(
                    owner: state.owner, expectedRevision: state.revision,
                    expectedPolicyEpoch: 0, chargedBytes: 0)
            } catch {
                preconditionFailure("host-buffer retirement refused: \(error)")
            }
            _ = ledger.retire(state.owner)
            self.state = nil
        }
    }
}

extension GlobalKVCacheBudget {
    nonisolated func reserveHostBuffers(bytes: UInt64) -> ProcessHostBufferReservation? {
        ProcessHostBufferReservation(ledger: processLedger, bytes: bytes)
    }
}
