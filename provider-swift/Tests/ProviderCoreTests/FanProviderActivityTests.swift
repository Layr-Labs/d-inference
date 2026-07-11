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
            readIdentity: { _ in replacement }
        ))
    }

    @Test("legacy and future-dated state fail closed")
    func malformedStateFailsClosed() {
        let state = makeState(
            writtenAt: 100,
            inferenceActive: true,
            identity: nil
        )
        #expect(!FanProviderActivityReader.inferenceActive(
            state: state,
            now: 101,
            readIdentity: { _ in nil }
        ))

        #expect(!FanProviderActivityReader.inferenceActive(
            state: makeState(
                writtenAt: 1_000,
                inferenceActive: true,
                identity: identity
            ),
            now: 101,
            readIdentity: { _ in identity }
        ))
    }

    @Test("request tracker publishes exact idempotent transitions")
    func trackerTransitions() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "inference-activity-\(UUID().uuidString).json"
            )
        defer { try? FileManager.default.removeItem(at: path) }
        let tracker = InferenceActivityTracker(path: path)

        tracker.begin("request-a")
        tracker.begin("request-a")
        tracker.begin("request-b")
        #expect(
            InferenceActivityFile.read(from: path)?
                .activeRequestCount == 2
        )

        tracker.end("request-a")
        tracker.end("request-a")
        #expect(
            InferenceActivityFile.read(from: path)?
                .activeRequestCount == 1
        )

        tracker.end("request-b")
        #expect(
            InferenceActivityFile.read(from: path)?
                .activeRequestCount == 0
        )
    }

    private func makeState(
        writtenAt: Double,
        inferenceActive: Bool,
        identity: ProcessIdentity?
    ) -> InferenceActivityState {
        InferenceActivityState(
            pid: 123,
            processIdentity: identity,
            writtenAt: writtenAt,
            activeRequestCount: inferenceActive ? 1 : 0
        )
    }
}
