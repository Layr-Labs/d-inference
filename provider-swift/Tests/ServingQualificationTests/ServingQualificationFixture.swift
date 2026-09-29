import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import MLXLMServer
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

final class ServingQualificationFixture: @unchecked Sendable {
    let job: ServingQualificationJob
    let bundle: ProviderEngineBundle
    let container: ModelContainer
    let tokenizer: TokenizerHandle
    let sizing: SlotSizingSnapshot
    let promptContractID: String
    let mtp: ServingMTPConfiguration?
    let budget: GlobalKVCacheBudget
    private let postureLease: DeadlinePostureLease

    private init(job: ServingQualificationJob, bundle: ProviderEngineBundle,
                 container: ModelContainer, tokenizer: TokenizerHandle, sizing: SlotSizingSnapshot,
                 promptContractID: String, mtp: ServingMTPConfiguration?, budget: GlobalKVCacheBudget,
                 postureLease: DeadlinePostureLease) {
        self.job = job; self.bundle = bundle; self.container = container
        self.tokenizer = tokenizer; self.sizing = sizing
        self.promptContractID = promptContractID; self.mtp = mtp; self.budget = budget
        self.postureLease = postureLease
    }

    static func load(
        _ job: ServingQualificationJob, sharedBudget: GlobalKVCacheBudget? = nil,
        kvGrantUpperBound: UInt64? = nil, activationReserveBytes: UInt64? = nil,
        requireInlineMTP: Bool = true
    ) async throws -> ServingQualificationFixture {
        // Use the same bounded background power-policy reader as production,
        // including when collecting fresh evidence with an empty catalog.
        let postureLease = DeadlinePostureMonitor.shared.acquire()
        let executable = try #require(Bundle(for: QualificationBundleMarker.self).executableURL)
        try #require(FileManager.default.fileExists(atPath:
            executable.deletingLastPathComponent().appendingPathComponent("mlx.metallib").path),
            "stage the source-matched metallib before supervised execution")
        let path = URL(fileURLWithPath: job.modelPath)
        let promptContractID = try PromptContractIdentity.compute(modelDirectory: path)
        let hash = try #require(WeightHasher.computeHash(snapshotDir: path, modelID: job.modelID))
        #expect(hash == job.artifactSHA256, "verified serving artifact changed")
        guard hash == job.artifactSHA256 else { throw QualificationFailure.artifactMismatch }
        let preparation: SpecDecPreparation
        if requireInlineMTP {
            let artifact = try SpecDecStore.inspectInlineArtifact(directory: path).get()
            preparation = SpecDecPreparation(artifact: artifact, status: .candidate(artifact))
        } else {
            preparation = SpecDecPreparation(artifact: nil,
                status: .disabled(.configDisabled, configured: false))
        }
        let cap = UnifiedMemoryCap.hardCapBytes(physicalBytes: ProcessInfo.processInfo.physicalMemory)
        MLX.Memory.cacheLimit = Int(cap)
        MLX.Memory.memoryLimit = Int(cap)
        let container = try await ModelContainerLoading.loadContainer(from: path)
        let tokenizer = await container.perform { TokenizerHandle($0.tokenizer) }
        let isVLM = ProviderLoop.modelIsVLM(at: path)
        let prepared = try await EngineV2SlotFactory.prepareProductionModel(
            modelId: job.modelID, isVLM: isVLM, modelDirectory: path,
            container: container, specDecPreparation: preparation)
        var environment: [String: String] = [:]
        // Never read or populate the installed provider's SSD prefix-cache
        // namespace. The isolated encrypted test root exists only for this job.
        environment["DARKBLOOM_PREFIX_CACHE_TEST_ROOT"] = URL(fileURLWithPath: job.outputPath)
            .deletingLastPathComponent().appendingPathComponent("prefix-cache").path
        environment["DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL"] = "1"
        if let cap = job.mixedPrefillTokenCap {
            environment["DARKBLOOM_CBV2_MIXED_PREFILL_CAP"] = String(cap)
        }
        if !job.reused, job.servingPolicy != true { environment["DARKBLOOM_PREFIX_CACHE"] = "0" }
        let sizing = await SlotSizingSnapshot.build(
            container: container, modelPath: path, fallbackDefaultMaxTokens: job.outputTokens)
            .replacingAuxiliaryWeightBytes(prepared.assistantBytes)
        let grant = min(kvGrantUpperBound ?? .max, UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: ProcessInfo.processInfo.physicalMemory,
            residentWeightBytes: UInt64(max(0, sizing.weightsBytes)),
            activationReserveBytes: activationReserveBytes, configReserveBytes: 0))
        let budget = sharedBudget ?? GlobalKVCacheBudget()
        let bundle: ProviderEngineBundle
        do {
            bundle = try await EngineV2SlotFactory.makeProductionBundle(
                modelId: job.modelID, modelType: "qwen3_5", isVLM: isVLM,
                modelDirectory: path, container: container, tokenizer: tokenizer,
                sizing: sizing, kvBytesCapacity: Int(grant),
                maxConcurrentRequests: job.schedulerMaxConcurrentRequests ?? job.width,
                constructionPurpose: job.servingPolicy == true ? .serving : .benchmark,
                kvBudget: budget, activationReserveBytes: activationReserveBytes, kvBackendConfig: job.kvBackend,
                prefillDeadlineMode: .enforce, modelArtifactSHA256: hash, weightHash: hash,
                specDecPreparation: preparation, preparedModel: prepared,
                environment: environment, startServingTelemetry: false)
        } catch {
            prepared.assistant?.release()
            throw error
        }
        let automatic = MTPAutomaticVerificationPolicy.maxRectangularTokens(environment: environment)
        let verification = providerMTPVerificationPolicy(for: prepared.assistant?.drafter,
                                                        automaticRectangularTokens: automatic)
        let depth = MTPAutomaticVerificationPolicy.draftDepthPolicy(
            usesRequestStatefulDrafter: prepared.assistant?.drafter is any CBv2MTPRequestStatefulDrafter,
            modelID: job.modelID, hasBenchmarkVerificationOverride: false)
        let mtp = ServingMTPConfiguration.resolve(config: CBv2MTPConfig(
            enabled: prepared.assistant != nil, maxDraftTokens: depth.maximum,
            fixedDraftTokens: depth.fixed, verificationMode: verification.mode,
            maxAutomaticRectangularTokens: verification.automaticRectangularTokens), artifact: prepared.mtpArtifact)
        return ServingQualificationFixture(job: job, bundle: bundle, container: container,
            tokenizer: tokenizer, sizing: sizing,
            promptContractID: promptContractID, mtp: mtp, budget: budget, postureLease: postureLease)
    }

    func service(profile: RequestProfileBuilder, usage: EngineV2RequestUsageSignal,
                 promptWork: PromptWork? = nil) -> MLXOpenAIService {
        let entry = MultiModelBatchSchedulerEngine.ModelRegistryEntry(
            tokenizer: tokenizer, modelType: "qwen3_5", container: container,
            isVLM: true, engineV2Bridge: bundle.bridge)
        return MLXOpenAIService(engine: MultiModelBatchSchedulerEngine(
            registryProvider: { [entry, job] in [job.modelID: entry] },
            defaultMaxTokens: job.outputTokens, cacheScope: "dedicated-serving-qualification",
            cacheEnabled: job.reused || job.servingPolicy == true, engineV2Usage: usage,
            firstContentDeadline: FirstContentDeadline(
                relativeBudgetMilliseconds: Int64(job.firstContentBudgetMilliseconds ?? 3_600_000)),
            profile: profile, promptWork: promptWork))
    }

    func retire() async {
        defer { postureLease.finish() }
        await bundle.bridge.shutdown()
        bundle.releaseAssistant()
        MLX.Stream().synchronize()
        MLX.Memory.clearCache()
    }

    func waitForIdle() async throws -> CBv2CapacitySnapshot {
        for _ in 0..<200 {
            let snapshot = await bundle.bridge.capacitySnapshot()
            if snapshot.activeRequests == 0 && snapshot.waitingRequests == 0 && snapshot.activeTokens == 0 {
                return snapshot
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw QualificationFailure.retirementTimedOut
    }
}

private final class QualificationBundleMarker: NSObject {}
enum QualificationFailure: Error { case artifactMismatch, contextExceeded, unsupportedEngine, retirementTimedOut }
