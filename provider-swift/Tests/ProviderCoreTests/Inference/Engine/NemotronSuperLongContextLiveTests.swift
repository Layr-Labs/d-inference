// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
@testable import MLXLLM
@testable import MLXLMCommon
@testable import MLXVLM
import Testing
@testable import ProviderCore

/// Gated full-checkpoint long-context run of the Super trunk under the
/// shipping activation-overflow policy (saturating, selected by the pinned
/// staging): natural text from this repository's documentation prefilled in
/// the owner's 2,048-token chunks up to `DARKBLOOM_SUPER_LONGCTX_TOKENS`
/// (default the served context), then greedy decode steps. Every chunk end's
/// and decode step's logits must be finite, and each chunk's MLX peak above
/// the memory held before it must stay within the owner's prefill lane.
/// Loads about 80 GB; run only with exclusive GPU access,
/// `DARKBLOOM_SUPER_LONGCTX_LIVE=1` and `NEMOTRON_SUPER_CHECKPOINT_DIR`.
struct NemotronSuperLongContextLiveTests {
    static let environment = ProcessInfo.processInfo.environment
    static let enabled = environment["DARKBLOOM_SUPER_LONGCTX_LIVE"] == "1"
        && environment["NEMOTRON_SUPER_CHECKPOINT_DIR"] != nil
    static let chunk = NemotronSuperLocalPrefill.defaultChunkTokens
    static let decodeSteps = 16

    /// Documentation prose in path order, evidence tables excluded.
    static func documentation() throws -> String {
        // Tests/ProviderCoreTests/Inference/Engine -> the repository's docs/.
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
            .appendingPathComponent("../../../../../docs").standardizedFileURL
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "md" && !$0.pathComponents.contains("evidence") }
            .sorted { $0.path < $1.path }
        return try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n\n")
    }

    @Test(.enabled(if: enabled), .timeLimit(.minutes(60)))
    func pinnedCheckpointStaysFiniteAndInsideTheLaneAtLongContext() async throws {
        let directory = URL(fileURLWithPath: try #require(Self.environment["NEMOTRON_SUPER_CHECKPOINT_DIR"]),
            isDirectory: true)
        let length = Int(Self.environment["DARKBLOOM_SUPER_LONGCTX_TOKENS"] ?? "")
            ?? NemotronSuperServingPolicy.contextTokens
        try #require(length > Self.decodeSteps && length <= NemotronSuperServingPolicy.maximumContextTokens)
        let inputs = try NemotronSuperCheckpoint.Inputs(directory: directory)
        let files = try await NemotronSuperCheckpoint.openShards(directory: directory,
            names: inputs.inventory.shards, parallelism: 8)
        let source = try ModelOptCheckpointSource(indexData: inputs.indexData,
            indexSHA256: inputs.indexSHA256, files: files)
        let allowance = NemotronSuperServingPolicy.backendAllowanceBytes
        let quote = try NemotronSuperInstallation.requiredLoadBytes(source: source, backendAllowanceBytes: allowance)
        let installed = try NemotronSuperInstallation.stage(
            configuration: try NemotronSuperImageConfiguration(data: inputs.configData), source: source,
            residency: try NemotronSuperResidency(capacityBytes: quote, maximumRequests: 1),
            backendAllowanceBytes: allowance, construction: NativeConstructionScope())
        defer { installed.closeAfterRetirement() }
        let model = try #require(installed.model)

        let tokenizer = try await LocalTokenizerLoader().load(from: directory)
        let encoded = tokenizer.encode(text: try Self.documentation(), addSpecialTokens: false)
        let promptLength = length - Self.decodeSteps
        try #require(encoded.count >= promptLength, "documentation encodes to \(encoded.count) tokens")
        let prompt = encoded.prefix(promptLength).map { Int32($0) }

        let adapter = NemotronSuperRecurrentAdapter(model)
        let backend = CBv2ContiguousKVBackend(config: .init(bytesCapacity: 8 << 30, kvDType: .bfloat16))
        let bank = CBv2LayerCacheBank(caches: model.languageModel.newCacheV2 {
            CBv2LayerCache(layerIndex: $0, kind: $1)
        })
        let rows = try backend.makeSequenceState(layerKinds: model.cbv2LayerKinds,
            promptLength: prompt.count, maxLength: length)
        let state = try CBv2RecurrentRequestState(spec: model.cbv2RecurrentStateSpec)
        func caches() -> [KVCache] { bank.layerCaches(rowStates: [rows]).map { $0 as! KVCache } }
        func finite(_ logits: MLXArray) -> (Bool, Float) {
            (all(isFinite(logits)).item(Bool.self), abs(logits).max().item(Float.self))
        }

        let lane = NemotronHModel.prefillActivationBoundBytes(tokens: Self.chunk)
        var token: Int32 = 0
        var worstTransient = 0
        var largestLogit: Float = 0
        var nonFinite: [Int] = []
        let started = ContinuousClock.now
        for start in stride(from: 0, to: prompt.count, by: Self.chunk) {
            let end = min(prompt.count, start + Self.chunk)
            Memory.clearCache()
            let held = Memory.activeMemory
            GPU.resetPeakMemory()
            let cache = caches()
            let binding = try state.bind()
            let output = adapter.cbv2RecurrentPrefill(
                MLXArray(Array(prompt[start ..< end])).reshaped(1, end - start), inputEmbedding: nil,
                cache: cache, recurrentState: [binding], positionIds: nil, requirement: .lastPositionLogits)
            let logits = output.reshaped(-1, output.dim(-1))[-1].asType(.float32)
            eval([logits] + (try binding.evaluate()) + cache.flatMap { $0.innerState() })
            try binding.commit()
            let transient = Memory.peakMemory - held
            worstTransient = max(worstTransient, transient)
            let (ok, scale) = finite(logits)
            largestLogit = max(largestLogit, scale)
            if !ok { nonFinite.append(end) }
            token = argMax(logits).item(Int32.self)
            if end % (16 * Self.chunk) == 0 || end == prompt.count {
                print("SUPER_LONGCTX_LIVE prefill \(end): finite \(ok) max_logit \(scale) "
                    + "transient_bytes \(transient) elapsed_s \(started.duration(to: .now))")
            }
        }
        let prefillSeconds = started.duration(to: .now)
        var decoded: [Int] = []
        for step in 0 ..< Self.decodeSteps {
            let cache = caches()
            let binding = try state.bind()
            let logits = adapter.cbv2Forward(MLXArray([token]).reshaped(1, 1), caches: cache,
                recurrentState: [binding])[0, -1].asType(.float32)
            eval([logits] + (try binding.evaluate()) + cache.flatMap { $0.innerState() })
            try binding.commit()
            let (ok, scale) = finite(logits)
            largestLogit = max(largestLogit, scale)
            if !ok { nonFinite.append(prompt.count + step + 1) }
            token = argMax(logits).item(Int32.self)
            decoded.append(Int(token))
        }
        print("SUPER_LONGCTX_LIVE context \(length) prompt \(prompt.count) chunk \(Self.chunk) "
            + "non_finite_positions \(nonFinite) max_logit \(largestLogit) worst_transient_bytes "
            + "\(worstTransient) lane_bytes \(lane) prefill_s \(prefillSeconds) decoded "
            + "\(tokenizer.decode(tokenIds: decoded, skipSpecialTokens: false).debugDescription)")
        #expect(nonFinite.isEmpty)
        #expect(worstTransient <= lane)
        bank.releaseBoundRows()
        try state.release()
        backend.release(rows)
    }
}
