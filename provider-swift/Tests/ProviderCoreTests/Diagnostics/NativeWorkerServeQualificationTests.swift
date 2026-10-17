import Foundation
import Testing
@testable import ProviderAppAttest
@testable import ProviderCore

@Suite struct NativeWorkerServeQualificationTests {
    @Test func separateOptInsAreRequired() throws {
        let key = NativeWorkerServeQualification.environmentKey
        #expect(try NativeWorkerServeQualification.selected(environment: [:]) == nil)
        #expect(throws: (any Error).self) {
            try NativeWorkerServeQualification.selected(environment: [key: "1"])
        }
        #expect(throws: (any Error).self) {
            try NativeWorkerServeQualification.selected(environment: [key: "1", NativeServeQualification.environmentKey: "1"])
        }
        #expect(try NativeWorkerServeQualification.selected(environment: [key: "1",
            NativeServeQualification.environmentKey: "1", AppAttestWorkerSelection.qualificationEnvironment: "1"]) != nil)
    }

    @Test func liveWorkerCannotBecomeConfirmedRetirement() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        let observation = NativeWorkerServeQualification()
        observation.recordReply(action: "ready", result: "ok", workerPID: child.processIdentifier)
        observation.recordReply(action: "assertion", result: "ok", workerPID: nil)
        observation.recordArmed()
        observation.recordReply(action: "assertion", result: "operation_timeout", workerPID: nil)
        #expect(observation.snapshot.failed)
        #expect(observation.snapshot.retiredAtNS == nil)
        #expect(observation.snapshot.successfulAssertions == 1)
    }

    @Test func observationsAreBoundedAndCannotAttributeTheParentAsWorker() {
        let observation = NativeWorkerServeQualification()
        observation.recordReply(action: "ready", result: "ok", workerPID: ProcessInfo.processInfo.processIdentifier)
        #expect(observation.snapshot.failed)
        #expect(observation.snapshot.initialWorker == nil)
    }

    @Test func realChildRetirementAndReplacementAreSeparateIdentities() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        let observation = NativeWorkerServeQualification()
        observation.recordReply(action: "ready", result: "ok", workerPID: child.processIdentifier)
        let identity = try #require(observation.snapshot.initialWorker)
        let generation = UUID()
        observation.recordArmed()
        observation.observe(.init(processID: child.processIdentifier, workerGeneration: generation,
            sequence: 5, phase: .submitted))
        observation.observe(.init(processID: child.processIdentifier, workerGeneration: generation,
            sequence: 5, phase: .callbackDiscarded))
        child.terminate()
        child.waitUntilExit()
        observation.recordReply(action: "assertion", result: "operation_timeout", workerPID: nil)
        #expect(observation.snapshot.retiredAtNS != nil)
        #expect(!observation.snapshot.failed)
        #expect(observation.snapshot.initialWorker == identity)
        #expect(observation.snapshot.events.count == 2)
        observation.observe(.init(processID: identity.pid, workerGeneration: generation,
            sequence: 5, phase: .callbackDiscarded))
        #expect(observation.snapshot.events.count == 2)
        #expect(observation.snapshot.failed)
    }
}
