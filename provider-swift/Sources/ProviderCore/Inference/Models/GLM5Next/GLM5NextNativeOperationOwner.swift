import Foundation
import MLXLLM
import MLXLMCommon

/// Public only so the bridge's public initializer can carry the opaque type.
/// Only provider factory code can construct it from an actual loaded GLM
/// resource tuple; callers cannot authorize native work with a flag or ID.
public final class GLM5NextNativeOperationOwner: @unchecked Sendable {
    private struct Binding {
        let model: GLM5NextProtectedModel
        let resources: GLM5NextProtectedResources
        let engine: EngineV2
    }
    private let lock = NSLock()
    private var binding: Binding?
    private weak var bridge: EngineV2Bridge?
    private var closing = false
    private var retired = false
    private var retainedFault = false
    #if DEBUG
        private var retirementRefusal: (@Sendable () throws -> Void)?
        func installRetirementRefusalForTesting(_ refusal: @escaping @Sendable () throws -> Void) {
            lock.withLock { retirementRefusal = refusal }
        }
    #endif
    let engineID: UUID
    let contractID: UUID
    /// The issued contract's permission, captured once; never a request flag.
    let servesPreparedCausalMedia: Bool
    private let residency: GLM5NextWiredResidency?

    init(model: GLM5NextProtectedModel, resources: GLM5NextProtectedResources, engine: EngineV2) {
        binding = Binding(model: model, resources: resources, engine: engine)
        engineID = engine.nativeShutdownEngineID
        contractID = resources.resources.contract.id
        servesPreparedCausalMedia = resources.resources.contract.supportsPreparedCausalMedia
        residency = GLM5NextWiredResidency.prepare(budget: resources.budget)
    }

    var residencyPhase: GLM5NextWiredResidency.Phase? { residency?.currentPhase }

    /// After the bridge is bound and its grant is serviceable.
    func startResidency() async {
        guard lock.withLock({ bridge != nil && !closing && !retired }) else { return }
        await residency?.start()
    }

    /// Only after proven retirement; an unproven close keeps the weights and
    /// therefore their residency. Idempotent (`GLM5NextWiredResidency.end`).
    func endResidencyAfterRetirement() async {
        guard lock.withLock({ retired }) else { return }
        await residency?.end()
    }

    func bind(to bridge: EngineV2Bridge) throws {
        try lock.withLock {
            guard self.bridge == nil, !closing, !retired, let binding else {
                throw GLM5NextManagedLoadError.lifecycle
            }
            try binding.resources.validateBinding(completePrefixCache: bridge.ssdHybridCheckpointStore)
            self.bridge = bridge
        }
    }

    func validate(bridge: EngineV2Bridge, engine: EngineV2, budget: GlobalKVCacheBudget?) throws {
        try GLM5NextLoadFaultState.requireHealthy()
        try lock.withLock {
            guard self.bridge === bridge, !closing, !retired, let binding,
                binding.engine === engine, binding.resources.budget === budget,
                engine.nativeShutdownExecutionContractID == contractID,
                engine.nativeShutdownEngineID == engineID, engine.nativeCompletionFault == nil,
                engine.usesProcessMemoryOwner(binding.resources.processOwner),
                binding.model.execution.target === binding.model.root.textTower,
                binding.model.root.mtp === binding.model.execution.predictor,
                binding.model.execution.maximumInputs == binding.model.maximumContextLength
            else {
                throw GLM5NextManagedLoadError.identityMismatch
            }
            try binding.resources.validateBinding(completePrefixCache: engine.completePrefixCache)
            guard bridge.ssdHybridCheckpointStore === binding.resources.resources.completePrefixCache else {
                throw GLM5NextManagedLoadError.identityMismatch
            }
        }
    }

    /// A close may be re-driven on the same owner while its host consumers
    /// drain, but a retained (unproven) close never is.
    func beginClosing(bridge: EngineV2Bridge, engine: EngineV2) throws {
        try lock.withLock {
            guard !retainedFault, !retired else { throw GLM5NextManagedLoadError.lifecycle }
            guard self.bridge === bridge, binding?.engine === engine,
                engine.nativeShutdownEngineID == engineID,
                engine.nativeShutdownExecutionContractID == contractID
            else {
                throw GLM5NextManagedLoadError.identityMismatch
            }
            closing = true
        }
        #if DEBUG
            try lock.withLock { retirementRefusal }?()
        #endif
    }

    /// Idempotent: concurrent re-drives of one closing owner may each complete
    /// it with the same cached bridge receipt.
    func complete(_ receipt: CBv2NativeShutdownReceipt) throws {
        try lock.withLock {
            guard receipt.engineID == engineID, receipt.executionContractID == contractID,
                receipt.generation == 1
            else { throw GLM5NextManagedLoadError.identityMismatch }
            closing = true
            retired = true
            binding = nil
        }
    }

    func retainFailure() {
        lock.withLock {
            closing = true
            retainedFault = true
        }
        GLM5NextLoadFaultState.retain([self])
    }

    /// No bridge exists if post-engine factory validation fails. Retire that
    /// exact engine before any host releases its root or restores a grant.
    func retireUnpublished() async throws {
        let engine = try lock.withLock { () throws -> EngineV2 in
            guard bridge == nil, let binding, !retired else {
                throw GLM5NextManagedLoadError.lifecycle
            }
            closing = true
            return binding.engine
        }
        switch await engine.shutdownReportingNativeCompletion() {
        case .quiescent(let receipt):
            try complete(receipt)
            await endResidencyAfterRetirement()
        case .incomplete:
            retainFailure()
            throw GLM5NextManagedLoadError.retirementUnproven
        }
    }
}

struct GLM5NextNativeConstructionFailure: Error, CustomStringConvertible {
    let owner: GLM5NextNativeOperationOwner
    let cause: any Error
    var description: String { "GLM native construction failed before ownership handoff: \(cause)" }
}

enum GLM5NextRetirement {
    static func validatedFailure(_ error: any Error, retaining owners: [AnyObject]) async
        -> any Error
    {
        do {
            let cause = try await constructionFailure(error)
            if GLM5NextLoadFunnel.isUnproven(cause) {
                GLM5NextLoadFaultState.retain(owners)
                return GLM5NextManagedLoadError.retirementUnproven
            }
            return cause
        } catch {
            GLM5NextLoadFaultState.retain(owners)
            return GLM5NextManagedLoadError.retirementUnproven
        }
    }

    /// `validatedFailure` for a failed slot build whose memory lies outside
    /// every published slot: an unproven retirement also charges
    /// `residentBytes` to `key`, so fleet KV budgets keep excluding it.
    static func validatedFailure(
        _ error: any Error, retaining owners: [AnyObject],
        charging key: AnyObject, residentBytes: @autoclosure () -> UInt64
    ) async -> any Error {
        let failure = await validatedFailure(error, retaining: owners)
        if GLM5NextLoadFunnel.isUnproven(failure) {
            GLM5NextLoadFaultState.retain(owners, charging: key, residentBytes: residentBytes())
        }
        return failure
    }

    static func constructionFailure(_ error: any Error) async throws -> any Error {
        guard let failure = error as? GLM5NextNativeConstructionFailure else { return error }
        do { try await failure.owner.retireUnpublished() } catch {
            failure.owner.retainFailure()
            throw GLM5NextManagedLoadError.retirementUnproven
        }
        return failure.cause
    }

    /// Retains a bundle whose weights remain counted by a slot (its own slot
    /// after a failed unload/eviction, or the published slot sharing them).
    /// Only its KV claim and any separate assistant bytes are charged.
    static func retainUnpublished(_ bundle: ProviderEngineBundle, with owners: [AnyObject]) async {
        let claim = await bundle.bridge.slotKVBytesClaim()
        let assistant = Int(clamping: bundle.assistantBytes)
        GLM5NextLoadFaultState.retain(owners, charging: bundle,
            residentBytes: GLM5NextLoadFaultState.residentBytes(claim, assistant))
    }

    /// After a quiescent SDK receipt, host pre-submit consumers of a closed
    /// bridge are already cancelled and unwind on their own; their pending
    /// result is retried, never treated as an unproven retirement. Any other
    /// error (incomplete proof, identity mismatch) escapes unchanged.
    ///
    /// The wait outlives a cancelled caller, as MiMo's registry-driven retry
    /// does: the bridge is already closed and cannot return to service, and
    /// every caller (unload, eviction, upgrade, recovery, unwind) treats any
    /// retirement error as unproven and retains it. Abandoning a proven-idle
    /// retirement on cancellation would therefore disable GLM until restart.
    static func drainingHostConsumers<T>(
        isolation: isolated (any Actor)? = #isolation,
        sleep: (Duration) async -> Void = { delay in
            await Task.detached { try? await Task.sleep(for: delay) }.value
        },
        _ attempt: () async throws -> T
    ) async throws -> T {
        var delay = Duration.milliseconds(5)
        while true {
            do { return try await attempt() } catch MiMoV26NativeBridgeShutdownError.pendingConsumers {
                await sleep(delay)
                delay = min(delay * 2, .milliseconds(250))
            }
        }
    }

    static func beforeRelease(_ bridge: EngineV2Bridge) async throws {
        if await bridge.hasGLM5NextNativeOwner {
            try await bridge.shutdownGLM5NextReportingCompletion()
        } else {
            if bridge.isGLM5NextManaged { try GLM5NextLoadFaultState.requireHealthy() }
            await bridge.shutdown()
        }
    }
}
