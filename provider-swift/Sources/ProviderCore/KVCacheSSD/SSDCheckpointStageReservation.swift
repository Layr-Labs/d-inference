import Foundation

/// A staging lease outlives the store ticket if adoption still owns arrays.
/// Its final callback refunds the process ledger exactly once.
final class SSDCheckpointStageReservation: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int
    private var released = false
    private var retirementRequested = false
    private var ioFinished: Bool
    private let key: String
    private let budget: GlobalKVCacheBudget?
    private let activity: SSDCheckpointActivity
    private let stats: SSDHybridCheckpointStatsBox
    private let refund = SSDCheckpointActivity()

    init(key: String, bytes: Int, budget: GlobalKVCacheBudget?,
         activity: SSDCheckpointActivity, stats: SSDHybridCheckpointStatsBox,
         holdsIO: Bool = false) {
        self.key = key
        self.bytes = bytes
        self.budget = budget
        self.activity = activity
        self.stats = stats
        self.ioFinished = !holdsIO
        refund.begin()
        stats.update {
            $0.stagedBytesInUse += bytes
            $0.peakStagingReservationBytes = max($0.peakStagingReservationBytes, $0.stagedBytesInUse)
        }
    }

    func resize(to next: Int) async -> Bool {
        guard next > 0, !lock.withLock({ retirementRequested }) else { return false }
        if let budget, !(await budget.resizeReservationBytes(requestID: key, bytes: UInt64(next))) { return false }
        let accepted = lock.withLock { () -> Bool in
            guard !released else { return false }
            let previous = bytes
            bytes = next
            stats.update {
                $0.stagedBytesInUse += next - previous
                $0.peakStagingReservationBytes = max($0.peakStagingReservationBytes, $0.stagedBytesInUse)
            }
            return !retirementRequested
        }
        if !accepted { release() }
        return accepted
    }

    func release() {
        let count = lock.withLock { () -> Int? in
            guard !released else { return nil }
            retirementRequested = true
            guard ioFinished else { return nil }
            activity.begin()
            released = true
            return bytes
        }
        guard let count else { return }
        Task {
            if let budget { await budget.release(requestID: key) }
            stats.update { $0.stagedBytesInUse -= count }
            refund.end()
            activity.end()
        }
    }

    /// Native importer cancellation may request release while provider Data is
    /// still on the read stack. Only the caller outside that helper can drain it.
    func finishIO() {
        let shouldRelease = lock.withLock {
            ioFinished = true
            return retirementRequested
        }
        if shouldRelease { release() }
    }

    func waitForRefund() async { await refund.waitUntilDrained() }
}
