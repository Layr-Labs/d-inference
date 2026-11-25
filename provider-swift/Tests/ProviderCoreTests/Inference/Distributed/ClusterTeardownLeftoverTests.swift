import Foundation
import Testing
@testable import ProviderCore

/// After a stop, a run's device journal and bootstrap directory can be left behind when its owner ended without closing
/// them (the other Mac dropped the link before the release was proven). `darkbloom restart` then waited its whole
/// teardown allowance on "a device record from a run is still open" and refused, while `darkbloom start` cleared the
/// same journal at once (a DevNet pair, 2026-11-24). The teardown check now runs that recovery once and checks again.
/// The recovery itself (`ClusterService.recoverDeviceJournal`, `cluster recover`'s) clears nothing while the owner or a
/// process of its epoch still runs: here it is a stand-in that clears or keeps the leftovers.
@Suite("A run's leftover device journal doesn't hold a restart's teardown check")
struct ClusterTeardownLeftoverTests {
    final class Sweeps: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [[String]]
        private(set) var recoveries = 0
        init(_ results: [[String]]) { self.results = results }
        func sweep() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return results.count > 1 ? results.removeFirst() : results.first ?? []
        }
        func recover() { lock.lock(); recoveries += 1; lock.unlock() }
    }

    static let journal = "native ownership journal is still present"
    static let bootstrap = "stale bootstrap directory remains"

    @Test("a journal and bootstrap directory whose owner is gone are recovered, and the check passes")
    func leftoverOfAnEndedOwnerIsRecovered() {
        let sweeps = Sweeps([[Self.journal, Self.bootstrap], []])
        let line = ClusterService.teardownLines(mac: "This Mac", sweep: sweeps.sweep, recoverLeftover: sweeps.recover)[0]
        #expect(sweeps.recoveries == 1)
        #expect(!line.contains("device record") && !line.contains("files from a run's start"), "\(line)")
    }

    @Test("a journal the recovery keeps (its owner still runs) still holds the check")
    func liveOwnersJournalStillHoldsTheCheck() {
        let sweeps = Sweeps([[Self.journal, "cluster worker owner pid 4242 is running"]])
        let line = ClusterService.teardownLines(mac: "This Mac", sweep: sweeps.sweep, recoverLeftover: sweeps.recover)[0]
        #expect(sweeps.recoveries == 1)
        #expect(line.hasPrefix("This Mac: still running: ") && line.contains("a device record from a run is still open")
                && line.contains("a cluster process"), "\(line)")
    }

    @Test("nothing a run left behind: no recovery is tried")
    func otherLeftoversTryNoRecovery() {
        let sweeps = Sweeps([["wired memory is above the idle baseline"]])
        let line = ClusterService.teardownLines(mac: "This Mac", sweep: sweeps.sweep, recoverLeftover: sweeps.recover)[0]
        #expect(sweeps.recoveries == 0)
        #expect(line.contains("memory a model held is not released yet"), "\(line)")
    }
}
