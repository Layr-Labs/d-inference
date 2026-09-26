import Foundation
import ProviderCore
import Testing
@testable import darkbloom

@Suite("Scheduled window model selection")
struct ScheduledWindowSelectionTests {
    private let hardware = HardwareInfo(
        machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
        memoryGb: 128, memoryAvailableGb: 124,
        cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
        gpuCores: 40, memoryBandwidthGbs: 546)

    private func startup(config: ProviderConfig, path: URL, model: String = "fixture/a") -> ProviderLoopConfig {
        ProviderLoopConfig(
            coordinatorURL: "wss://startup.invalid/ws/provider", hardware: hardware,
            models: [ModelInfo(id: model, modelType: "gpt_oss", sizeBytes: 1, estimatedMemoryGb: 1)],
            config: config, authToken: "startup-auth",
            runtimeHashes: RuntimeHashes(pythonHash: "python", runtimeHash: "metallib", templateHashes: ["a": "template"]),
            runtimeCapabilities: [.appleM5, .mlxNAX],
            modelHashes: [model: "stale-startup-hash"], modelHashFingerprints: [model: "stale-startup-fingerprint"],
            localEndpoint: LocalInferenceHTTPConfig(host: "127.0.0.2", port: 8123, authToken: "local-auth"),
            configPath: path)
    }

    private func snapshot(in cache: URL, id: String) throws -> URL {
        let path = cache.appendingPathComponent("models--\(id.replacingOccurrences(of: "/", with: "--"))/snapshots/current")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try Data(#"{"model_type":"gpt_oss","hidden_size":64}"#.utf8).write(to: path.appendingPathComponent("config.json"))
        try Data(id.utf8).write(to: path.appendingPathComponent("model.safetensors"))
        return path
    }

    /// Exercise real scanner metadata and weight hashing in an isolated cache;
    /// production resolves the same IDs from the process's HuggingFace cache.
    private func resolve(_ ids: [String], cache: URL, paths: [String: URL]) throws -> [ModelInfo] {
        let local = ModelScanner.scanAllModels(in: cache, environment: [:])
        return try ids.map { id in
            var model = try #require(local.first { $0.id == id })
            model.weightHash = try #require(WeightHasher.computeHash(snapshotDir: #require(paths[id]), modelID: id))
            return model
        }
    }

    @Test func nextWindowUsesDurableSelectionAndFreshHashesWithoutReloadingOtherSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("custom-provider.toml")
        let b = try snapshot(in: directory, id: "fixture/b")
        _ = try snapshot(in: directory, id: "fixture/unselected")
        var original = ProviderConfig(provider: ProviderSettings(name: "startup-provider"))
        original.backend.enabledModels = ["fixture/a"]
        original.backend.idleTimeoutMins = 17
        try ConfigManager.save(original, to: path)
        let loopConfig = startup(config: original, path: path)
        var selection = ScheduledWindowSelection(startup: loopConfig, configFileExists: true)
        #expect(try selection.nextWindowConfiguration().models.map(\.id) == ["fixture/a"])

        var edited = original
        edited.provider.name = "not-live"
        edited.backend.idleTimeoutMins = 99
        edited.coordinator.url = "wss://not-live.invalid"
        try ConfigManager.save(edited, to: path)
        try ProviderModelSelection.save(["fixture/b"], configPath: path)
        let next = try selection.nextWindowConfiguration(
            resolveModels: { ids, _ in try resolve(ids, cache: directory, paths: ["fixture/b": b]) },
            resolveLocalPath: { $0 == "fixture/b" ? b : nil })
        let hash = try #require(WeightHasher.computeHash(snapshotDir: b, modelID: "fixture/b"))
        let fingerprint = try #require(WeightHasher.snapshotFingerprint(snapshotDir: b))
        #expect(next.models.map(\.id) == ["fixture/b"])
        #expect(next.models.first?.weightHash == hash)
        #expect(next.models.first?.modelType == "gpt_oss")
        #expect(next.models.first?.sizeBytes == UInt64("fixture/b".utf8.count))
        #expect(next.modelHashes == ["fixture/b": hash])
        #expect(next.modelHashFingerprints == ["fixture/b": fingerprint])
        #expect(next.config.backend.enabledModels == ["fixture/b"])
        #expect(loopConfig.models.map(\.id) == ["fixture/a"])
        #expect(loopConfig.config.backend.enabledModels == ["fixture/a"])
        #expect(next.config.provider.name == "startup-provider")
        #expect(next.config.backend.idleTimeoutMins == 17)
        #expect(next.config.coordinator.url == original.coordinator.url)
        #expect(next.coordinatorURL == loopConfig.coordinatorURL)
        #expect(next.hardware == loopConfig.hardware)
        #expect(next.authToken == "startup-auth")
        #expect(next.runtimeCapabilities == [.appleM5, .mlxNAX])
        #expect(next.runtimeHashes?.pythonHash == "python")
        #expect(next.runtimeHashes?.runtimeHash == "metallib")
        #expect(next.runtimeHashes?.templateHashes == ["a": "template"])
        #expect(next.localEndpoint?.host == "127.0.0.2")
        #expect(next.localEndpoint?.port == 8123)
        #expect(next.localEndpoint?.authToken == "local-auth")
        #expect(next.configPath == path)

        // Another window must still select B and must not reuse old snapshot
        // metadata when its on-disk weights changed during the idle period.
        try Data("updated fixture/b weights".utf8).write(to: b.appendingPathComponent("model.safetensors"))
        let later = try selection.nextWindowConfiguration(
            resolveModels: { ids, _ in try resolve(ids, cache: directory, paths: ["fixture/b": b]) },
            resolveLocalPath: { $0 == "fixture/b" ? b : nil })
        let updatedHash = try #require(WeightHasher.computeHash(snapshotDir: b, modelID: "fixture/b"))
        #expect(later.models.map(\.id) == ["fixture/b"])
        #expect(updatedHash != hash)
        #expect(later.modelHashes == ["fixture/b": updatedHash])
        #expect(later.modelHashFingerprints["fixture/b"] == WeightHasher.snapshotFingerprint(snapshotDir: b))
        #expect(later.modelHashFingerprints["fixture/b"] != fingerprint)
    }

    @Test func explicitSwitchToAlreadySavedIDsReplacesManualOverrideNextWindow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("provider.toml")
        let target = try snapshot(in: directory, id: "fixture/b")
        var original = ProviderConfig(provider: ProviderSettings(name: "manual"))
        original.backend.enabledModels = ["fixture/b"]
        try ConfigManager.save(original, to: path)
        var selection = ScheduledWindowSelection(
            startup: startup(config: original, path: path, model: "manual-argv"), configFileExists: true)
        #expect(try selection.nextWindowConfiguration().models.map(\.id) == ["manual-argv"])
        try ProviderModelSelection.save(["fixture/b"], configPath: path)
        selection.notePersistedSwitch()
        let next = try selection.nextWindowConfiguration(
            resolveModels: { ids, _ in try resolve(ids, cache: directory, paths: ["fixture/b": target]) },
            resolveLocalPath: { $0 == "fixture/b" ? target : nil })
        #expect(next.models.map(\.id) == ["fixture/b"])
    }

    @Test func manualOverrideSurvivesUntilDurableSelectionChangesAndNeverReturnsAfterward() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("custom-provider.toml")
        let paths = ["fixture/a": try snapshot(in: directory, id: "fixture/a"),
                     "fixture/b": try snapshot(in: directory, id: "fixture/b")]
        var original = ProviderConfig(provider: ProviderSettings(name: "manual"))
        original.backend.enabledModels = ["fixture/a"]
        try ConfigManager.save(original, to: path)
        var selection = ScheduledWindowSelection(
            startup: startup(config: original, path: path, model: "manual-argv"), configFileExists: true)
        #expect(try selection.nextWindowConfiguration().models.map(\.id) == ["manual-argv"])
        original.backend.idleTimeoutMins = 99
        try ConfigManager.save(original, to: path)
        // No local "manual-argv" snapshot exists: unchanged windows must retain
        // the already resolved startup selection rather than re-select from disk.
        #expect(try selection.nextWindowConfiguration().models.map(\.id) == ["manual-argv"])
        for ids in [["fixture/b"], ["fixture/a"], ["fixture/b", "fixture/a"]] {
            try ProviderModelSelection.save(ids, configPath: path)
            let next = try selection.nextWindowConfiguration(
                resolveModels: { ids, _ in try resolve(ids, cache: directory, paths: paths) },
                resolveLocalPath: { paths[$0] })
            #expect(next.models.map(\.id) == ids)
            #expect(next.config.backend.enabledModels == ids)
            #expect(Set(next.modelHashes.keys) == Set(ids))
        }
    }

    @Test func invalidSavedSelectionOrConfigCannotFallBackToStartup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("custom-provider.toml")
        var config = ProviderConfig(provider: ProviderSettings(name: "invalid-selection"))
        config.backend.enabledModels = ["fixture/a"]
        try ConfigManager.save(config, to: path)
        var selection = ScheduledWindowSelection(startup: startup(config: config, path: path), configFileExists: true)
        _ = try selection.nextWindowConfiguration()
        try ProviderModelSelection.save(["missing-\(UUID().uuidString)"], configPath: path)
        #expect(throws: (any Error).self) { _ = try selection.nextWindowConfiguration() }
        try ProviderModelSelection.save([], configPath: path)
        #expect(throws: (any Error).self) { _ = try selection.nextWindowConfiguration() }
        try "[backend]\nenabled_models = 42\n".write(to: path, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { _ = try selection.nextWindowConfiguration() }
        try FileManager.default.removeItem(at: path)
        #expect(throws: (any Error).self) { _ = try selection.nextWindowConfiguration() }
    }

    @Test func firstWindowKeepsStartupSelectionEvenIfDurableSelectionAlreadyChanged() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("custom-provider.toml")
        var config = ProviderConfig(provider: ProviderSettings(name: "initial-window"))
        config.backend.enabledModels = ["fixture/a"]
        var selection = ScheduledWindowSelection(startup: startup(config: config, path: path), configFileExists: false)
        try ProviderModelSelection.save(["missing-\(UUID().uuidString)"], configPath: path)
        #expect(try selection.nextWindowConfiguration().models.map(\.id) == ["fixture/a"])
        #expect(throws: (any Error).self) { _ = try selection.nextWindowConfiguration() }
    }
}
