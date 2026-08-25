import Foundation
import Testing
@testable import ProviderCoreFoundation

@Suite("Daemon state runtime truth")
struct DaemonStateRuntimeTruthTests {
    private let now = 1_800_000_000.0

    private func state(
        writtenAt: Double? = nil,
        identity: ProcessIdentity? = nil
    ) -> DaemonState {
        DaemonState(
            pid: 42,
            processIdentity: identity,
            version: "test",
            writtenAt: writtenAt ?? now - 1,
            startedAt: now - 60
        )
    }

    @Test("legacy records without kernel identity fail closed")
    func legacyPID() {
        let liveIdentity = ProcessIdentity(pid: 42, startTimeMicros: 100)
        #expect(!DaemonStateRuntimeTruth.belongsToLiveProcess(
            state(),
            readIdentity: { _ in liveIdentity }
        ))
        #expect(!DaemonStateRuntimeTruth.isFreshAndLive(
            state(),
            now: now,
            readIdentity: { _ in liveIdentity }
        ))
    }

    @Test("kernel start identity prevents PID reuse, staleness, and malformed records")
    func processIdentity() {
        let recorded = ProcessIdentity(pid: 42, startTimeMicros: 100)
        #expect(DaemonStateRuntimeTruth.belongsToLiveProcess(
            state(identity: recorded),
            readIdentity: { _ in recorded }
        ))
        #expect(DaemonStateRuntimeTruth.isFreshAndLive(
            state(identity: recorded),
            now: now,
            readIdentity: { _ in recorded }
        ))
        #expect(!DaemonStateRuntimeTruth.isFreshAndLive(
            state(writtenAt: now - 91, identity: recorded),
            now: now,
            readIdentity: { _ in recorded }
        ))
        #expect(!DaemonStateRuntimeTruth.belongsToLiveProcess(
            state(identity: recorded),
            readIdentity: { _ in ProcessIdentity(pid: 42, startTimeMicros: 200) }
        ))
        #expect(!DaemonStateRuntimeTruth.belongsToLiveProcess(
            state(identity: ProcessIdentity(pid: 99, startTimeMicros: 100)),
            readIdentity: { _ in ProcessIdentity(pid: 99, startTimeMicros: 100) }
        ))
    }

    @Test("trust evidence expires independently of fresh daemon writes")
    func trustFreshness() {
        let fresh = DaemonState.Trust(
            trustLevel: "hardware",
            status: "online",
            reason: "challenge verified",
            receivedAt: now - DaemonState.Trust.maxFreshAge
        )
        #expect(fresh.isFresh(now: now))

        let stale = DaemonState.Trust(
            trustLevel: "hardware",
            status: "online",
            reason: "old challenge",
            receivedAt: now - DaemonState.Trust.maxFreshAge - 0.001
        )
        #expect(!stale.isFresh(now: now))

        let future = DaemonState.Trust(
            trustLevel: "hardware",
            status: "online",
            reason: "malformed timestamp",
            receivedAt: now + 1
        )
        #expect(!future.isFresh(now: now))
    }
}
