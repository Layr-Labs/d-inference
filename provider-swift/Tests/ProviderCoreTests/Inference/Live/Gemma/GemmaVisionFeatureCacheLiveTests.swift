import Foundation
import MLX
import MLXLMCommon
import MLXLMServer
import ProviderCoreFoundation
import Testing
@testable import ProviderCore

/// Requires an exclusive native lane and the exact incident Gemma QAT artifact.
/// The 64-token / 48-GiB fixture is functional evidence only; production 4096
/// output caps, SLA/load admission and two-user HTTP qualification are separate.
/// No skip-as-pass: once explicitly enabled, missing artifacts/metallib fail.
@Suite("Gemma image feature cache incident-bound functional checks", .serialized,
    .enabled(if: LiveInferenceFixtures.gemmaTestsEnabled
        && ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_VISION_FEATURE_CACHE"] == "1"
        && ProcessInfo.processInfo.environment["DARKBLOOM_VISION_FEATURE_CACHE"] == "1"))
struct GemmaVisionFeatureCacheLiveTests: Sendable {
    private let model = "gemma-4-26b-qat-4bit"
    private let aggregate = "2468a0cb3049a871f42052f4d9f9380bf12a0792f64c7a29f768559fc7d28785"
    private let red = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAFklEQVR42mO4IyJCEmIY1TCqYfhqAAACcQQQFd0BdQAAAABJRU5ErkJggg=="
    private let blue = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAFklEQVR42mMQ0bhDEmIY1TCqYfhqAAAUJBgQCtUO5gAAAABJRU5ErkJggg=="

    private func request(_ images: [String], text: String) -> OpenAIChatCompletionRequest {
        .init(model: model, messages: [.init(role: .user,
            content: .parts(images.map { .imageURL($0) } + [.text(text)]))],
            temperature: 0, maxTokens: 64)
    }

    private struct FeatureBits: Equatable, Sendable {
        let shape: [Int]
        let dtype: String
        let bytes: Data
    }

    private func snapshot(_ prepared: EngineV2VisionPrefill.PreparedSubmission,
                          in container: ModelContainer) async throws -> [FeatureBits] {
        try await container.perform { _ in
            try await MLX.withError { (errors: MLX.ErrorBox) in
                try prepared.embeddings.map { feature in
                    eval(feature)
                    try EngineV2VisionPrefill.throwIfMLXFaulted(errors)
                    let copied = feature.asData(access: .copy)
                    try EngineV2VisionPrefill.throwIfMLXFaulted(errors)
                    return FeatureBits(shape: copied.shape, dtype: String(describing: copied.dType),
                        bytes: copied.data)
                }
            }
        }
    }

    @Test func realEncoderSkipFeatureBitsCurrentSpansAndGreedyColorOracles() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_GEMMA_QAT_MODEL_DIRECTORY"],
            "explicit incident artifact directory required; an HF alias is not identity")
        try #require(path.hasPrefix("/") && !path.utf8.contains(0))
        let directory = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        // This full hash is executed ONLY inside this explicitly opted-in test,
        // after its caller has acquired the native/resource lane.
        try #require(WeightHasher.computeHash(snapshotDir: directory, modelID: model) == aggregate,
            "requires the exact ten-file incident catalog aggregate")
        let fingerprint = try #require(WeightHasher.snapshotFingerprint(snapshotDir: directory))
        let budget = GlobalKVCacheBudget()
        let loaded = try await LiveInferenceFixtures.loadBridge(modelID: model,
            maxConcurrentRequests: 1, memoryBudgetBytes: 48 * 1024 * 1024 * 1024,
            defaultMaxTokens: 64, kvBudget: budget, modelDirectoryOverride: directory)
        let container = loaded.container
        let bridge = loaded.bridge
        let cache = bridge.visionFeatureCache
        do {
            try #require(WeightHasher.snapshotFingerprint(snapshotDir: directory) == fingerprint,
                "artifact changed during load")
            #expect(cache.isEnabled)
            let original = request([red, blue], text: "Describe the first image then the second.")
            let cold = try await EngineV2VisionPrefill.prepare(container: container, request: original)
            let firstProfile = RequestProfileBuilder()
            let first = try await EngineV2VisionPrefill.prepare(container: container, request: original,
                featureCache: cache, visionCacheScope: "qualified-account-a", profile: firstProfile)
            #expect(firstProfile.wireObject().visionEncoderImages == 2)
            #expect(firstProfile.wireObject().visionFeatureCacheHits == 0)
            let warmProfile = RequestProfileBuilder()
            let warm = try await EngineV2VisionPrefill.prepare(container: container, request: original,
                featureCache: cache, visionCacheScope: "qualified-account-a", profile: warmProfile)
            #expect(warmProfile.wireObject().visionEncoderImages == 0)
            #expect(warmProfile.wireObject().visionFeatureCacheHits == 2)
            let featureBits = (
                try await snapshot(cold, in: container),
                try await snapshot(first, in: container),
                try await snapshot(warm, in: container))
            #expect(featureBits.0 == featureBits.1)
            #expect(featureBits.0 == featureBits.2)
            try #require(featureBits.0.count == 2)
            #expect(featureBits.0[0] != featureBits.0[1]) // Two contrastive feature oracles.
            #expect(cold.promptTokens == warm.promptTokens)
            #expect(cold.spans == warm.spans)

            // All media is on a system role, which ingestion intentionally
            // drops. This deterministic input error from another scope must
            // not discard the first account's already committed warm entries.
            let invalid = OpenAIChatCompletionRequest(model: model, messages: [
                .init(role: .system, content: .parts([.imageURL(red), .text("Describe this image.")])),
                .init(role: .user, content: .text("Name its color."))
            ], temperature: 0, maxTokens: 64)
            let invalidProfile = RequestProfileBuilder()
            do {
                _ = try await EngineV2VisionPrefill.prepare(container: container, request: invalid,
                    featureCache: cache, visionCacheScope: "qualified-account-b", profile: invalidProfile)
                Issue.record("System-role-only media must be rejected")
            } catch EngineV2VisionPrefillError.noProcessedMedia {}
            #expect(invalidProfile.wireObject().visionEncoderImages == 0)
            #expect(invalidProfile.wireObject().visionFeatureCacheHits == 0)
            let afterInvalidProfile = RequestProfileBuilder()
            let afterInvalid = try await EngineV2VisionPrefill.prepare(container: container, request: original,
                featureCache: cache, visionCacheScope: "qualified-account-a", profile: afterInvalidProfile)
            #expect(afterInvalidProfile.wireObject().visionEncoderImages == 0)
            #expect(afterInvalidProfile.wireObject().visionFeatureCacheHits == 2)
            #expect(try await snapshot(afterInvalid, in: container) == featureBits.0)

            let changed = request([blue, red], text: "Now identify the second image. Answer briefly.")
            let changedCold = try await EngineV2VisionPrefill.prepare(container: container, request: changed)
            let changedProfile = RequestProfileBuilder()
            let changedWarm = try await EngineV2VisionPrefill.prepare(container: container, request: changed,
                featureCache: cache, visionCacheScope: "qualified-account-a", profile: changedProfile)
            #expect(changedProfile.wireObject().visionEncoderImages == 0)
            #expect(changedProfile.wireObject().visionFeatureCacheHits == 2)
            #expect(changedWarm.promptTokens == changedCold.promptTokens)
            #expect(changedWarm.promptTokens != cold.promptTokens)
            #expect(changedWarm.spans == changedCold.spans)
            let changedBits = (
                try await snapshot(changedCold, in: container),
                try await snapshot(changedWarm, in: container))
            #expect(changedBits.0 == changedBits.1)
            #expect(changedBits.1 == featureBits.0.reversed().map { $0 })

            // Route full completions through the production scheduler. Prefix
            // caching is disabled independently; feature hits cannot earn credit.
            let tokenizer = await container.perform { TokenizerHandle($0.tokenizer) }
            let fp16 = loaded.sizing.fp16KVBytesPerToken
            let context = loaded.sizing.maxContextLength
            func answer(_ image: String, text: String, scope: String?) async throws -> (String, InferenceProfile) {
                let profile = RequestProfileBuilder()
                let usage = EngineV2RequestUsageSignal()
                let engine = MultiModelBatchSchedulerEngine(registryProvider: {
                    [model: .init(tokenizer: tokenizer, modelType: "gemma4", container: container,
                        isVLM: true, engineV2Bridge: bridge,
                        visionGate: .init(kvBudget: budget, fp16KVBytesPerToken: fp16, contextLength: context))]
                }, defaultMaxTokens: 64, visionCacheScope: scope, cacheEnabled: false, engineV2Usage: usage, profile: profile)
                var output = ""
                var info: ServerGenerationInfo?
                for try await event in try await engine.streamChatCompletion(request: request([image], text: text)) {
                    if case .content(let text) = event { output += text }
                    if case .info(let value) = event { info = value }
                }
                let accounted = try #require(info)
                #expect(accounted.promptTokens > 0)
                #expect(accounted.cachedPromptTokens == 0)
                #expect(usage.prefixCacheHitTokens == 0)
                #expect(usage.prefixCachePrefillTokensSaved == 0)
                return (output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), profile.wireObject())
            }
            let prompt = "What single color fills this image? Reply with only the lowercase color name."
            let coldRed = try await answer(red, text: prompt, scope: nil)
            let warmRed = try await answer(red, text: prompt, scope: "qualified-account-a")
            let coldBlue = try await answer(blue, text: prompt, scope: nil)
            let warmBlue = try await answer(blue, text: prompt, scope: "qualified-account-a")
            #expect(coldRed.0 == "red")
            #expect(coldBlue.0 == "blue")
            #expect(warmRed.0 == coldRed.0)
            #expect(warmBlue.0 == coldBlue.0)
            for pair in [coldRed, coldBlue] {
                #expect(pair.1.visionFeatureCacheHits == 0)
                #expect(pair.1.visionEncoderImages == 1)
            }
            for pair in [warmRed, warmBlue] {
                #expect(pair.1.visionFeatureCacheHits == 1)
                #expect(pair.1.visionEncoderImages == 0)
            }
            let changedText = try await answer(red,
                text: "Name the dominant color. Output its lowercase name only.", scope: "qualified-account-a")
            #expect(changedText.0 == "red")
            #expect(changedText.1.visionFeatureCacheHits == 1)
            #expect(changedText.1.visionEncoderImages == 0)
            let other = try await answer(red, text: prompt, scope: "qualified-account-b")
            #expect(other.0 == "red")
            #expect(other.1.visionFeatureCacheHits == 0)
            #expect(other.1.visionEncoderImages == 1)
            try #require(WeightHasher.snapshotFingerprint(snapshotDir: directory) == fingerprint,
                "artifact changed during functional run")
        } catch {
            await bridge.shutdown()
            throw error
        }
        await bridge.shutdown()
        #expect(!cache.isEnabled)
        #expect(throws: CancellationError.self) { try cache.begin() }
    }

    /// Actual native preparations with the production ledger and cache policy.
    /// Explicit trim/close exercise release; this does not induce OS pressure,
    /// native faults, pending-copy cancellation or pinned-retired concurrency.
    @Test func realFeatureChargesTrimAndCloseRelease() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_GEMMA_QAT_MODEL_DIRECTORY"])
        try #require(path.hasPrefix("/") && !path.utf8.contains(0))
        let directory = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        try #require(WeightHasher.computeHash(snapshotDir: directory, modelID: model) == aggregate)
        let fingerprint = try #require(WeightHasher.snapshotFingerprint(snapshotDir: directory))
        let budget = GlobalKVCacheBudget()
        let loaded = try await LiveInferenceFixtures.loadBridge(modelID: model,
            maxConcurrentRequests: 1, memoryBudgetBytes: 48 * 1024 * 1024 * 1024,
            defaultMaxTokens: 64, kvBudget: budget, modelDirectoryOverride: directory)
        let container = loaded.container
        let bridge = loaded.bridge
        let cache = bridge.visionFeatureCache
        do {
            try #require(cache.isEnabled)
            let baseline = budget.processLedger.snapshot()
            let input = request([red, blue], text: "Describe both image colors.")
            let coldProfile = RequestProfileBuilder()
            let cold = try await EngineV2VisionPrefill.prepare(container: container, request: input,
                featureCache: cache, visionCacheScope: "resource-account-a", profile: coldProfile)
            let bits = try await snapshot(cold, in: container)
            try #require(bits.count == 2)
            #expect(coldProfile.wireObject().visionEncoderImages == 2)
            #expect(coldProfile.wireObject().visionFeatureCacheHits == 0)
            // There are no engine submissions in this test. Once prepare has
            // returned, its scratch owners have retired; only two host feature
            // owners should differ from the unchanged loaded-engine baseline.
            let expectedCharge = bits.reduce(UInt64(0)) { $0 + UInt64($1.bytes.count) + 1024 }
            let filled = budget.processLedger.snapshot()
            #expect(filled.chargedBytes == baseline.chargedBytes + expectedCharge)
            #expect(filled.unmaterializedBytes == baseline.unmaterializedBytes + expectedCharge)
            #expect(filled.materializedBytes == baseline.materializedBytes)
            #expect(filled.ownerCount == baseline.ownerCount + 2)
            #expect(filled.closingOwnerCount == baseline.closingOwnerCount)
            let warmProfile = RequestProfileBuilder()
            let warm = try await EngineV2VisionPrefill.prepare(container: container, request: input,
                featureCache: cache, visionCacheScope: "resource-account-a", profile: warmProfile)
            #expect(warmProfile.wireObject().visionEncoderImages == 0)
            #expect(warmProfile.wireObject().visionFeatureCacheHits == 2)
            #expect(try await snapshot(warm, in: container) == bits)
            let reused = budget.processLedger.snapshot()
            #expect(reused.chargedBytes == filled.chargedBytes)
            #expect(reused.unmaterializedBytes == filled.unmaterializedBytes)
            #expect(reused.materializedBytes == filled.materializedBytes)
            #expect(reused.ownerCount == filled.ownerCount)
            // The ordinary production budget trimmer removes retained CPU
            // copies. Existing request-owned hydrated native embeddings remain
            // usable and byte-identical after those CPU owners retire.
            budget.visionFeatureCacheBudget.trim()
            let trimmed = budget.processLedger.snapshot()
            #expect(trimmed.chargedBytes == baseline.chargedBytes)
            #expect(trimmed.unmaterializedBytes == baseline.unmaterializedBytes)
            #expect(trimmed.materializedBytes == baseline.materializedBytes)
            #expect(trimmed.ownerCount == baseline.ownerCount)
            #expect(trimmed.closingOwnerCount == baseline.closingOwnerCount)
            #expect(try await snapshot(warm, in: container) == bits)
            let refillProfile = RequestProfileBuilder()
            let refill = try await EngineV2VisionPrefill.prepare(container: container, request: input,
                featureCache: cache, visionCacheScope: "resource-account-a", profile: refillProfile)
            #expect(refillProfile.wireObject().visionEncoderImages == 2)
            #expect(refillProfile.wireObject().visionFeatureCacheHits == 0)
            #expect(try await snapshot(refill, in: container) == bits)
            let refilled = budget.processLedger.snapshot()
            #expect(refilled.chargedBytes == filled.chargedBytes)
            #expect(refilled.unmaterializedBytes == filled.unmaterializedBytes)
            #expect(refilled.materializedBytes == filled.materializedBytes)
            #expect(refilled.ownerCount == filled.ownerCount)
            await cache.closeAndDrain()
            let closed = budget.processLedger.snapshot()
            #expect(!cache.isEnabled)
            #expect(closed.chargedBytes == baseline.chargedBytes)
            #expect(closed.unmaterializedBytes == baseline.unmaterializedBytes)
            #expect(closed.materializedBytes == baseline.materializedBytes)
            #expect(closed.ownerCount == baseline.ownerCount)
            #expect(closed.closingOwnerCount == baseline.closingOwnerCount)
            #expect(throws: CancellationError.self) { try cache.begin() }
            #expect(try await snapshot(refill, in: container) == bits)
            try #require(WeightHasher.snapshotFingerprint(snapshotDir: directory) == fingerprint)
            print("gemma_native_feature_charge expected=\(expectedCharge) baseline=\(baseline.chargedBytes) filled=\(filled.chargedBytes) reused=\(reused.chargedBytes) trimmed=\(trimmed.chargedBytes) refilled=\(refilled.chargedBytes) closed=\(closed.chargedBytes)")
        } catch {
            await bridge.shutdown()
            throw error
        }
        await bridge.shutdown()
    }
}
