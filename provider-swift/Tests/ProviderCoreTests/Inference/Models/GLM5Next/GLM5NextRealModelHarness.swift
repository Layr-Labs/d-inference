import CryptoKit
import Darwin
import Foundation
import MLX
import MLXLMCommon
import MLXLMServer
import ProviderCoreFoundation
import Testing

@_spi(Benchmarking) @testable import ProviderCore

/// Test-owned assembly only: the real managed loader, production grant and slot
/// factory remain authoritative. Never uses a synthetic memory snapshot.
///
/// GLM serves only with its embedded MTP owner (target-only GLM has no native
/// completion receipt and is refused by production), so every real cell runs
/// with the MTP process gate and the inline assistant enabled.
final class GLM5NextRealModelHarness: @unchecked Sendable {
    static let templateSHA256 = "46b2e2137e2759355b3e0e3e90cf4bd172b568437a75588af5c457cc8c095b2e"
    static let servedModelID = "glm5-qualification"
    let environment = ProcessInfo.processInfo.environment
    let root: URL
    let directory: URL
    let localPlan: GLM5NextServingPlan
    var plan: GLM5NextArtifactPlan { localPlan.plan }
    let maximumContext: Int
    let budget: GlobalKVCacheBudget
    var container: ModelContainer?
    var session: EngineV2BenchmarkSession?
    var loadSeconds: Double = 0
    var memoryAfterLoad: [String: Any] = [:]
    var checkpointStore: SSDHybridCheckpointStore? { bundle?.bridge.ssdHybridCheckpointStore }
    private(set) var bundle: ProviderEngineBundle?
    private var tokenizer: TokenizerHandle?
    private var oldCache: String?
    private var cacheConfigured = false
    private var retirementUnproven = false

    init() throws {
        let env = ProcessInfo.processInfo.environment
        directory = URL(fileURLWithPath: try #require(env["DARKBLOOM_TEST_GLM5_REAL_MODEL_DIR"]))
        let reportRoot = URL(fileURLWithPath: try #require(env["DARKBLOOM_TEST_GLM5_REAL_RESULTS_DIR"]))
        root = reportRoot.appendingPathComponent("isolated-\(UUID())", isDirectory: true)
        let repo = try #require(env["DARKBLOOM_TEST_GLM5_REAL_SOURCE_REPO"])
        let revision = try #require(env["DARKBLOOM_TEST_GLM5_REAL_SOURCE_REVISION"])
        try #require(repo == GLM5NextLocalQualification.modelID)
        try #require(revision.count == 40 && revision.allSatisfy { $0.isHexDigit })
        // The same operator selection file and resolver as local serving
        // (DARKBLOOM_EXPERIMENTAL_GLM5_NEXT); the test only cross-checks that
        // the selection binds the independently supplied identity.
        let selection = try GLM5NextLocalQualification.selection(environment: env)
        let source = try #require(selection.catalog.huggingFaceArtifact)
        try #require(source.repoID == repo && source.revision == revision)
        let expectedAggregate = try #require(env["DARKBLOOM_TEST_GLM5_REAL_AGGREGATE_SHA256"])
        try #require(selection.expectedAggregateSHA256 == expectedAggregate)
        try #require(selection.maximumContextLength != nil, "the qualification context bound must be explicit")
        localPlan = try GLM5NextLocalQualification.resolveLocalPlan(modelID: repo, directory: directory,
            environment: env)
        maximumContext = localPlan.maximumContextLength
        try #require(Self.hash(try Data(contentsOf: directory.appendingPathComponent("chat_template.jinja")))
            == Self.templateSHA256, "only the explicitly reviewed bracket-index template is admitted")
        try #require(maximumContext > 0)
        let reserve = MLXMemoryGuard.defaultReserveGB * (1 << 30)
        budget = GlobalKVCacheBudget(
            capFraction: UnifiedMemoryCap.resolvedCapFraction(explicit: nil, env: env),
            activationReserveBytes: UnifiedMemoryCap.resolvedActivationReserveBytes(env: env,
                modelIDs: [repo]), configReserveBytes: reserve)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    func load(concurrency: Int = 1, ssd: Bool = false) async throws {
        try #require(container == nil && session == nil)
        try #require((1...4).contains(concurrency))
        try #require(CBv2MTPConfig.envEnabled, "GLM serves only with its native MTP owner; set DARKBLOOM_CBV2_MTP=1")
        oldCache = ModelScanner.configuredCacheDirectory
        cacheConfigured = true
        ModelScanner.configureCacheDirectory(root.appendingPathComponent("hub").path)
        var env = environment
        env["DARKBLOOM_PREFIX_CACHE"] = ssd ? "1" : "0"
        env["DARKBLOOM_PREFIX_CACHE_MEMORY"] = "0"
        env["DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL"] = "1"
        env["DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY"] = "0"
        env["DARKBLOOM_PREFIX_CACHE_TEST_ROOT"] = root.appendingPathComponent("ssd").path
        env["DARKBLOOM_PREFIX_CACHE_DISK_GB"] = "4"
        env["DARKBLOOM_CBV2_SOLO_PREFILL_STRIPE"] = "0"
        _ = try GPUEnforcement.requireMetal()
        MLXMemoryGuard.configureOnce()
        let start = DispatchTime.now().uptimeNanoseconds
        let admission = budget.memoryHeadroomSnapshot()
        // Written before any throwing load step, so an admission refusal
        // still leaves its exact claim inputs on disk.
        var admissionRecord: [String: Any] = [
            "capFraction": UnifiedMemoryCap.resolvedCapFraction(explicit: nil, env: env),
            "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
            "capBytes": admission.capBytes, "loadReserveBytes": budget.loadReserveBytes,
            "policyReserveBytes": admission.activationReserveBytes,
            "systemAvailableBytes": admission.systemAvailableBytes, "mlxActiveBytes": admission.activeBytes,
            "mlxCacheBytes": admission.cacheBytes, "runtimeRemainingBytes": admission.runtimeRemainingBytes,
            "requiredWeightBytes": plan.quotation.requiredWeightBytes,
            "requiredToLoadGiB": plan.quotation.requiredToLoadGb(activationReserveBytes: admission.activationReserveBytes),
            "availableForLoadGiB": budget.availableForLoadGb(), "outcome": "claiming"]
        try write("admission", admissionRecord)
        let load: GLM5NextManagedLoad
        do { load = try await GLM5NextManagedLoad.claim(plan: plan, budget: budget) } catch {
            admissionRecord["outcome"] = "refused"
            admissionRecord["error"] = String(describing: error)
            try write("admission", admissionRecord)
            throw error
        }
        admissionRecord["outcome"] = "claimed"
        try write("admission", admissionRecord)
        container = try #require(try await load.load().autoregressive)
        let container = try #require(container)
        let weightsSeconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        let sizing = try localPlan.boundedSizing(
            await GLM5NextLoadFunnel.sizing(container: container, defaultMaxTokens: 1024))
        try #require(sizing.maxContextLength == maximumContext)
        let reserve = UnifiedMemoryCap.resolvedActivationReserveBytes(env: env,
            modelIDs: [plan.weights.catalog.id])
        try #require(KVHeadroomProbe.hasServeableKVHeadroom(activationReserveBytes: reserve))
        let grant = try EngineV2Factory.benchmarkProductionGrant(modelId: plan.weights.catalog.id,
            sizing: sizing, environment: env,
            operatorReserveBytes: MLXMemoryGuard.defaultReserveGB * (1 << 30))
        let preparation = try await EngineV2SlotFactory.glm5NextInlinePreparation(container: container, enabled: true)
        try GLM5NextLoadFunnel.requireNativeMTP(preparation)
        let tokenizer = await container.perform { TokenizerHandle($0.tokenizer) }
        self.tokenizer = tokenizer
        do {
            bundle = try await EngineV2SlotFactory.makeProductionBundle(modelId: plan.weights.catalog.id,
                modelType: "glm5_next", isVLM: true, modelDirectory: directory,
                container: container, tokenizer: tokenizer, sizing: sizing,
                kvBytesCapacity: grant.grantBytes, maxConcurrentRequests: concurrency, constructionPurpose: .benchmark,
                kvBudget: budget, activationReserveBytes: reserve, kvBackendConfig: "paged",
                kvQuantizationConfig: "native", checkpointQuantizationConfig: "native",
                modelArtifactSHA256: plan.weights.manifest.aggregateSHA256,
                weightHash: ssd ? plan.weights.manifest.aggregateSHA256 : nil,
                specDecPreparation: preparation, environment: env, startServingTelemetry: false)
        } catch {
            admissionRecord["outcome"] = "engine_construction_failed"
            admissionRecord["error"] = String(describing: (error as? GLM5NextNativeConstructionFailure)?.cause ?? error)
            admissionRecord["constructionDiagnostics"] = Self.constructionDiagnostics(error)
            admissionRecord["preparation"] = String(describing: preparation.status)
            try? write("admission", admissionRecord)
            throw error
        }
        let bundle = try #require(bundle)
        // The production publication condition: MTP active end to end and the
        // bridge holds the acknowledged native retirement owner.
        try #require(await GLM5NextLoadFunnel.servesWithNativeOwner(bundle),
            "GLM must publish only with an active MTP native owner")
        let engine = try #require(await bundle.bridge.ownedEngine as? EngineV2)
        let sample = budget.memoryHeadroomSnapshot()
        try #require(KVHeadroomProbe.postBuildServeable(kvBackendKind: .paged,
            pagedPoolBytes: await bundle.bridge.kvBackendPoolBytes(), activationReserveBytes: reserve,
            measuredHeadroomBytes: sample.runtimeRemainingBytes))
        session = EngineV2BenchmarkSession(bundle: bundle, engine: engine, backend: "paged", fallback: nil,
            effectiveMaxConcurrentRequests: concurrency, memoryEnabled: false, activationReserveBytes: reserve,
            postLoadMaximumKVBytes: sample.runtimeRemainingBytes, budget: budget, assistantIdentity: [:],
            productionGrant: grant, postBuildHeadroomBytes: sample.runtimeRemainingBytes)
        loadSeconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        try plan.weights.recheck()
        memoryAfterLoad = Self.residentMemory()
        memoryAfterLoad["weightsLoadSeconds"] = weightsSeconds
        memoryAfterLoad["kvGrantBytes"] = grant.grantBytes
        memoryAfterLoad["pagedPoolBytes"] = await bundle.bridge.kvBackendPoolBytes()
        admissionRecord["outcome"] = "served"
        admissionRecord["loadSeconds"] = loadSeconds
        admissionRecord["memoryAfterLoad"] = memoryAfterLoad
        try write("admission", admissionRecord)
    }

    func close() async throws {
        guard !retirementUnproven else {
            GLM5NextLoadFaultState.retain([self])
            throw GLM5NextManagedLoadError.retirementUnproven
        }
        do {
            if let session { try await session.shutdownReportingCompletion() }
            else if let bundle { try await GLM5NextRetirement.beforeRelease(bundle.bridge); bundle.releaseAssistant() }
            if let container { await ModelContainerLoading.releaseExternalResources(in: container) }
        } catch {
            GLM5NextLoadFaultState.retain([self])
            throw error
        }
        session = nil
        bundle = nil
        container = nil
        if cacheConfigured { ModelScanner.configureCacheDirectory(oldCache) }
        if !GLM5NextLoadFaultState.isRetained { try FileManager.default.removeItem(at: root) }
    }

    static func withLoaded(concurrency: Int = 1, ssd: Bool = false,
        _ body: (GLM5NextRealModelHarness) async throws -> Void) async throws {
        let harness = try Self()
        let result: Result<Void, any Error>
        do { try await harness.load(concurrency: concurrency, ssd: ssd)
            try await body(harness); result = .success(()) }
        catch {
            let failure = await GLM5NextRetirement.validatedFailure(error, retaining: [harness])
            harness.retirementUnproven = GLM5NextLoadFunnel.isUnproven(failure)
            result = .failure(failure)
        }
        try await harness.close()
        try result.get()
    }

    /// Provider prompt contract: the same body decoding, GLM prompt policy and
    /// template rendering as a served chat request.
    func prompt(_ text: String, effort: String? = "low") async throws -> [Int] {
        var body: [String: Any] = ["model": Self.servedModelID,
            "messages": [["role": "user", "content": text]]]
        if let effort { body["reasoning_effort"] = effort }
        return try await tokenize(body: JSONSerialization.data(withJSONObject: body))
    }

    func tokenize(body: Data) async throws -> [Int] {
        let container = try #require(container)
        return try await container.perform { context in
            try ProviderPromptContractPipeline.tokenizeProviderBody(body,
                tokenizer: context.tokenizer, modelType: "glm5_next")
        }
    }

    func decode(_ tokens: [Int]) async throws -> String {
        try #require(tokenizer).inner.decode(tokenIds: tokens, skipSpecialTokens: false)
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func tokenHash(_ tokens: [Int]) -> String {
        hash(Data(tokens.map(String.init).joined(separator: ",").utf8))
    }
    static func json<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed)
    }
    func write(_ name: String, _ value: [String: Any]) throws {
        let path = URL(fileURLWithPath: try #require(environment["DARKBLOOM_TEST_GLM5_REAL_RESULTS_DIR"]))
            .appendingPathComponent(name + ".json")
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: path, options: .atomic)
    }

    /// Read-only diagnosis of a refused protected construction: which of the
    /// tuple conditions the unpublished engine failed. Reflection only; the
    /// owner's binding stays private to production code.
    static func constructionDiagnostics(_ error: any Error) -> [String: Any] {
        guard let failure = error as? GLM5NextNativeConstructionFailure else { return ["owner": "none"] }
        func child(_ value: Any, _ label: String) -> Any? {
            var mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .optional, let some = mirror.children.first?.value {
                mirror = Mirror(reflecting: some)
            }
            return mirror.children.first { $0.label == label }?.value
        }
        guard let binding = child(failure.owner, "binding"), let engine = child(binding, "engine") as? EngineV2 else {
            return ["owner": "present", "engine": "unreachable"]
        }
        return ["mtpInactiveReason": engine.mtpInactiveReason ?? NSNull(),
            "pagedAttentionWorkInactiveReason": engine.pagedAttentionWorkInactiveReason ?? NSNull(),
            "nativeCompletionFault": engine.nativeCompletionFault.map { String(describing: $0) } ?? NSNull(),
            "resolvedMTPAdmission": String(describing: engine.resolvedMTPAdmission)]
    }

    /// Process-resident and MLX allocator view. `physFootprintBytes` is the
    /// kernel's per-process accounting (what Activity Monitor reports).
    static func residentMemory() -> [String: Any] {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        var value: [String: Any] = ["mlxActiveBytes": Memory.activeMemory, "mlxCacheBytes": Memory.cacheMemory,
            "mlxPeakBytes": Memory.peakMemory, "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory]
        if status == KERN_SUCCESS {
            value["physFootprintBytes"] = info.phys_footprint
            value["residentBytes"] = info.resident_size
        }
        return value
    }
}

struct GLM5NextRealRun: Sendable {
    let tokens: [Int]
    let text: String
    let reason: CBv2FinishReason?
    let usage: CBv2Usage?
    let ttftSeconds: Double?
    let lastDeltaSeconds: Double?
    let finishedSeconds: Double?
    let wallSeconds: Double
    let stageDisposition: String
    let stopTokens: Set<Int>
    let mtp: GLM5NextRealMTPDelta?
}

struct GLM5NextRealMTPDelta: Sendable {
    let rounds: Int
    let serialVerificationRounds: Int
    let proposed: Int
    let accepted: Int
    let emitted: Int
    var acceptance: Double { proposed > 0 ? Double(accepted) / Double(proposed) : 0 }
    var record: [String: Any] {
        ["rounds": rounds, "serialVerificationRounds": serialVerificationRounds, "proposed": proposed,
         "accepted": accepted, "emitted": emitted, "acceptance": acceptance,
         "meanAcceptedPerRound": rounds > 0 ? Double(accepted) / Double(rounds) : 0]
    }
}

extension GLM5NextRealModelHarness {
    /// Raw engine request. Stop tokens are the production EOS set unless the
    /// caller explicitly asks for a fixed-length probe. The MTP delta is only
    /// attributable when no other request overlaps (`attributeMTP`).
    func run(_ prompt: [Int], id: UInt64, output: Int, cache: Bool = false,
        cancelAfterFirst: Bool = false, multimodal: CBv2MultimodalInput? = nil,
        suppressEOS: Bool = false, attributeMTP: Bool = true) async throws -> GLM5NextRealRun {
        let session = try #require(session)
        try GLM5NextExecutionBound.validateRequest(promptTokens: prompt.count,
            maximumOutputTokens: output, limit: maximumContext)
        var stopTokens = Set<Int>()
        if !suppressEOS {
            stopTokens = await session.stopTokenIDs()
            try #require(!stopTokens.isEmpty, "production EOS set must be resolved")
        }
        let before = attributeMTP ? session.rawEngine.mtpMetricsSnapshot() : nil
        let start = DispatchTime.now().uptimeNanoseconds
        let submission = try await session.submit(.init(id: .init(id), promptTokens: prompt,
            sampling: .init(temperature: 0), maxTokens: output, stopTokens: stopTokens,
            cacheSalt: cache ? "isolated-real-model-tenant" : nil, prefixCacheEnabled: cache,
            multimodal: multimodal, prefixCheckpointTargetTokens: cache ? 1024 : nil))
        var tokens: [Int] = [], text = ""
        var first: UInt64?, last: UInt64?, finished: UInt64?
        var reason: CBv2FinishReason?, usage: CBv2Usage?
        for await event in submission.events {
            switch event {
            case .delta(let delta, let ids, _):
                if first == nil { first = DispatchTime.now().uptimeNanoseconds }
                last = DispatchTime.now().uptimeNanoseconds
                tokens += ids; text += delta
                if cancelAfterFirst { session.rawEngine.cancel(.init(id)) }
            case .finished(let terminal, let count):
                finished = DispatchTime.now().uptimeNanoseconds
                reason = terminal; usage = count
            }
        }
        let end = DispatchTime.now().uptimeNanoseconds
        await session.complete(receiptID: submission.receiptID)
        var delta: GLM5NextRealMTPDelta?
        if let before, let after = session.rawEngine.mtpMetricsSnapshot() {
            delta = .init(rounds: Int(after.rounds - before.rounds),
                serialVerificationRounds: Int(after.serialVerificationRounds - before.serialVerificationRounds),
                proposed: Int(after.draftedTokens - before.draftedTokens),
                accepted: Int(after.acceptedTokens - before.acceptedTokens),
                emitted: Int(after.emittedTokens - before.emittedTokens))
        }
        return .init(tokens: tokens, text: text, reason: reason, usage: usage,
            ttftSeconds: first.map { Double($0 - start) / 1e9 },
            lastDeltaSeconds: last.map { Double($0 - start) / 1e9 },
            finishedSeconds: finished.map { Double($0 - start) / 1e9 },
            wallSeconds: Double(end - start) / 1e9,
            stageDisposition: submission.stageDisposition, stopTokens: stopTokens, mtp: delta)
    }
}

/// Served chat contract: OpenAI body → production decode, GLM prompt policy,
/// MultiModelBatchSchedulerEngine (tool handler, reasoning prefix, media
/// routing) → the real EngineV2 bridge → MLXOpenAIService response assembly,
/// with the reasoning parser selected exactly as ProviderLoop selects it.
struct GLM5NextRealChatOutcome: @unchecked Sendable {
    let body: [String: Any]
    let response: [String: Any]?
    let error: String?
    let wallSeconds: Double

    private var choice: [String: Any]? { (response?["choices"] as? [[String: Any]])?.first }
    private var message: [String: Any]? { choice?["message"] as? [String: Any] }
    var finishReason: String? { choice?["finish_reason"] as? String }
    var content: String { message?["content"] as? String ?? "" }
    var reasoning: String? { message?["reasoning_content"] as? String }
    var toolCalls: [[String: Any]] { message?["tool_calls"] as? [[String: Any]] ?? [] }
    var completionTokens: Int? { (response?["usage"] as? [String: Any])?["completion_tokens"] as? Int }

    var record: [String: Any] {
        ["finishReason": finishReason ?? NSNull(), "content": content, "reasoningContent": reasoning ?? NSNull(),
         "toolCalls": toolCalls, "completionTokens": completionTokens ?? NSNull(),
         "error": error ?? NSNull(), "wallSeconds": wallSeconds]
    }
}

extension GLM5NextRealModelHarness {
    func chat(_ body: [String: Any]) async throws -> GLM5NextRealChatOutcome {
        let bundle = try #require(bundle)
        let container = try #require(container)
        let tokenizer = try #require(tokenizer)
        let data = try JSONSerialization.data(withJSONObject: body)
        let entry = MultiModelBatchSchedulerEngine.ModelRegistryEntry(tokenizer: tokenizer,
            modelType: "glm5_next", container: container, isVLM: true, engineV2Bridge: bundle.bridge)
        let engine = MultiModelBatchSchedulerEngine(
            registryProvider: { [Self.servedModelID: entry] },
            defaultMaxTokens: ProviderLoop.schedulerDefaultMaxTokens,
            templateControls: ProviderLoop.extractChatTemplateControls(from: data),
            cacheEnabled: false)
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            var request = try ProviderLoop.decodeOpenAIRequest(data, modelType: "glm5_next")
            if request.reasoningParser == nil {
                request.reasoningParser = ProviderLoop.inferReasoningParser(for: "glm5_next")
            }
            let response = try await MLXOpenAIService(engine: engine).createChatCompletion(request: request)
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any]
            return .init(body: body, response: object, error: nil,
                wallSeconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        } catch {
            return .init(body: body, response: nil, error: String(describing: error),
                wallSeconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        }
    }
}
