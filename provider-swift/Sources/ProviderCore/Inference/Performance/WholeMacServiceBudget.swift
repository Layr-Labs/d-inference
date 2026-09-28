import Foundation

/// One normalized service allowance shared by every resident model. A profile
/// of width N consumes 1/N per request; three models never get three budgets.
/// Leases have no timeout: cancellation releases only after engine retirement.
final class WholeMacServiceBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var charges: [String: Double] = [:]

    func acquire(ownerID: String, concurrency: Int) -> Bool {
        lock.withLock {
            guard charges[ownerID] == nil, concurrency > 0 else { return false }
            let charge = 1 / Double(concurrency)
            guard charges.values.reduce(0, +) + charge <= 1 + 1e-12 else { return false }
            charges[ownerID] = charge
            return true
        }
    }

    func release(ownerID: String) {
        _ = lock.withLock { charges.removeValue(forKey: ownerID) }
    }

    var usedFraction: Double { lock.withLock { charges.values.reduce(0, +) } }
    var count: Int { lock.withLock { charges.count } }
}
