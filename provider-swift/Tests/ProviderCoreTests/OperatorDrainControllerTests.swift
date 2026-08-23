import Foundation
import Testing
@testable import ProviderCore

private actor DrainEventRecorder {
    private var values: [String] = []
    func record(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}

@Suite("Operator drain controller")
struct OperatorDrainControllerTests {
    @Test("clean drain closes the coordinator after work reaches zero")
    func cleanDrain() async {
        let recorder = DrainEventRecorder()
        let controller = OperatorDrainController(
            dependencies: .init(
                begin: { await recorder.record("begin"); return true },
                waitForDrain: { _ in await recorder.record("wait"); return true },
                resume: { await recorder.record("resume") },
                finishShutdown: { await recorder.record("shutdown") }
            ),
            timeout: .seconds(1)
        )

        #expect(await controller.run() == .drained)
        #expect(await recorder.snapshot() == ["begin", "wait", "shutdown"])
    }

    @Test("timeout reopens admission and never shuts down")
    func timeoutResumes() async {
        let recorder = DrainEventRecorder()
        let controller = OperatorDrainController(
            dependencies: .init(
                begin: { await recorder.record("begin"); return true },
                waitForDrain: { _ in await recorder.record("wait"); return false },
                resume: { await recorder.record("resume") },
                finishShutdown: { await recorder.record("shutdown") }
            ),
            timeout: .milliseconds(1)
        )

        #expect(await controller.run() == .timedOut)
        #expect(await recorder.snapshot() == ["begin", "wait", "resume"])
    }

    @Test("busy lifecycle does not wait, resume, or shut down")
    func busyDoesNothing() async {
        let recorder = DrainEventRecorder()
        let controller = OperatorDrainController(
            dependencies: .init(
                begin: { await recorder.record("begin"); return false },
                waitForDrain: { _ in await recorder.record("wait"); return true },
                resume: { await recorder.record("resume") },
                finishShutdown: { await recorder.record("shutdown") }
            ),
            timeout: .seconds(1)
        )

        #expect(await controller.run() == .busy)
        #expect(await recorder.snapshot() == ["begin"])
    }
}
