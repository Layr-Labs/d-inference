import Foundation
import Logging
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import ProviderCoreFoundation

/// Wall-clock phases of one successful managed GLM load.
struct GLM5NextLoadPhases: Equatable, Sendable {
    /// SHA-256 of the manifest files outside the native core set.
    var auxiliaryVerification: Duration = .zero
    /// The native reader's SHA-256 of every core file, then header indexing.
    var coreVerification: Duration = .zero
    /// Tensor payload reads, model construction and the final evaluation fence.
    var construction: Duration = .zero
    var total: Duration = .zero
}

/// One admitted construction, not a serving capability. The normal provider
/// caller may bind its existing pending-load generation; isolated qualification
/// can claim the same real budget API instead. Neither path manufactures credit.
actor GLM5NextManagedLoad {
    /// Every provider GLM target, and the embedded MTP layer that inherits it,
    /// uses this one policy. The reference KDA/selection graphs grow per token
    /// and exceed MLX's Metal resource limit at real prompt lengths.
    static let executionPolicy = GLM5NextExecutionPolicy.serving
    private static let logger = Logger(label: "darkbloom.GLM5NextLoad")

    nonisolated let plan: GLM5NextArtifactPlan
    private let budget: GlobalKVCacheBudget
    private let permit: PendingModelLoadLease
    private let ownsPermit: Bool
    private var started = false
    private var finished = false
    private var artifactOwnership: GLM5NextArtifactOwnership?
    private let ownsArtifactOwnership: Bool
    private var activity: WholeMacUnboundedActivity?
    private let hooks: GLM5NextLoadHooks?
    private var constructionOwner: GLM5NextConstructionOwner?
    /// The manifest aggregate, set only once this load has SHA-256-verified
    /// every manifest file against the catalog-pinned manifest (core files in
    /// the native reader before any payload is parsed, the rest before the
    /// tokenizer loads) and the snapshot's file identities stayed unchanged
    /// through construction. `WeightHasher` reports this same value for these
    /// files, so callers publish it rather than reading the weights again.
    private(set) var verifiedArtifactSHA256: String?
    private(set) var phases: GLM5NextLoadPhases?

    private init(
        plan: GLM5NextArtifactPlan, budget: GlobalKVCacheBudget,
        permit: PendingModelLoadLease, ownsPermit: Bool,
        artifactOwnership: GLM5NextArtifactOwnership? = nil, hooks: GLM5NextLoadHooks? = nil
    ) {
        self.plan = plan
        self.budget = budget
        self.permit = permit
        self.ownsPermit = ownsPermit
        self.artifactOwnership = artifactOwnership
        self.ownsArtifactOwnership = artifactOwnership == nil
        self.hooks = hooks
    }

    /// Existing provider LOAD funnel: the caller remains responsible for the
    /// permit through engine construction/publication and all failed-load unwind.
    static func adopting(
        plan: GLM5NextArtifactPlan, budget: GlobalKVCacheBudget,
        permit: PendingModelLoadLease, artifactOwnership: GLM5NextArtifactOwnership? = nil,
        hooks: GLM5NextLoadHooks? = nil
    ) async throws -> GLM5NextManagedLoad {
        try GLM5NextLoadFaultState.requireHealthy()
        try await GLM5NextUnretiredLoads.shared.requireHealthy()
        guard
            await budget.validateGLM5NextPendingLoad(
                permit, modelID: plan.weights.catalog.id,
                quotation: plan.quotation)
        else { throw GLM5NextManagedLoadError.admission }
        try plan.weights.recheck()
        try Task.checkCancellation()
        return .init(
            plan: plan, budget: budget, permit: permit, ownsPermit: false,
            artifactOwnership: artifactOwnership, hooks: hooks)
    }

    /// On-demand isolated loader. The supplied budget must be the actual owner
    /// used by the resulting engine; this method never creates another ledger.
    static func claim(
        plan: GLM5NextArtifactPlan, budget: GlobalKVCacheBudget, hooks: GLM5NextLoadHooks? = nil
    ) async throws
        -> GLM5NextManagedLoad
    {
        try GLM5NextLoadFaultState.requireHealthy()
        try await GLM5NextUnretiredLoads.shared.requireHealthy()
        try Task.checkCancellation()
        let sample = budget.memoryHeadroomSnapshot()
        guard sample.activationReserveBytes >= UnifiedMemoryCap.defaultActivationReserveBytes,
            plan.quotation.requiredToLoadGb(activationReserveBytes: sample.activationReserveBytes)
                <= budget.availableForLoadGb(),
            let permit = await budget.claimPendingLoad(
                requestID: "pending-load:\(plan.weights.catalog.id)",
                weightBytes: plan.quotation.requiredWeightBytes)
        else {
            throw GLM5NextManagedLoadError.admission
        }
        do {
            try Task.checkCancellation()
            try plan.weights.recheck()
            return .init(plan: plan, budget: budget, permit: permit, ownsPermit: true, hooks: hooks)
        } catch {
            await budget.finishPendingLoad(permit)
            throw error
        }
    }

    func load(loadMTP: Bool = true) async throws -> ProviderModelContainer {
        try GLM5NextLoadFaultState.requireHealthy()
        guard !started, !finished else { throw GLM5NextManagedLoadError.lifecycle }
        started = true
        activity = budget.serviceBudget.beginUnboundedActivity()
        var loaded: EngineV2NewcomerBox?
        var nativeAttempted = false
        let clock = ContinuousClock()
        let startedAt = clock.now
        var phases = GLM5NextLoadPhases()
        do {
            try await GLM5NextUnretiredLoads.shared.requireHealthy()
            if artifactOwnership == nil { artifactOwnership = try .acquire(plan: plan) }
            try artifactOwnership!.claim(plan: plan)
            try await recheckPermit()
            try plan.weights.recheck()
            // No detached unjoined hash task: cancellation never releases the
            // permit or artifact lock while a reader still owns the source.
            let auxiliaryStartedAt = clock.now
            try await GLM5NextConstructionLane.shared.verify(plan)
            phases.auxiliaryVerification = clock.now - auxiliaryStartedAt
            try await recheckPermit()
            let tokenizer = try await LocalTokenizerLoader().load(from: plan.weights.directory)
            try Task.checkCancellation()
            try plan.weights.recheck()
            guard
                TemplateRenderCheck.renderOK(
                    at: plan.weights.directory, modelID: plan.weights.catalog.id) == true
            else {
                throw GLM5NextManagedLoadError.metadata(
                    "installed template does not render; no automatic repair")
            }
            try GLM5NextTokenizerPreflight.validate(tokenizer, modelID: plan.weights.catalog.id)
            guard let servingTokenizer = try? GLM5NextThinkingTokenizer(base: tokenizer) else {
                throw GLM5NextManagedLoadError.metadata("tokenizer lacks the <think> tokens")
            }
            try await recheckPermit()
            nativeAttempted = true
            let owner = GLM5NextConstructionOwner(hooks: hooks)
            constructionOwner = owner
            let constructed = try await GLM5NextConstructionLane.shared.construct(
                plan,
                tokenizer: servingTokenizer, loadMTP: loadMTP, budget: budget, permit: permit,
                owner: owner)
            loaded = EngineV2NewcomerBox(constructed.container)
            (phases.coreVerification, phases.construction) = (constructed.verification, constructed.construction)
            try Task.checkCancellation()
            try plan.weights.recheck()
            // The construction lane has joined native evaluation before handing
            // over an already-evaluated, serial ModelContainer. No model alias is
            // retained here; the ordinary newcomer owner now owns retirement.
            if let constructionOwner {
                await GLM5NextConstructionLane.shared.finishTransfer(constructionOwner)
            }
            if ownsPermit { await budget.finishPendingLoad(permit) }
            finished = true
            constructionOwner = nil
            releaseConstructionOwnership()
            phases.total = clock.now - startedAt
            self.phases = phases
            verifiedArtifactSHA256 = plan.weights.manifest.aggregateSHA256
            Self.logger.info(
                "GLM load \(plan.weights.catalog.id): all \(plan.weights.manifest.files.count) manifest files SHA-256 verified before serving; auxiliary verification \(Self.seconds(phases.auxiliaryVerification)), core verification \(Self.seconds(phases.coreVerification)), tensors and construction \(Self.seconds(phases.construction)), total \(Self.seconds(phases.total))")
            return try loaded!.borrowModel()
        } catch {
            if error as? GLM5NextManagedLoadError == .retirementUnproven {
                artifactOwnership?.retainAfterUnprovenCompletion()
                // Fail closed: neither filesystem ownership nor the pending
                // memory promise is refunded without a confirmed native join.
                await GLM5NextUnretiredLoads.shared.retain(self)
                throw error
            }
            if nativeAttempted {
                do {
                    if let constructionOwner {
                        try await GLM5NextConstructionLane.shared.cleanup(constructionOwner)
                    }
                } catch {
                    artifactOwnership?.retainAfterUnprovenCompletion()
                    await GLM5NextUnretiredLoads.shared.retain(self)
                    throw GLM5NextManagedLoadError.retirementUnproven
                }
            }
            await loaded?.releaseAfterExternalResources()
            constructionOwner = nil
            if ownsPermit { await budget.finishPendingLoad(permit) }
            finished = true
            releaseConstructionOwnership()
            throw error
        }
    }

    func constructionSnapshot() async -> (arrays: Int, owners: Int) {
        guard let constructionOwner else { return (0, 0) }
        return await GLM5NextConstructionLane.shared.snapshot(constructionOwner)
    }

    /// For a claimed load cancelled before `load` starts. Once started, only its
    /// joined completion path can refund the permit.
    func cancelBeforeStart() async throws {
        guard !started, !finished else { throw GLM5NextManagedLoadError.lifecycle }
        finished = true
        if ownsPermit { await budget.finishPendingLoad(permit) }
    }

    private func recheckPermit() async throws {
        try Task.checkCancellation()
        guard
            await budget.validateGLM5NextPendingLoad(
                permit, modelID: plan.weights.catalog.id,
                quotation: plan.quotation)
        else { throw GLM5NextManagedLoadError.admission }
    }

    private func releaseConstructionOwnership() {
        if ownsArtifactOwnership { artifactOwnership?.release() }
        artifactOwnership = nil
        activity?.finish()
        activity = nil
    }

    static func seconds(_ duration: Duration) -> String {
        let components = duration.components
        let value = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return String(format: "%.1f s", value)
    }
}

/// Synchronous native work is isolated on this lane. The caller always awaits
/// its completion, including cancellation, before releasing admission/locks.
private actor GLM5NextConstructionLane {
    static let shared = GLM5NextConstructionLane()
    func cleanup(_ owner: GLM5NextConstructionOwner) throws { try owner.cleanupAfterFailure() }
    func finishTransfer(_ owner: GLM5NextConstructionOwner) { owner.finishTransferred() }
    func snapshot(_ owner: GLM5NextConstructionOwner) -> (arrays: Int, owners: Int) {
        (owner.retainedArrayCount, owner.retainedOwnerCount)
    }

    func verify(_ plan: GLM5NextArtifactPlan) throws {
        try plan.weights.verifyAuxiliaryContents(nativeIdentity: plan.nativeIdentity)
    }

    func construct(
        _ plan: GLM5NextArtifactPlan, tokenizer: any Tokenizer,
        loadMTP: Bool, budget: GlobalKVCacheBudget,
        permit: PendingModelLoadLease, owner: GLM5NextConstructionOwner
    ) async throws -> (container: ModelContainer, verification: Duration, construction: Duration) {
        try Task.checkCancellation()
        guard
            await budget.validateGLM5NextPendingLoad(
                permit, modelID: plan.weights.catalog.id,
                quotation: plan.quotation)
        else { throw GLM5NextManagedLoadError.admission }
        try Task.checkCancellation()
        _ = try GPUEnforcement.requireMetal()
        MLXMemoryGuard.configureOnce()
        let clock = ContinuousClock()
        var verification = Duration.zero
        let startedAt = clock.now
        let container = try Stream.withNewDefaultStream(device: .gpu) {
            let stream = StreamOrDevice.default.stream
            owner.capture(stream: stream)
            do {
                return try MLX.withError { error in
                    // The initializer SHA-256-verifies every core file before it
                    // parses a header or reads a payload.
                    let artifact = try GLM5NextArtifactLoader(
                        directory: plan.weights.directory,
                        expectedIdentity: plan.nativeIdentity, storage: plan.storage,
                        constructionRoots: owner.roots,
                        executionPolicy: GLM5NextManagedLoad.executionPolicy)
                    verification = clock.now - startedAt
                    owner.retain(artifact)
                    guard artifact.configuration == plan.configuration,
                        artifact.inventory.entries.values.map(\.tensor).sorted(by: {
                            $0.name < $1.name
                        })
                            == plan.descriptors.sorted(by: { $0.name < $1.name }),
                        UInt64(artifact.resources.conservativeLoadPeakBytes)
                            <= plan.quotation.requiredWeightBytes
                    else {
                        throw GLM5NextManagedLoadError.identityMismatch
                    }
                    try Task.checkCancellation()
                    let processor = try GLM5NextProcessor(
                        configuration: plan.processorConfiguration, tokenizer: tokenizer)
                    let model = try GLM5NextModel(artifact: artifact, loadMTP: loadMTP)
                    owner.retain(model)
                    guard model.textTower.executionPolicy == GLM5NextManagedLoad.executionPolicy,
                        model.mtp.map({ $0.executionPolicy == GLM5NextManagedLoad.executionPolicy })
                            ?? true
                    else { throw GLM5NextManagedLoadError.identityMismatch }
                    // All source ranges are bounded and already evaluated; this
                    // is the final complete-owned-root fence, not a BF16 copy.
                    try owner.roots.evaluate(model.parameters().flattened().map(\.1))
                    stream.synchronize()
                    try error.check()
                    try Task.checkCancellation()
                    try plan.weights.recheck()
                    var configuration = ModelConfiguration(
                        directory: plan.weights.directory, eosTokenIds: plan.eosTokenIDs)
                    configuration.toolCallFormat = .glm5
                    let container = ModelContainer(
                        context: ModelContext(
                            configuration: configuration, model: model,
                            processor: processor, tokenizer: tokenizer))
                    owner.retain(container)
                    return container
                }
            } catch {
                let original = error
                do {
                    try owner.cleanupAfterFailure()
                } catch { throw GLM5NextManagedLoadError.retirementUnproven }
                throw original
            }
        }
        return (container, verification, clock.now - startedAt - verification)
    }
}

/// No timeout or destructor fabricates retirement after a failed native join.
/// Retain the actual owner/locks and refuse subsequent GLM construction. The
/// outer provider must apply its existing fatal native-fault policy as well.
private actor GLM5NextUnretiredLoads {
    static let shared = GLM5NextUnretiredLoads()
    private var retained: [GLM5NextManagedLoad] = []
    func requireHealthy() throws {
        guard retained.isEmpty else { throw GLM5NextManagedLoadError.retirementUnproven }
    }
    func retain(_ load: GLM5NextManagedLoad) {
        retained.append(load)
        GLM5NextLoadFaultState.retain([load])
    }
}
