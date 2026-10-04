import Foundation
import Testing
@testable import ProviderCore

@Suite("Autopilot startup ownership")
struct AutopilotStartupTests {
    @Test func activationCannotOverlapSelectedModelStartupPreload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ModelInfo(id: "target", modelType: "gemma4", parameters: nil,
            quantization: "4bit", sizeBytes: 2_000_000_000, estimatedMemoryGb: 2)
        let loop = try await autopilotTestLoop(enabled: true, models: [model], activeControl: false)
        await loop.setLoadedModelsFileForTesting(root.appendingPathComponent("loaded.json"))
        await loop.setDaemonStateFileForTesting(root.appendingPathComponent("daemon.json"))
        await loop.setStartupPreloadFreeMemoryOverrideForTesting { 100 }
        await loop.setStartupSelfTestOverrideForTesting { _ in .milliseconds(1) }
        let (release, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        await loop.setStartupPreloadLoadOverrideForTesting { _ in
            for await _ in release { break }
        }
        #expect(await loop.startupPreloadPlanForTesting().map(\.modelId) == ["target"])
        let startup = Task { await loop.runStartupPreloadGateForTesting() }
        var polls = 0
        while !(await loop.startupPreloadTaskRunningForTesting()), polls < 500 {
            try await Task.sleep(for: .milliseconds(10))
            polls += 1
        }
        #expect(await loop.startupPreloadTaskRunningForTesting())
        await loop.activateAutopilotForTesting()
        let recorder = AutopilotRecorder()
        await loop.handleModelAutopilot(.init(commandId: "during-startup", loadModelId: "target",
            expiresAtMs: Int64(Date().timeIntervalSince1970 * 1_000) + 60_000,
            sessionId: "session", revision: "test"), send: SendHandle(recorder.append))
        #expect(recorder.statuses.last?.error == "provider_busy")
        #expect(await loop.autopilotCommand == nil)
        continuation.yield(())
        #expect(await startup.value == .warm)
        #expect(await loop.modelAutopilotEnabled)
    }
}
