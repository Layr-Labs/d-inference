import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import MLXVLM

enum GLM5NextExecutionBoundError: Error, Equatable, CustomStringConvertible {
    case missing
    case invalid(requested: Int, modelMaximum: Int)
    case backendMismatch(prepared: Int, backend: Int?)
    case requestExceedsLimit

    var description: String {
        switch self {
        case .missing:
            return "GLM MTP requires an explicit enforced maximum context"
        case .invalid(let requested, let modelMaximum):
            return
                "GLM context must be positive and within model maximum \(modelMaximum); requested \(requested)"
        case .backendMismatch(let prepared, let backend):
            return
                "GLM prepared context \(prepared) differs from backend context \(backend.map(String.init) ?? "missing")"
        case .requestExceedsLimit:
            return "GLM request exceeds its enforced context"
        }
    }
}

/// A caller-selected enforced context, never a replacement model configuration
/// or a smaller memory estimate for the original advertised context.
enum GLM5NextExecutionBound {
    static func require(_ requested: Int?, modelMaximum: Int) throws -> Int {
        guard let requested else { throw GLM5NextExecutionBoundError.missing }
        guard requested > 0, requested <= modelMaximum, requested <= Int(Int32.max) else {
            throw GLM5NextExecutionBoundError.invalid(
                requested: requested, modelMaximum: modelMaximum)
        }
        return requested
    }

    static func validateRequest(promptTokens: Int, maximumOutputTokens: Int, limit: Int) throws {
        guard promptTokens > 0, maximumOutputTokens >= 0, promptTokens <= limit,
            maximumOutputTokens <= limit - promptTokens
        else {
            throw GLM5NextExecutionBoundError.requestExceedsLimit
        }
    }

    static func validateBackend(_ config: PagedKVPoolConfig, prepared: Int) throws {
        guard prepared > 0, config.nominalMaxSequenceLength == prepared,
            config.gatheredAttention?.maximumContextTokens == prepared,
            config.maxPrefillChunk > 0, config.maxPrefillChunk <= prepared,
            let maximumQuery = config.gatheredAttention?.maximumQueryTokens,
            maximumQuery > 0, maximumQuery <= prepared
        else {
            throw GLM5NextExecutionBoundError.backendMismatch(
                prepared: prepared,
                backend: config.gatheredAttention?.maximumContextTokens)
        }
    }
}

/// A real trained assistant and its source root. This is a load/engine owner,
/// never a request-state map. Only the SDK's admitted factory creates histories.
final class GLM5NextProtectedModel: Module, LanguageModel, CBv2CompleteCheckpointKVTypeProviding {
    let root: GLM5NextModel
    let execution: GLM5NextMTPExecution
    let assistant: GLM5NextMTPAdapter
    let maximumContextLength: Int

    var cbv2CompleteCheckpointKVDTypes: [DType]? { root.textTower.cbv2CompleteCheckpointKVDTypes }

    /// Rectangular MTP verification is the GLM default: one captured target
    /// forward verifies up to three index-shared proposals, with an adaptive
    /// depth. Its greedy output is not token-identical to target-only decode
    /// (multi-token verify arithmetic can flip near-ties). Exact `0` / `false`
    /// / `no` / `off` selects the serial single-proposal profile instead.
    static let rectangularVerifyEnvironmentKey = "DARKBLOOM_GLM_RECTANGULAR_VERIFY"
    static let rectangularDepth = 3

    static func verification(
        configuration: GLM5NextTextConfiguration, environment: [String: String]
    ) -> GLM5NextMTPVerification {
        guard MiMoV26DecodeDefaults.isEnabled(rectangularVerifyEnvironmentKey, environment: environment)
        else { return .serialTarget }
        // Proposals beyond the first reuse step 0's sparse selection, which the
        // checkpoint must declare; otherwise one rectangular proposal.
        return .rectangular(
            depth: configuration.indexShareForMTPIteration ? rectangularDepth : 1)
    }

    /// Resolve before fingerprinting the SSD namespace as well as before engine
    /// assembly. The identity must describe the actual issued profile: serial
    /// depth one, or rectangular up to its depth with an adaptive controller.
    func resolvedMTPConfiguration(_ config: CBv2MTPConfig, drafter: (any CBv2MTPDrafter)?) throws
        -> CBv2MTPConfig
    {
        guard (drafter as? GLM5NextMTPAdapter) === assistant, config.effectiveEnabled,
            [.serialTarget, .rectangular].contains(config.verificationMode)
        else {
            throw EngineV2ProductionError.pagedUnavailable("GLM protected execution tuple changed")
        }
        var config = config
        config.maxSpeculativeBatch = 1
        config.verificationMode = execution.verification.engineMode
        switch execution.verification {
        case .serialTarget:
            config.maxDraftTokens = min(1, config.maxDraftTokens)
            // The serial profile has no adaptive top-two policy capability. Use
            // its genuine single-proposal profile rather than passing nil into
            // the recurrent adaptive-driver eligibility gate.
            config.fixedDraftTokens = min(1, config.fixedDraftTokens ?? 1)
        case .rectangular(let depth):
            config.maxDraftTokens = depth
            // nil keeps the engine's measured marginal-cost depth controller.
            config.fixedDraftTokens = config.fixedDraftTokens.map { min(max($0, 1), depth) }
        }
        return config
    }

    init(
        root: GLM5NextModel, maximumContextLength: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        guard let predictor = root.mtp else {
            throw GLM5NextManagedLoadError.metadata("trained MTP is not loaded")
        }
        let bound = try GLM5NextExecutionBound.require(
            maximumContextLength,
            modelMaximum: root.configuration.textConfig.maxPositionEmbeddings)
        self.root = root
        self.maximumContextLength = bound
        execution = try GLM5NextMTPExecution(
            target: root.textTower, predictor: predictor,
            maximumInputs: bound, storage: .contiguous,
            verification: Self.verification(
                configuration: root.configuration.textConfig, environment: environment))
        assistant = try GLM5NextMTPAdapter(
            target: root.textTower, predictor: predictor, factory: execution)
        super.init()
    }

    func prepare(_ input: LMInput, cache: [any KVCache], windowSize: Int?) throws -> PrepareResult {
        try requireInput(input.text.tokens, cache: cache)
        return try root.prepare(input, cache: cache, windowSize: windowSize)
    }
    func newCache(parameters: GenerateParameters?) -> [any KVCache] {
        root.newCache(parameters: parameters)
    }
    /// The non-throwing LanguageModel step entry points have no provider caller:
    /// serving runs only through the issued native steppable, whose admission
    /// enforces the bound. They never touch the MTP execution sized to that
    /// bound, so they delegate unchanged instead of adding a process abort.
    func callAsFunction(_ inputs: MLXArray, cache: [any KVCache]?) -> MLXArray {
        root(inputs, cache: cache)
    }
    func callAsFunction(_ input: LMInput.Text, cache: [any KVCache]?, state: LMOutput.State?)
        -> LMOutput
    {
        root(input, cache: cache, state: state)
    }

    private func requireInput(_ tokens: MLXArray, cache: [any KVCache]) throws {
        guard tokens.ndim == 2 else { throw GLM5NextExecutionBoundError.requestExceedsLimit }
        let offset = cache.map(\.offset).max() ?? 0
        guard offset >= 0, offset <= maximumContextLength else {
            throw GLM5NextExecutionBoundError.requestExceedsLimit
        }
        try GLM5NextExecutionBound.validateRequest(
            promptTokens: tokens.dim(1),
            maximumOutputTokens: offset, limit: maximumContextLength)
    }
}

/// Keep the actual SDK construction scope reachable if a fence fails. A
/// successful preparation has no request or slab allocation yet; EngineV2
/// binds this exact process owner before its first native allocation.
final class GLM5NextProtectedResources {
    let scope: NativeConstructionScope
    let budget: GlobalKVCacheBudget
    let processOwner: EngineProcessMemoryOwner
    let resources: GLM5NextMTPExecution.NativeResources

    init(
        model: GLM5NextProtectedModel, config: PagedKVPoolConfig,
        budget: GlobalKVCacheBudget, completePrefixCache: (any CBv2CompletePrefixCache)? = nil
    ) throws {
        let store = try Self.checkedStore(completePrefixCache, budget: budget)
        try GLM5NextExecutionBound.validateBackend(config, prepared: model.maximumContextLength)
        guard model.execution.maximumInputs == model.maximumContextLength else {
            throw GLM5NextExecutionBoundError.backendMismatch(
                prepared: model.maximumContextLength,
                backend: config.gatheredAttention?.maximumContextTokens)
        }
        try GLM5NextRetainedConstruction.requireHealthy()
        let scope = NativeConstructionScope()
        let processOwner = budget.makeEngineMemoryOwner()
        self.scope = scope
        self.budget = budget
        self.processOwner = processOwner
        do {
            resources = try model.execution.makeNativeResources(
                assistant: model.assistant,
                config: config, processMemoryOwner: processOwner, construction: scope,
                completePrefixCache: store, mediaOwner: model.root)
        } catch {
            // The scope itself retains every native root on failed completion.
            if scope.snapshot.isRetainedFault { GLM5NextRetainedConstruction.keep(scope) }
            throw error
        }
    }

    /// A profile name never authorizes a substitute store, including one with
    /// identical durable identity. The SDK tuple owns this exact object.
    func validateBinding(completePrefixCache: (any CBv2CompletePrefixCache)?) throws {
        let store = try Self.checkedStore(completePrefixCache, budget: budget)
        let strategy = resources.assistant.verification == .serialTarget ? "serial" : "rectangular"
        let profile =
            store == nil
            ? "glm5_next_native_paged_\(strategy)_mtp_v1"
            : "glm5_next_native_paged_full_state_\(strategy)_mtp_v1"
        guard resources.completePrefixCache === store,
            resources.processMemoryOwner === processOwner,
            resources.contract.profile == profile,
            resources.contract.supportsNativeCompletePrefix == (store != nil)
        else {
            throw EngineV2ProductionError.pagedUnavailable(
                "GLM protected prefix tuple changed: exact_store=\(resources.completePrefixCache === store), "
                    + "exact_process_owner=\(resources.processMemoryOwner === processOwner), "
                    + "issued_profile=\(resources.contract.profile), expected_profile=\(profile)")
        }
    }

    private static func checkedStore(
        _ cache: (any CBv2CompletePrefixCache)?, budget: GlobalKVCacheBudget
    ) throws -> SSDHybridCheckpointStore? {
        guard let cache else { return nil }
        guard let store = cache as? SSDHybridCheckpointStore,
            store.kvBudget === budget, !store.isClosed,
            [
                store.identity.modelAggregateHash, store.identity.promptContractID,
                store.identity.buildID, store.identity.numericsFingerprint,
            ].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }),
            store.config.backendLayout == CBv2CompleteCheckpointManifest.glm5NextPagedLayout
        else {
            throw EngineV2ProductionError.pagedUnavailable(
                "GLM requires its budget-bound encrypted full-state store")
        }
        return store
    }
}

private enum GLM5NextRetainedConstruction {
    static let lock = NSLock()
    nonisolated(unsafe) static var scopes: [NativeConstructionScope] = []
    static func keep(_ scope: NativeConstructionScope) {
        lock.withLock { scopes.append(scope) }
        GLM5NextLoadFaultState.retain([scope])
    }
    static func requireHealthy() throws {
        try lock.withLock {
            guard scopes.isEmpty else { throw GLM5NextManagedLoadError.retirementUnproven }
        }
    }
}
