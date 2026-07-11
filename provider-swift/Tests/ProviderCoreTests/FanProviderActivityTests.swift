import Foundation
import Testing

@testable import ProviderCore

@Suite("Fan provider activity")
struct FanProviderActivityTests {
    private let identity = ProcessIdentity(
        pid: 123,
        startTimeMicros: 456
    )

    @Test("fresh active state from the same live process is trusted")
    func activeState() {
        let state = makeState(
            writtenAt: 100,
            inferenceActive: true,
            identity: identity
        )
        #expect(FanProviderActivityReader.inferenceActive(
            state: state,
            now: 110,
            processAlive: { _ in true },
            readIdentity: { _ in identity }
        ))
    }

    @Test("idle or stale state never activates cooling")
    func idleAndStaleState() {
        #expect(!FanProviderActivityReader.inferenceActive(
            state: makeState(
                writtenAt: 100,
                inferenceActive: false,
                identity: identity
            ),
            now: 101,
            readIdentity: { _ in identity }
        ))
        #expect(!FanProviderActivityReader.inferenceActive(
            state: makeState(
                writtenAt: 100,
                inferenceActive: true,
                identity: identity
            ),
            now: 116,
            readIdentity: { _ in identity }
        ))
    }

    @Test("PID reuse cannot keep fans boosted")
    func rejectsReusedPID() {
        let replacement = ProcessIdentity(
            pid: identity.pid,
            startTimeMicros: identity.startTimeMicros + 1
        )
        #expect(!FanProviderActivityReader.inferenceActive(
            state: makeState(
                writtenAt: 100,
                inferenceActive: true,
                identity: identity
            ),
            now: 101,
            processAlive: { _ in true },
            readIdentity: { _ in replacement }
        ))
    }

    @Test("legacy state requires a live PID")
    func legacyStateChecksPID() {
        let state = makeState(
            writtenAt: 100,
            inferenceActive: true,
            identity: nil
        )
        #expect(FanProviderActivityReader.inferenceActive(
            state: state,
            now: 101,
            processAlive: { $0 == 123 },
            readIdentity: { _ in nil }
        ))
        #expect(!FanProviderActivityReader.inferenceActive(
            state: state,
            now: 101,
            processAlive: { _ in false },
            readIdentity: { _ in nil }
        ))
    }

    private func makeState(
        writtenAt: Double,
        inferenceActive: Bool,
        identity: ProcessIdentity?
    ) -> DaemonState {
        DaemonState(
            pid: 123,
            processIdentity: identity,
            version: "test",
            writtenAt: writtenAt,
            startedAt: 1,
            inferenceActive: inferenceActive
        )
    }
}
