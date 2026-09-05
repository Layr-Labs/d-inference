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

/// The sole production assistant loader. Qwen 3.5 targets accept either a
/// combined inline assistant or a separately published `qwen3_5_mtp`
/// artifact; Qwen 3.8 Flash-Next drives the target checkpoint's own `mtp.*`
/// head; Gemma targets retain their dedicated assistant-checkpoint path.
///
/// This is the container path's form of the contract's decoder selection
/// (§5, §9): a drafter that binds here is the `mtp` decoder being resident,
/// and a target with no head stays serial. On the runner path the same
/// question is answered by `runner.loadedDecoders` and carried on
/// `EngineBuild.decoder` — see
/// `EngineV2Factory.runnerDecoder(runner:speculationRequested:)`, which
/// refuses rather than downgrading, for exactly the reason the fallback
/// reasons below are recorded: `mtp_active` must never claim a head that is
/// not running.
struct ProductionProviderMTPAssistantLoader: ProviderMTPAssistantLoading {
    func loadAndBind(
        artifact: SpecDecArtifact,
        target: any LanguageModel
    ) async throws -> ProviderMTPAssistantHandle {
        // Qwen 3.8 Flash-Next: the head is a block of the TARGET checkpoint
        // (`mtp.*`), not a separate artifact, so there is nothing to load
        // from a directory — the same shape `Qwen4ExpRunner` gives the
        // benchmark worker, where the drafter is built straight off the
        // loaded model and a drafter directory pointing anywhere else is
        // refused. A checkpoint published without the head simply has no
        // `mtp` decoder and serves serial.
        if let qwen4Exp = target as? Qwen4ExpModel {
            guard let assistant = Qwen4ExpInlineMTPAssistant(target: qwen4Exp) else {
                throw ProviderMTPAssistantLoadError.targetIncompatible(
                    "the qwen4_exp checkpoint carries no mtp.* head")
            }
            return ProviderMTPAssistantHandle(owner: assistant, drafter: assistant)
        }

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
    automaticRectangularTokens: Int
) -> (mode: CBv2MTPVerificationMode, automaticRectangularTokens: Int) {
    guard let required = drafter?.requiredVerificationMode else {
        return (.automatic, automaticRectangularTokens)
    }
    return (required, required == .automatic ? automaticRectangularTokens : 0)
}
