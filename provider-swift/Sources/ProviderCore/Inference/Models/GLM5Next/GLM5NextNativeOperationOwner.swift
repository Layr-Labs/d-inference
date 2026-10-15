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
    #if DEBUG
        private var retirementRefusal: (@Sendable () throws -> Void)?
        func installRetirementRefusalForTesting(_ refusal: @escaping @Sendable () throws -> Void) {
            lock.withLock { retirementRefusal = refusal }
        }
    #endif
    let engineID: UUID
    let contractID: UUID

    init(model: GLM5NextProtectedModel, resources: GLM5NextProtectedResources, engine: EngineV2) {
        binding = Binding(model: model, resources: resources, engine: engine)
        engineID = engine.nativeShutdownEngineID
        contractID = resources.resources.contract.id
    }

    func bind(to bridge: EngineV2Bridge) throws {
        try lock.withLock {
            guard self.bridge == nil, !closing, !retired else {
                throw GLM5NextManagedLoadError.lifecycle
            }
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
                binding.resources.resources.contract.profile
                    == "glm5_next_native_paged_serial_mtp_v1",
                engine.usesProcessMemoryOwner(binding.resources.processOwner),
                binding.model.execution.target === binding.model.root.textTower,
                binding.model.root.mtp === binding.model.execution.predictor,
                binding.model.execution.maximumInputs == binding.model.maximumContextLength
            else {
                throw GLM5NextManagedLoadError.identityMismatch
            }
        }
    }

    func beginClosing(bridge: EngineV2Bridge, engine: EngineV2) throws {
        try lock.withLock {
            guard self.bridge === bridge, !retired, binding?.engine === engine,
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
        lock.withLock { closing = true }
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
        case .quiescent(let receipt): try complete(receipt)
        case .incomplete:
            retainFailure()
            throw GLM5NextManagedLoadError.retirementUnproven
        }
    }
}

struct GLM5NextNativeConstructionFailure: Error, CustomStringConvertible {
    let owner: GLM5NextNativeOperationOwner
    let cause: any Error
    var description: String { "GLM native construction failed before ownership handoff" }
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
    static func constructionFailure(_ error: any Error) async throws -> any Error {
        guard let failure = error as? GLM5NextNativeConstructionFailure else { return error }
        do { try await failure.owner.retireUnpublished() } catch {
            failure.owner.retainFailure()
            throw GLM5NextManagedLoadError.retirementUnproven
        }
        return failure.cause
    }

    static func beforeRelease(_ bridge: EngineV2Bridge) async throws {
        if await bridge.hasGLM5NextNativeOwner {
            try await bridge.shutdownGLM5NextReportingCompletion()
        } else {
            try GLM5NextLoadFaultState.requireHealthy()
            await bridge.shutdown()
        }
    }
}
