import Foundation
import MLXLLM
import MLXLMCommon

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
    func loadAndBind(
        artifact: SpecDecArtifact,
        target: any LanguageModel
    ) async throws -> ProviderMTPAssistantHandle
}

/// The sole production assistant loader. `Gemma4AssistantDraftModel.load`
/// decodes the assistant's own `config.json`, applies its own per-layer
/// quantization table, loads its own safetensors, and verifies all parameters.
struct Gemma4ProviderMTPAssistantLoader: ProviderMTPAssistantLoading {
    func loadAndBind(
        artifact: SpecDecArtifact,
        target: any LanguageModel
    ) async throws -> ProviderMTPAssistantHandle {
        if artifact.source == .inline {
            do {
                let assistant = try Qwen35InlineMTPAssistant.load(
                    from: artifact.directory, target: target)
                return ProviderMTPAssistantHandle(owner: assistant, drafter: assistant)
            } catch let error as ProviderMTPAssistantLoadError {
                throw error
            } catch let error as Qwen35InlineMTPError {
                throw ProviderMTPAssistantLoadError.loadFailed(
                    error.localizedDescription)
            } catch {
                throw ProviderMTPAssistantLoadError.loadFailed(String(describing: error))
            }
        }

        guard let gemmaTarget = target as? Gemma4TextModel else {
            throw ProviderMTPAssistantLoadError.targetIncompatible(
                String(describing: type(of: target)))
        }

        let assistant: Gemma4AssistantDraftModel
        do {
            assistant = try await Gemma4AssistantDraftModel.load(
                from: artifact.directory)
        } catch {
            throw ProviderMTPAssistantLoadError.loadFailed(String(describing: error))
        }
        do {
            let drafter = try Gemma4CBv2MTPDrafter(
                drafter: assistant, target: gemmaTarget)
            return ProviderMTPAssistantHandle(owner: assistant, drafter: drafter)
        } catch {
            throw ProviderMTPAssistantLoadError.bindFailed(String(describing: error))
        }
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
