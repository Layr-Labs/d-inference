// Copyright © 2026 Eigen Labs.
//
// DeepSeek-V4 MoE expert-streaming lifecycle: (a) `ExpertStreamingConfigurator
// .configure`'s pure enabled/disabled decision (the signal `BatchScheduler
// .stopCurrentEngine()` uses to decide whether to purge the shared expert
// cache on unload), and (b) `BatchScheduler`'s purge-on-unload wiring itself,
// exercised against the real, process-wide `DeepseekV4ExpertStreaming.cache`.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import XCTest

@testable import ProviderCore

final class ExpertStreamingLifecycleTests: XCTestCase {

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsv4-lifecycle-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeConfig(modelType: String?, to dir: URL) throws {
        var json: [String: Any] = [:]
        if let modelType { json["model_type"] = modelType }
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: dir.appendingPathComponent("config.json"))
    }

    override func tearDown() {
        // Belt-and-suspenders: don't let one test's `enabled=true` /
        // `modelDirectory` leak into a sibling test via the process-wide
        // statics.
        MLXLLM.DeepseekV4ExpertStreaming.enabled = false
        MLXLLM.DeepseekV4ExpertStreaming.modelDirectory = nil
        MLXLLM.DeepseekV4ExpertStreaming.purgeCache()
        super.tearDown()
    }

    // MARK: - (a) ExpertStreamingConfigurator.configure: pure enabled decision

    func testConfigureIsDisabledWhenStreamExpertsIsOff() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeConfig(modelType: "deepseek_v4", to: dir)

        let result = ExpertStreamingConfigurator.configure(
            streamExperts: false, expertCacheGb: 8, modelDirectory: dir)

        XCTAssertFalse(result.enabled, "streamExperts=false must never enable streaming, even for a deepseek_v4 checkpoint")
        XCTAssertEqual(result.cacheBytes, 0)
        XCTAssertFalse(MLXLLM.DeepseekV4ExpertStreaming.enabled)
    }

    func testConfigureIsDisabledForNonDeepseekV4ModelType() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeConfig(modelType: "gemma3", to: dir)

        let result = ExpertStreamingConfigurator.configure(
            streamExperts: true, expertCacheGb: 8, modelDirectory: dir)

        XCTAssertFalse(result.enabled, "only deepseek_v4 checkpoints ever enable streaming")
        XCTAssertEqual(result.cacheBytes, 0)
    }

    func testConfigureIsDisabledWhenConfigJsonIsMissing() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // No config.json at all.

        let result = ExpertStreamingConfigurator.configure(
            streamExperts: true, expertCacheGb: 8, modelDirectory: dir)

        XCTAssertFalse(result.enabled)
    }

    func testConfigureEnablesStreamingForDeepseekV4WhenRequested() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeConfig(modelType: "deepseek_v4", to: dir)

        let result = ExpertStreamingConfigurator.configure(
            streamExperts: true, expertCacheGb: 8, modelDirectory: dir)

        XCTAssertTrue(result.enabled)
        XCTAssertGreaterThan(
            result.cacheBytes, 0,
            "an empty checkpoint dir (0 resident weight bytes) leaves ample headroom under the "
                + "cap for a positive auto-sized cache on any machine running this test")
        XCTAssertTrue(MLXLLM.DeepseekV4ExpertStreaming.enabled, "must flip the module-level opt-in")
        XCTAssertEqual(MLXLLM.DeepseekV4ExpertStreaming.modelDirectory, dir)
        XCTAssertEqual(
            UInt64(MLXLLM.DeepseekV4ExpertStreaming.cache.currentByteBudget), result.cacheBytes,
            "configure must resize the shared cache's budget directly, not rely solely on setenv")
    }

    func testConfigureCaseInsensitiveIsNotAssumed() throws {
        // Document current behavior precisely (mirrors
        // `ExpertStreamingConfigurator.modelType` reading `config.json`
        // verbatim, no case-folding) -- a checkpoint that ships an
        // unexpectedly-cased model_type does not opt in.
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeConfig(modelType: "DeepSeek_V4", to: dir)

        let result = ExpertStreamingConfigurator.configure(
            streamExperts: true, expertCacheGb: 8, modelDirectory: dir)

        XCTAssertFalse(result.enabled)
    }

    // MARK: - (b) BatchScheduler: purge fires iff THIS load configured streaming

    func testUnloadPurgesSharedExpertCacheWhenThisLoadConfiguredStreaming() async throws {
        let scheduler = BatchScheduler(maxConcurrentRequests: 4)
        await scheduler._setExpertStreamingConfiguredForTest(true)
        let configured = await scheduler._expertStreamingConfiguredForTest()
        XCTAssertTrue(configured)

        let placeholder = ExpertWeights(
            gateWeight: .zeros([1]), gateScales: .zeros([1]), gateBiases: nil,
            upWeight: .zeros([1]), upScales: .zeros([1]), upBiases: nil,
            downWeight: .zeros([1]), downScales: .zeros([1]), downBiases: nil,
            byteCount: 10)
        MLXLLM.DeepseekV4ExpertStreaming.cache.insert(layer: 0, expert: 0, weights: placeholder)
        XCTAssertTrue(MLXLLM.DeepseekV4ExpertStreaming.cache.contains(layer: 0, expert: 0))

        await scheduler.unloadModel()

        XCTAssertFalse(
            MLXLLM.DeepseekV4ExpertStreaming.cache.contains(layer: 0, expert: 0),
            "unloading a model that configured streaming must purge the shared expert cache")
        let stillConfigured = await scheduler._expertStreamingConfiguredForTest()
        XCTAssertFalse(stillConfigured, "the flag itself must reset on teardown")
    }

    func testUnloadDoesNotPurgeSharedExpertCacheWhenThisLoadDidNotConfigureStreaming() async throws {
        let scheduler = BatchScheduler(maxConcurrentRequests: 4)
        // Deliberately left at its default (false) -- this model's load never
        // called `ExpertStreamingConfigurator.configure` with streaming
        // enabled, so its unload must not disturb a cache another
        // (hypothetical) streaming-configured slot might still be using.
        let configured = await scheduler._expertStreamingConfiguredForTest()
        XCTAssertFalse(configured)

        let placeholder = ExpertWeights(
            gateWeight: .zeros([1]), gateScales: .zeros([1]), gateBiases: nil,
            upWeight: .zeros([1]), upScales: .zeros([1]), upBiases: nil,
            downWeight: .zeros([1]), downScales: .zeros([1]), downBiases: nil,
            byteCount: 10)
        MLXLLM.DeepseekV4ExpertStreaming.cache.insert(layer: 0, expert: 0, weights: placeholder)

        await scheduler.unloadModel()

        XCTAssertTrue(
            MLXLLM.DeepseekV4ExpertStreaming.cache.contains(layer: 0, expert: 0),
            "unloading a model that did NOT configure streaming must leave the shared cache alone")
    }
}
