// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Loads Muse Glimmer 30B's text tower for a generic CBv2 slot.
///
/// No SDK factory builds this model: `MuseGlimmerInstallation.stage` verifies
/// the pinned checkpoint (index and every shard by SHA-256) and installs the
/// projections it reads from the verified shard headers. The installer
/// reserves no memory, so this runs only inside the slot owner's LOAD claim,
/// like every `ModelContainerLoading` load. The provider's own weight-hash
/// bracket around the load is unchanged.
///
/// Text only: the checkpoint's vision tensors are verified and left unloaded.
enum MuseGlimmerServingLoad {
    static func container(from directory: URL) async throws -> ModelContainer {
        async let tokenizer = LocalTokenizerLoader().load(from: directory)
        let installed = try MuseGlimmerInstallation.stage(directory: directory)
        var configuration = ModelConfiguration(
            directory: directory,
            eosTokenIds: ModelEOSPolicy.artifactEOSTokenIds(modelDirectory: directory) ?? [])
        configuration.toolCallFormat = .atem
        let loadedTokenizer = try await tokenizer
        return ModelContainer(context: ModelContext(
            configuration: configuration, model: installed.model,
            processor: TextProcessor(tokenizer: loadedTokenizer), tokenizer: loadedTokenizer))
    }

    /// The container's input processor: the chat template over text messages.
    /// Serving tokenizes through the provider's own prompt pipeline; this
    /// serves the callers that hand a container a `UserInput`.
    private struct TextProcessor: UserInputProcessor {
        let tokenizer: any Tokenizer

        func prepare(input: UserInput) throws -> LMInput {
            let messages = DefaultMessageGenerator().generate(from: input)
            let tokens = try tokenizer.applyChatTemplate(
                messages: messages, tools: input.tools, additionalContext: input.additionalContext)
            return LMInput(tokens: MLXArray(tokens))
        }
    }
}
