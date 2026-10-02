import Foundation
import Testing
@testable import ProviderCore

@Suite("Autopilot revision and publication ownership")
struct ModelAutopilotOperationOwnershipTests {
    @Test func revisionDrainExcludesNewAutopilotOperation() async throws {
        let loop = try await autopilotTestLoop(enabled: true)
        await loop.holdRevisionDrainForAutopilotTesting()
        let recorder = AutopilotRecorder()
        await loop.handleModelAutopilot(.init(commandId: "during-revision", loadModelId: "uncached",
            expiresAtMs: Int64(Date().timeIntervalSince1970 * 1_000) + 60_000,
            sessionId: "session", revision: "test"), send: SendHandle(recorder.append))
        #expect(recorder.statuses.last?.error == "provider_busy")
        #expect(await loop.autopilotCommand == nil)
    }

    @Test func acceptedOperationDefersPublicationAndRevisionReconciliation() async throws {
        let loop = try await autopilotTestLoop(enabled: true)
        let entry = CoordinatorMessage.DesiredModelEntry(modelName: "target", desiredBuild: "target",
            revision: "new", aggregateSHA256: "verified")
        await loop.holdAutopilotForRevisionTesting(entry)
        #expect(await loop.publishVerifiedPrefetch(modelId: "target") == false)
        #expect(await loop.reserveDeferredPrefetches.contains("target"))
        #expect(await loop.advertisedModels["target"] == nil)
        #expect(await loop.pendingModelRevisions().isEmpty)
        #expect(await loop.revisionIsDesired(entry) == false)
    }
}

private extension ProviderLoop {
    func holdRevisionDrainForAutopilotTesting() { revisionUpdatesInProgress.insert("target") }

    func holdAutopilotForRevisionTesting(_ entry: CoordinatorMessage.DesiredModelEntry) {
        desiredModelRevisions[entry.desiredBuild] = entry
        autopilotCommand = .init(commandId: "owns-residency", loadModelId: "target",
            expiresAtMs: Int64(Date().timeIntervalSince1970 * 1_000) + 60_000,
            sessionId: "session", revision: "test")
    }
}
