import Foundation
import MLX
import MLXLLM
import MLXLMCommon
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
final class GLM5NextProtectedModel: Module, LanguageModel {
    let root: GLM5NextModel
    let execution: GLM5NextMTPExecution
    let assistant: GLM5NextMTPAdapter
    let maximumContextLength: Int

    init(root: GLM5NextModel, maximumContextLength: Int) throws {
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
            maximumInputs: bound, storage: .contiguous
        )
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
    func callAsFunction(_ inputs: MLXArray, cache: [any KVCache]?) -> MLXArray {
        precondition(
            (try? requireInput(inputs, cache: cache ?? [])) != nil,
            "GLM protected forward exceeds its enforced context")
        return root(inputs, cache: cache)
    }
    func callAsFunction(_ input: LMInput.Text, cache: [any KVCache]?, state: LMOutput.State?)
        -> LMOutput
    {
        precondition(
            (try? requireInput(input.tokens, cache: cache ?? [])) != nil,
            "GLM protected forward exceeds its enforced context")
        return root(input, cache: cache, state: state)
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
        budget: GlobalKVCacheBudget
    ) throws {
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
                config: config, processMemoryOwner: processOwner, construction: scope)
        } catch {
            // The scope itself retains every native root on failed completion.
            if scope.snapshot.isRetainedFault { GLM5NextRetainedConstruction.keep(scope) }
            throw error
        }
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
