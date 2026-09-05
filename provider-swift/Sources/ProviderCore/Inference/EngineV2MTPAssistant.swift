// Copyright © 2026 Eigen Labs.
//
// The slot's MTP drafter, loaded through the family's own runner.
//
// Darkbloom does not know how any family drafts. `Runner.loadDrafter` does:
// it is the one method on the runner boundary that READS TENSORS, and each
// family answers it its own way — an embedded `mtp.*` head inside the target
// checkpoint, or a separate assistant checkpoint bound to the loaded tower.
// What stays here is the provider's policy around it: the fail-open ladder
// (a drafter that cannot load leaves the slot serving serial, with a named
// `MTPFallbackReason`), the slot-owned lifetime handle, and the
// verification-mode policy the engine is configured with.
//
// The activation question — is `mtp` actually running — is answered on the
// runner path by `runner.loadedDecoders` and carried on `EngineBuild.decoder`
// (`EngineV2Factory.runnerDecoder`), which refuses a decoder the runner does
// not hold rather than downgrading it: `mtp_active` must never claim a head
// that is not running.

import Foundation
import MLXLMCommon
import MLXRunners

enum ProviderMTPAssistantLoadError: Error, CustomStringConvertible {
    case targetIncompatible(String)
    case loadFailed(String)
    case bindFailed(String)

    var reason: MTPFallbackReason {
        switch self {
        case .targetIncompatible, .bindFailed: .assistantTargetIncompatible
        case .loadFailed: .assistantLoadFailed
        }
    }

    var description: String {
        switch self {
        case .targetIncompatible(let detail): "target incompatible: \(detail)"
        case .loadFailed(let detail): "assistant load failed: \(detail)"
        case .bindFailed(let detail): "assistant bind failed: \(detail)"
        }
    }
}

protocol ProviderMTPAssistantLoading: Sendable {
    /// - Parameters:
    ///   - artifact: the resolved drafter artifact. Its directory is what the
    ///     runner is pointed at; for a family whose head ships inside the
    ///     target checkpoint that is the model directory itself.
    ///   - runner: the family claiming this checkpoint.
    ///   - modelDirectory: the target checkpoint.
    ///   - target: the module the engine will serve, so the drafter binds to
    ///     the instance that runs — never to a second copy.
    func loadAndBind(
        artifact: SpecDecArtifact,
        runner: (any Runner.Type)?,
        modelDirectory: URL?,
        target: any LanguageModel
    ) async throws -> ProviderMTPAssistantHandle
}

/// The sole production assistant loader: it asks the family's runner.
struct ProductionProviderMTPAssistantLoader: ProviderMTPAssistantLoading {
    func loadAndBind(
        artifact: SpecDecArtifact,
        runner: (any Runner.Type)?,
        modelDirectory: URL?,
        target: any LanguageModel
    ) async throws -> ProviderMTPAssistantHandle {
        // Production always has both: the slot resolved a checkpoint before
        // it resolved an artifact. Absent means a caller with no checkpoint
        // to ask, which cannot be served a drafter.
        guard let runner, let modelDirectory else {
            throw ProviderMTPAssistantLoadError.targetIncompatible(
                "no runner adopted for the slot, so no family can load a drafter")
        }
        let options = EngineV2Factory.runnerLoadOptions(
            modelDirectory: modelDirectory,
            drafterDirectory: artifact.directory,
            kvBytesCapacity: 0,
            maxSequenceLength: RunnerLoadOptions().maxSequenceLength)
        let drafter: (any CBv2MTPDrafter)?
        do {
            drafter = try await runner.loadDrafter(
                options: options, directory: modelDirectory, target: target)
        } catch RunnerError.unexpectedModel(let type) {
            throw ProviderMTPAssistantLoadError.targetIncompatible(type)
        } catch RunnerError.drafterUnavailable(let detail) {
            throw ProviderMTPAssistantLoadError.loadFailed(detail)
        } catch {
            throw ProviderMTPAssistantLoadError.loadFailed(String(describing: error))
        }
        // A runner that returns no drafter for a checkpoint the provider
        // resolved an artifact for has nothing to bind: fail open, by name.
        guard let drafter else {
            throw ProviderMTPAssistantLoadError.loadFailed(
                "\(runner.manifest.runnerID) loaded no drafter from \(artifact.directory.path)")
        }
        return ProviderMTPAssistantHandle(owner: drafter, drafter: drafter)
    }
}

func providerMTPVerificationPolicy(
    for drafter: (any CBv2MTPDrafter)?,
    automaticRectangularTokens: Int
) -> (mode: CBv2MTPVerificationMode, automaticRectangularTokens: Int) {
    guard let required = drafter?.requiredVerificationMode else {
        return (.automatic, automaticRectangularTokens)
    }
    return (required, required == .automatic ? automaticRectangularTokens : 0)
}
