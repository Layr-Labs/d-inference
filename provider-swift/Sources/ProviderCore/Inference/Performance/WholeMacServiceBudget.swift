import Foundation

/// One normalized service allowance shared by every resident model. A profile
/// of width N consumes 1/N per request; three models never get three budgets.
/// Leases have no timeout: cancellation releases only after engine retirement.
final class WholeMacServiceBudget: @unchecked Sendable {
    private let lock = NSLock()
    private struct Charge {
        let fraction: Double
        let reservationID: String?
        let lifetime: ServiceReservationLifetime?
    }
    struct Snapshot: Sendable, Equatable {
        let usedFraction: Double
        let reservations: [WholeMacServiceReservation]
    }
    private var charges: [String: Charge] = [:]
    private var observerID: UUID?
    private var observer: AsyncStream<Void>.Continuation?

    func acquire(ownerID: String, concurrency: Int, serviceReservationID: String? = nil,
        serviceReservation: ServiceReservationLifetime? = nil) -> Bool {
        // Correlation is optional. Malformed input gets no overlap credit; it
        // never bypasses the actual provider-side service allowance.
        let reservationID = serviceReservation?.id
            ?? ServiceReservationLifetime.normalizedID(serviceReservationID)
        let (acquired, notification) = lock.withLock { () -> (Bool, AsyncStream<Void>.Continuation?) in
            guard charges[ownerID] == nil, concurrency > 0 else { return (false, nil) }
            if let reservationID, charges.values.contains(where: { $0.reservationID == reservationID }) {
                return (false, nil)
            }
            let charge = 1 / Double(concurrency)
            guard charges.values.reduce(0, { $0 + $1.fraction }) + charge <= 1 + 1e-12 else { return (false, nil) }
            guard serviceReservation?.acquireLease() ?? true else { return (false, nil) }
            charges[ownerID] = Charge(fraction: charge, reservationID: reservationID,
                lifetime: serviceReservation)
            return (true, observer)
        }
        notification?.yield()
        return acquired
    }

    func release(ownerID: String) {
        let (charge, notification) = lock.withLock { () -> (Charge?, AsyncStream<Void>.Continuation?) in
            guard let charge = charges.removeValue(forKey: ownerID) else { return (nil, nil) }
            return (charge, observer)
        }
        charge?.lifetime?.releaseLease()
        notification?.yield()
    }

    /// One provider-loop observer sees changes from all shared model bridges.
    /// Coalesce bursts before the actor hop; the consumer reads current usage,
    /// never a possibly reordered fraction captured by the notifying thread.
    func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuation.onTermination = { [weak self] _ in self?.removeObserver(id) }
        let previous = lock.withLock {
            let previous = observer
            observerID = id
            observer = continuation
            return previous
        }
        previous?.finish()
        continuation.yield() // include ownership acquired before registration
        return stream
    }

    private func removeObserver(_ id: UUID) {
        lock.withLock {
            guard observerID == id else { return }
            observerID = nil
            observer = nil
        }
    }

    /// Total and correlations must be from one lock epoch. In particular, a
    /// heartbeat cannot pair a pre-retirement total with post-retirement IDs.
    func snapshot() -> Snapshot {
        lock.withLock {
            let reservations = charges.values.compactMap { charge in
                charge.reservationID.map { WholeMacServiceReservation(id: $0, usedFraction: charge.fraction) }
            }.sorted { $0.id < $1.id }
            return Snapshot(usedFraction: charges.values.reduce(0, { $0 + $1.fraction }),
                reservations: Array(reservations.prefix(64)))
        }
    }

    var usedFraction: Double { lock.withLock { charges.values.reduce(0, { $0 + $1.fraction }) } }
    var count: Int { lock.withLock { charges.count } }
}
