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

    @Test("legacy records use PID liveness and freshness")
    func legacyPID() {
        #expect(DaemonStateRuntimeTruth.isFreshAndLive(
            state(),
            now: now,
            processAlive: { $0 == 42 },
            readIdentity: { _ in nil }
        ))
        #expect(!DaemonStateRuntimeTruth.isFreshAndLive(
            state(writtenAt: now - 91),
            now: now,
            processAlive: { _ in true },
            readIdentity: { _ in nil }
        ))
        #expect(!DaemonStateRuntimeTruth.isFreshAndLive(
            state(),
            now: now,
            processAlive: { _ in false },
            readIdentity: { _ in nil }
        ))
    }

    @Test("kernel start identity prevents PID reuse and malformed records")
    func processIdentity() {
        let recorded = ProcessIdentity(pid: 42, startTimeMicros: 100)
        #expect(DaemonStateRuntimeTruth.belongsToLiveProcess(
            state(identity: recorded),
            processAlive: { _ in false },
            readIdentity: { _ in recorded }
        ))
        #expect(!DaemonStateRuntimeTruth.belongsToLiveProcess(
            state(identity: recorded),
            processAlive: { _ in true },
            readIdentity: { _ in ProcessIdentity(pid: 42, startTimeMicros: 200) }
        ))
        #expect(!DaemonStateRuntimeTruth.belongsToLiveProcess(
            state(identity: ProcessIdentity(pid: 99, startTimeMicros: 100)),
            processAlive: { _ in true },
            readIdentity: { _ in ProcessIdentity(pid: 99, startTimeMicros: 100) }
        ))
    }
}
