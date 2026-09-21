import Foundation

extension StandaloneServer {
    public func drainAndStop(timeoutSeconds: Int = 600) async -> Bool {
        lifecycleDraining = true
        responseTracker.setAccepting(false)
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
        while responseTracker.activeCount > 0 || slotReservations.values.contains(where: { $0 > 0 }) {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        await stop()
        return true
    }
}
