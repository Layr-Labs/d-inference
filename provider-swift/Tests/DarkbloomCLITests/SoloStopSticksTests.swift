import Foundation
import Testing

@testable import ProviderCore
@testable import darkbloom

/// solo-steps-failed.md §5.8: once single-Mac serving is stopped for the pair (the offer, `stop --solo`, or a step aside),
/// a login, a watchdog tick and an update don't bring it back over a started pair, and the pair keeps its serving lock.
@Suite("A stop of single-Mac serving sticks through a login, a watchdog tick and an update")
struct SoloStopSticksTests {
    /// After `stop --solo`: the job is disabled and unloaded (`LaunchAgent.stop`), so `singleMacSetUp` is false.
    let stoppedJobLoaded = false

    @Test("a watchdog tick never revives it: unloaded is not managed, and a loaded dead job beside a started pair isn't either")
    func watchdogTick() {
        #expect(WatchdogPolicy.decide(autoRestartEnabled: true, providerLoaded: stoppedJobLoaded, providerRunning: false,
                                      downSince: 0, now: 10_000) == .notManaged)
        // A job revived some other way and dead again, while the pair keeps the lock (WatchdogCommand's `pairOwnsServing`).
        let pairOwnsServing = true
        #expect(WatchdogPolicy.decide(autoRestartEnabled: true, providerLoaded: true && !pairOwnsServing, providerRunning: false,
                                      downSince: 0, now: 10_000) == .notManaged)
    }

    @Test("an update restarts the pair, never single-Mac serving, while the pair is started")
    func update() {
        #expect(!Update.soloJobBesidePair(soloJobLoaded: stoppedJobLoaded, pairServes: true))
        #expect(Update.soloJobBesidePair(soloJobLoaded: true, pairServes: true), "a job left loaded: the pair restarts, the job stays off")
    }

    @Test("a login, or 0.10.8's updater, that starts it anyway: it steps aside for the started pair, which keeps its slot")
    func loginOrOldUpdater() {
        // Nobody chose it since the pair was started (the consented stop and `stop --solo` clear any choice).
        #expect(ClusterSoloChoice.stepsAside(wantedKey: "cluster:84377e741989", chosenAt: nil))
        // The pair's part waits while it holds the lock, and its blocked ends never cost the pair its Darkbloom approval.
        #expect(ClusterApprovalCheck.memberQuickEnds(after: 2, ranSeconds: 3, lastError: "closed", heldBack: true) == 2)
    }

    @Test("an orphaned pair part is never reported as single-Mac serving")
    func orphanedPart() {
        let orphan = ProviderInstanceHolder.Holder(pid: 64399, kind: .singleMac) // `start --local`, adopted by launchd
        #expect(ProviderInstanceHolder.singleMac(orphan, recordedPartPID: 64399) == nil)
        #expect(ProviderInstanceHolder.singleMac(orphan, recordedPartPID: nil) == orphan)
        #expect(ProviderInstanceHolder.singleMac(.init(pid: 1, kind: .pairPart), recordedPartPID: nil) == nil)
    }
}
