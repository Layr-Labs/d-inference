import Foundation
import DarkbloomClusterProcess

/// Production caller supplies actual authenticated endpoint ACK observations.
/// The CPU fixture labels its explicit simulated lease-release closure separately.
@MainActor final class CancellationOwnedPair {
    let pair: ClusterWorkerPair
    let endpoints: [any ClusterWorkerEndpoint]
    let leaseReleaseObserved: () -> [Bool]
    init(pair: ClusterWorkerPair, endpoints: [any ClusterWorkerEndpoint], leaseReleaseObserved: @escaping () -> [Bool]) {
        self.pair = pair; self.endpoints = endpoints; self.leaseReleaseObserved = leaseReleaseObserved
    }
    func close(lifetimeDeadline: UInt64) async -> (native: [Bool], leases: [Bool], nativeAt: UInt64, leasesAt: UInt64) {
        await pair.shutdown() // Waits for actual native cleanup, never a timeout substitute.
        let native = endpoints.map(\.nativeCleanupObserved), nativeAt = DispatchTime.now().uptimeNanoseconds
        let deadline = min(lifetimeDeadline + 2_000_000_000, nativeAt + 2_000_000_000)
        var leases = leaseReleaseObserved()
        while (leases.count != 2 || !leases.allSatisfy({ $0 })), DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000); leases = leaseReleaseObserved()
        }
        return (native, leases, nativeAt, DispatchTime.now().uptimeNanoseconds)
    }
}
