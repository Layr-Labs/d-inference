import Foundation
import Network

public enum ModelSwitchError: Error, Sendable, Equatable, LocalizedError {
    case disconnected
    case timedOut
    case invalidDrain
    case invalidModels
    case rejected(String)
    case switchInProgress

    public var errorDescription: String? {
        switch self {
        case .disconnected: "Coordinator connection lost; model switch outcome is unknown."
        case .timedOut: "Coordinator acknowledgement timed out; model switch outcome is unknown."
        case .invalidDrain: "Model replacement requires the latest acknowledged drain on this connection."
        case .invalidModels: "Coordinator rejected the complete model selection."
        case .rejected(let reason): "Coordinator rejected model replacement: \(reason)"
        case .switchInProgress: "A model replacement is already awaiting acknowledgement."
        }
    }
}

internal struct PendingModelReplacement: Sendable {
    let requestID: String
    let drainID: String
    let validateOnly: Bool
    let connection: NWConnection
    let continuation: AsyncStream<Result<Void, ModelSwitchError>>.Continuation
}

extension CoordinatorClient {
    /// Keeps the next registration truthful while the caller mutates its local
    /// inventory under a closed admission gate. This sends no wire traffic.
    internal func stageModelSelection(_ models: [ModelInfo]) {
        advertisedModelStore.replace(models)
        modelWeightHashOverrides = Dictionary(uniqueKeysWithValues: models.compactMap { model in
            model.weightHash.map { (model.id, $0) }
        })
    }

    /// Checks the complete target against the settled drain without changing the
    /// advertised inventory or consuming the drain. The caller must validate
    /// before unloading residents; only a later replacement resumes routing.
    public func validateModelSelectionAfterDrain(
        _ models: [ModelInfo], drainID: String, timeout: Duration
    ) async throws {
        try await sendModelSelectionAfterDrain(models, drainID: drainID, timeout: timeout, validateOnly: true)
    }

    /// Never reconnects. Explicit rejection restores the previous reconnect inventory;
    /// timeout/disconnect retains the intended inventory because commit is unknown.
    public func replaceModelsAfterDrain(
        _ models: [ModelInfo], drainID: String, timeout: Duration
    ) async throws {
        try await sendModelSelectionAfterDrain(models, drainID: drainID, timeout: timeout, validateOnly: false)
    }

    private func sendModelSelectionAfterDrain(
        _ models: [ModelInfo], drainID: String, timeout: Duration, validateOnly: Bool
    ) async throws {
        guard hasRegisteredConnection(), let connection = nwConnection else {
            throw ModelSwitchError.disconnected
        }
        guard modelReplacement == nil else { throw ModelSwitchError.switchInProgress }
        guard !drainID.isEmpty, acknowledgedSwitchDrain == drainID else {
            throw ModelSwitchError.invalidDrain
        }
        var ids = Set<String>()
        guard !models.isEmpty, models.allSatisfy({ model in
            !model.id.isEmpty && ids.insert(model.id).inserted &&
                ModelRuntimeRequirements.isEligible(modelID: model.id, available: config.runtimeCapabilities)
        }) else { throw ModelSwitchError.invalidModels }

        let oldModels = advertisedModelStore.models
        let oldHashes = modelWeightHashOverrides
        let id = UUID().uuidString
        let (stream, continuation) = AsyncStream<Result<Void, ModelSwitchError>>.makeStream()
        modelReplacement = PendingModelReplacement(
            requestID: id, drainID: drainID, validateOnly: validateOnly,
            connection: connection, continuation: continuation)
        defer {
            if modelReplacement?.requestID == id { modelReplacement = nil }
            continuation.finish()
        }
        // Install a commit's target before sending: a drop immediately after
        // coordinator commit must not register the old set on reconnect.
        // Validation cannot commit, so its reconnect inventory stays unchanged.
        if !validateOnly { stageModelSelection(models) }
        outboundRouter.yield(.modelsReplace(
            requestId: id, drainID: drainID, models: models, validateOnly: validateOnly))
        let result = await withTaskGroup(of: Result<Void, ModelSwitchError>.self) { group in
            group.addTask {
                for await result in stream { return result }
                return .failure(.disconnected)
            }
            group.addTask {
                try? await taskSleep(timeout)
                return .failure(.timedOut)
            }
            let result = await group.next() ?? .failure(.disconnected)
            group.cancelAll()
            return result
        }
        switch result {
        case .success:
            guard nwConnection === connection, hasRegisteredConnection() else {
                throw ModelSwitchError.disconnected
            }
            if !validateOnly, acknowledgedSwitchDrain == drainID { acknowledgedSwitchDrain = nil }
        case .failure(let error):
            switch error {
            case .invalidDrain, .invalidModels, .rejected:
                // Do not overwrite a new session's inventory after teardown.
                if !validateOnly, nwConnection === connection {
                    advertisedModelStore.replace(oldModels)
                    modelWeightHashOverrides = oldHashes
                }
            default:
                break
            }
            throw error
        }
    }

    internal func completeModelReplacement(_ ack: CoordinatorMessage.ModelsReplaceAck) {
        guard let pending = modelReplacement,
              pending.requestID == ack.requestId, pending.drainID == ack.drainRequestId,
              pending.validateOnly == ack.validateOnly,
              pending.connection === nwConnection else { return }
        let result: Result<Void, ModelSwitchError>
        if ack.accepted {
            result = .success(())
        } else {
            switch ack.error {
            case "invalid_drain": result = .failure(.invalidDrain)
            case "invalid_models": result = .failure(.invalidModels)
            case "disconnected": result = .failure(.disconnected)
            default: result = .failure(.rejected(ack.error ?? "unspecified"))
            }
        }
        pending.continuation.yield(result)
        pending.continuation.finish()
    }

    internal func failModelReplacements() {
        modelReplacement?.continuation.yield(.failure(.disconnected))
        modelReplacement?.continuation.finish()
        modelReplacement = nil
    }
}
