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
}
