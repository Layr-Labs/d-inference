import Foundation
import MLXLLM
import MLXLMCommon
import MLXVLM

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
/// artifact. Native Qwen4 uses its trained in-tree assistant; Gemma targets
/// retain their dedicated drafter path. Muse Glimmer loads only the pinned
/// quantized DFlash drafter.
struct ProductionProviderMTPAssistantLoader: ProviderMTPAssistantLoading {
    func loadAndBind(
        artifact: SpecDecArtifact,
        target: any LanguageModel
    ) async throws -> ProviderMTPAssistantHandle {
        if let glimmer = target as? MuseGlimmerTextModel {
            return try MuseGlimmerDrafterBinding.bind(
                directory: artifact.directory, target: glimmer, pin: .museGlimmer30BQuantized)
        }
        if let prism = target as? MLXVLM.PrismHadamardQwen35 {
            do {
                let assistant = try prism.loadValidated9BMTPAssistant(from: artifact.directory)
                return ProviderMTPAssistantHandle(owner: assistant, drafter: assistant)
            } catch {
                throw ProviderMTPAssistantLoadError.loadFailed(String(describing: error))
            }
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

        if target is any Qwen4ExpMTPTargeting {
            do {
                let assistant = try Qwen4ExpInlineMTPAssistant.load(
                    from: artifact.directory, target: target)
                return ProviderMTPAssistantHandle(owner: assistant, drafter: assistant)
            } catch let error as ProviderMTPAssistantLoadError {
                throw error
            } catch let error as Qwen4ExpInlineMTPError {
                throw ProviderMTPAssistantLoadError.loadFailed(error.localizedDescription)
            } catch {
                throw ProviderMTPAssistantLoadError.loadFailed(String(describing: error))
            }
        }

        if let nemotron = target as? NemotronH35Model {
            do {
                let assistant = try NemotronH35MTPAssistant.load(from: artifact.directory, target: nemotron)
                return ProviderMTPAssistantHandle(owner: assistant, drafter: assistant)
            } catch {
                throw ProviderMTPAssistantLoadError.loadFailed(String(describing: error))
            }
        }

        guard let gemmaTarget = target as? Gemma4TextModel else {
            throw ProviderMTPAssistantLoadError.targetIncompatible(
                String(describing: type(of: target)))
        }

        let assistant: MLXLLM.Gemma4AssistantDraftModel
        do {
            assistant = try await MLXLLM.Gemma4AssistantDraftModel.load(
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

/// Muse Glimmer's DFlash drafter over the served tower.
///
/// The store has already checked the artifact's files against its catalog or
/// local digests and `SpecDecLimits`; the SDK's pin checks both files' SHA-256
/// again and the configuration, so bytes other than the pinned quantized
/// drafter fail closed even if a catalog published them. The BF16 assistant
/// never gets here: the store refuses it on size.
///
/// Verification follows the tower: on exact verify windows (always on for
/// the served tower) one rectangular forward scores a round and each row
/// commits its own accepted prefix; otherwise rounds are serial. One request
/// speculates per round, the shape the SDK measured.
enum MuseGlimmerDrafterBinding {
    static func settings(target: MuseGlimmerTextModel) -> MuseGlimmerDFlashDrafter.Settings {
        var settings = MuseGlimmerDFlashDrafter.Settings.verifying(target, maximumSpeculativeRows: 1)
        settings.maximumDraftTokens = min(
            MuseGlimmerModelPolicy.maximumDraftTokens, CBv2MTPConfig.testedMaxDraftTokens)
        return settings
    }

    static func bind(
        directory: URL, target: MuseGlimmerTextModel, pin: MuseGlimmerDFlashArtifactPin
    ) throws -> ProviderMTPAssistantHandle {
        let model: MuseGlimmerDFlashDraftModel
        do {
            model = try MuseGlimmerDFlashDraftModel.load(
                directory: directory, pin: pin, maximumBytes: Int(SpecDecLimits.maximumArtifactBytes))
        } catch {
            throw ProviderMTPAssistantLoadError.loadFailed(String(describing: error))
        }
        do {
            let drafter = try MuseGlimmerDFlashDrafter(
                target: target, model: model, settings: settings(target: target))
            return ProviderMTPAssistantHandle(owner: model, drafter: drafter)
        } catch {
            throw ProviderMTPAssistantLoadError.bindFailed(String(describing: error))
        }
    }
}

func providerMTPVerificationPolicy(
    for drafter: (any CBv2MTPDrafter)?,
    automaticRectangularTokens: Int
) -> (mode: CBv2MTPVerificationMode, automaticRectangularTokens: Int) {
    if let required = drafter?.requiredVerificationMode {
        return (required, required == .automatic ? automaticRectangularTokens : 0)
    }
    // Verify a bounded window in one target traversal. Drafter-required
    // modes retain priority; the engine checks storage support and rolls
    // back rejected suffixes. Wider evaluation can change rounding and wording.
    return (.automatic, automaticRectangularTokens)
}
