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

/// The sole production assistant loader. Qwen targets accept either a
/// combined inline assistant or a separately published `qwen3_5_mtp`
/// artifact; Gemma targets retain their dedicated drafter path.
struct ProductionProviderMTPAssistantLoader: ProviderMTPAssistantLoading {
    func loadAndBind(
        artifact: SpecDecArtifact,
        target: any LanguageModel
    ) async throws -> ProviderMTPAssistantHandle {
        if target is Qwen35TextModel || target is Qwen35Model {
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
    modelID: String? = nil,
    benchmarkVerification: EngineV2BenchmarkMTPVerification? = nil,
    automaticRectangularTokens: Int
) -> (mode: CBv2MTPVerificationMode, automaticRectangularTokens: Int) {
    if let required = drafter?.requiredVerificationMode {
        return (required, required == .automatic ? automaticRectangularTokens : 0)
    }
    // Same-state QAT verification changes target logits with rectangular width.
    // Keep assistant drafting and acceptance, but score its columns with the
    // ordinary target shape. Explicit offline controls retain their bounded
    // automatic baseline and undergo the usual target/drafter validation.
    if drafter != nil, modelID == "gemma-4-26b-qat-4bit", benchmarkVerification == nil {
        return (.serialTarget, 0)
    }
    return (.automatic, automaticRectangularTokens)
}
