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
///
/// The staged tower always serves with exact verify windows, drafter or not,
/// so it has one numerics profile: neither its output nor its checkpoint
/// identity depends on whether a drafter loaded.
enum MuseGlimmerServingLoad {
    /// `MuseGlimmerTextModel.numericsProfile` with exact windows on. The
    /// complete-checkpoint fingerprint carries it, and a store is built only
    /// for a tower that reports it.
    static let exactWindowsProfile = "muse-glimmer-exact-windows-v1"

    static func container(from directory: URL) async throws -> ModelContainer {
        async let tokenizer = LocalTokenizerLoader().load(from: directory)
        let installed = try MuseGlimmerInstallation.stage(directory: directory)
        try enableExactWindows(installed.model)
        var configuration = ModelConfiguration(
            directory: directory,
            eosTokenIds: ModelEOSPolicy.artifactEOSTokenIds(modelDirectory: directory) ?? [])
        configuration.toolCallFormat = .atem
        let loadedTokenizer = try await tokenizer
        return ModelContainer(context: ModelContext(
            configuration: configuration, model: installed.model,
            processor: TextProcessor(tokenizer: loadedTokenizer), tokenizer: loadedTokenizer))
    }

    /// Every call of 1 to 64 rows gives each row the bytes it gets alone, so
    /// one forward over a draft window equals the decode steps it replaces.
    /// A projection without a row-exact product throws
    /// (`MuseGlimmerRowExactError.unsupportedProjection`) and fails the load;
    /// the tower never falls back to MLX's kernels.
    static func enableExactWindows(_ model: MuseGlimmerTextModel) throws {
        try model.setRowExactWindows(true)
        guard model.verifiesWindowsExactly, model.numericsProfile == exactWindowsProfile else {
            throw MuseGlimmerServingLoadError.numericsProfile(model.numericsProfile)
        }
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

enum MuseGlimmerServingLoadError: Error, Equatable, CustomStringConvertible {
    /// The tower did not report the exact-windows profile after the switch.
    case numericsProfile(String)

    var description: String {
        switch self {
        case .numericsProfile(let profile): "Muse Glimmer numerics profile \(profile), not exact windows"
        }
    }
}
