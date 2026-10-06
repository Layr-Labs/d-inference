import Foundation
import ProviderCore
import Testing
@testable import darkbloom

@Suite("Autopilot downloaded network inventory")
struct AutopilotInventoryTests {
    private func local(_ id: String, size: Double = 2, type: String = "gemma4") -> ModelInfo {
        ModelInfo(id: id, modelType: type, parameters: nil, quantization: "4bit",
            sizeBytes: 2_000_000_000, estimatedMemoryGb: size)
    }

    private func catalog(_ id: String, active: Bool = true,
                         capabilities: [ProviderRuntimeCapability]? = nil) -> CatalogModel {
        CatalogModel(id: id, s3Name: id, displayName: id, sizeGb: 2,
            active: active, weightHash: "verified-build", requiredProviderCapabilities: capabilities)
    }

    @Test func inventoryIsIntersectionNotAPickerOrCatalogDownload() async throws {
        let result = try await Start.verifiedAutopilotInventory(
            local: [local("z"), local("a"), local("a"), local("local-only"), local("retired"),
                    local("too-large", size: 100), local("unsupported", type: "unknown"), local("protected")],
            catalog: [catalog("a"), catalog("z"), catalog("catalog-only"), catalog("retired", active: false),
                      catalog("too-large"), catalog("unsupported"), catalog("protected", capabilities: [.mlxNAX])],
            memoryGb: 64, runtimeCapabilities: [], verify: { model in
                #expect(["a", "z"].contains(model.id))
            })
        #expect(result == ["a", "z"])
    }

    @Test func progressIdentifiesTheModelBeforeVerificationWaitsOrFails() async throws {
        var events: [String] = []
        let result = try await Start.verifiedAutopilotInventory(
            local: [local("z"), local("a"), local("local-only")],
            catalog: [catalog("a"), catalog("z")], memoryGb: 64, runtimeCapabilities: [],
            verifying: { events.append("checking \($0)") },
            verify: { model in
                events.append("verify \(model.id)")
                if model.id == "a" { throw CocoaError(.fileReadNoPermission) }
            }, excluded: { id, _ in events.append("excluded \(id)") })
        #expect(result == ["z"])
        #expect(events == ["checking a", "verify a", "excluded a", "checking z", "verify z"])
    }

    @Test func unverifiedDownloadedBuildsAreExcludedWithoutDownloading() async throws {
        var excluded: [String] = []
        let result = try await Start.verifiedAutopilotInventory(
            local: [local("good"), local("bad")], catalog: [catalog("good"), catalog("bad")],
            memoryGb: 64, runtimeCapabilities: [], verify: { model in
                if model.id == "bad" { throw CocoaError(.fileReadCorruptFile) }
            }, excluded: { id, _ in excluded.append(id) })
        #expect(result == ["good"])
        #expect(excluded == ["bad"])
    }

    @Test func savedConsentDoesNotExpandUntilExplicitInventoryRefresh() async throws {
        let models = [local("previous"), local("newly-downloaded")]
        let entries = [catalog("previous"), catalog("newly-downloaded")]
        let saved = try await Start.verifiedAutopilotInventory(local: models, catalog: entries,
            memoryGb: 64, runtimeCapabilities: [], approved: ["previous"], verify: { _ in })
        let refreshed = try await Start.verifiedAutopilotInventory(local: models, catalog: entries,
            memoryGb: 64, runtimeCapabilities: [], verify: { _ in })
        #expect(saved == ["previous"])
        #expect(refreshed == ["newly-downloaded", "previous"])
    }

    @Test(arguments: ["transient-verification", "missing-local", "removed-catalog", "ineligible"])
    func ordinaryStartCannotPersistPartialRecordedInventory(failure: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("provider.toml")
        var config = ProviderConfig(provider: ProviderSettings(name: "fixed-inventory"))
        config.backend.modelAutopilot = .init(enabled: true, consentRecorded: true,
            paused: true, selectedModels: ["a", "b"], revision: "recorded")
        try ConfigManager.save(config, to: path)
        let before = try Data(contentsOf: path)
        let models = failure == "missing-local" ? [local("a")] : [local("a"), local("b")]
        let entries = failure == "removed-catalog" ? [catalog("a")]
            : [catalog("a"), catalog("b", capabilities: failure == "ineligible" ? [.mlxNAX] : nil)]
        await #expect(throws: (any Error).self) {
            let inventory = try await Start.verifiedAutopilotInventory(local: models, catalog: entries,
                memoryGb: 64, runtimeCapabilities: [], approved: ["a", "b"], verify: { entry in
                    if failure == "transient-verification" && entry.id == "b" {
                        throw URLError(.timedOut)
                    }
                })
            try await Start.completeDaemonReplacement(autopilot: true, models: inventory,
                configPath: path.path, stop: { Issue.record("Partial validation must not stop the daemon") },
                install: { Issue.record("Partial validation must not install a replacement") })
        }
        #expect(try Data(contentsOf: path) == before)
        #expect(try ConfigManager.load(from: path).backend.modelAutopilot.selectedModels == ["a", "b"])
    }

    @Test func emptyOrFailedInventoryRefusesBeforeEnrollment() async {
        await #expect(throws: (any Error).self) {
            try await Start.verifiedAutopilotInventory(local: [], catalog: [catalog("remote-only")],
                memoryGb: 64, runtimeCapabilities: [], verify: { _ in
                    Issue.record("A catalog-only model must not be verified or downloaded")
                })
        }
        await #expect(throws: (any Error).self) {
            try await Start.verifiedAutopilotInventory(local: [local("bad")], catalog: [catalog("bad")],
                memoryGb: 64, runtimeCapabilities: [], verify: { _ in throw CocoaError(.fileReadCorruptFile) })
        }
    }

    @Test func cancellationCannotBecomePartialEnrollment() async {
        await #expect(throws: CancellationError.self) {
            try await Start.verifiedAutopilotInventory(local: [local("a"), local("b")],
                catalog: [catalog("a"), catalog("b")], memoryGb: 64, runtimeCapabilities: [],
                verify: { if $0.id == "b" { throw CancellationError() } })
        }
    }

    @Test func cancellationDuringSuccessfulFinalVerificationCannotEnroll() async {
        let (started, signal) = AsyncStream<Void>.makeStream()
        let gate = InventoryVerificationGate()
        let task = Task {
            try await Start.verifiedAutopilotInventory(local: [local("a")], catalog: [catalog("a")],
                memoryGb: 64, runtimeCapabilities: [], verify: { _ in
                    await gate.wait(signal: signal)
                })
        }
        for await _ in started { break }
        task.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        signal.finish()
    }
}

private actor InventoryVerificationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait(signal: AsyncStream<Void>.Continuation) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            signal.yield(())
        }
    }
    func release() { continuation?.resume(); continuation = nil }
}
