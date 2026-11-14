// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import ProviderCoreFoundation

/// Loads Muse Glimmer 30B for a generic CBv2 slot: its text tower, and its
/// image encoder when this provider serves images.
///
/// No SDK factory builds this model: `MuseGlimmerInstallation.stage` verifies
/// the pinned checkpoint (index and every shard by SHA-256) and installs the
/// projections it reads from the verified shard headers. The installer
/// reserves no memory, so this runs only inside the slot owner's LOAD claim,
/// like every `ModelContainerLoading` load. The provider's own weight-hash
/// bracket around the load is unchanged.
///
/// Images: the vision tensors are verified with every other shard. The
/// encoder loads from those verified sources only when
/// `MuseGlimmerVisionArtifact` makes the same decision discovery advertised
/// (switch, exact identity, pinned metadata); an encoder that then fails to
/// load fails the whole load, so an advertised slot never serves text alone.
/// Otherwise the slot serves text and its processor records why images are
/// refused.
///
/// The staged tower always serves with exact verify windows, drafter or not,
/// so it has one numerics profile: neither its output nor its checkpoint
/// identity depends on whether a drafter loaded.
enum MuseGlimmerServingLoad {
    static func container(
        from directory: URL, modelID: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> ModelContainer {
        async let tokenizer = LocalTokenizerLoader().load(from: directory)
        let installed = try MuseGlimmerInstallation.stage(directory: directory)
        try enableExactWindows(installed.model)
        let images = try imageService(
            installed: installed, directory: directory, modelID: modelID, environment: environment)
        var configuration = ModelConfiguration(
            directory: directory,
            eosTokenIds: ModelEOSPolicy.artifactEOSTokenIds(modelDirectory: directory) ?? [])
        configuration.toolCallFormat = .atem
        let loadedTokenizer = try await tokenizer
        return ModelContainer(context: ModelContext(
            configuration: configuration, model: installed.model,
            processor: MuseGlimmerServingProcessor(tokenizer: loadedTokenizer, images: images),
            tokenizer: loadedTokenizer))
    }

    /// Every decode or verify row then gets the bytes it gets alone, at any
    /// row count, so one forward over a draft window equals the decode steps
    /// it replaces; prompt chunks keep MLX's arithmetic.
    /// A projection without a row-exact product throws
    /// (`MuseGlimmerRowExactError.unsupportedProjection`) and fails the load;
    /// the tower never falls back to MLX's kernels. The tower must then report
    /// `MuseGlimmerModelPolicy.servedNumericsProfile`, so an SDK whose numerics
    /// changed fails the load until the provider names the new profile.
    static func enableExactWindows(_ model: MuseGlimmerTextModel) throws {
        try model.setRowExactWindows(true)
        guard model.verifiesWindowsExactly,
            model.numericsProfile == MuseGlimmerModelPolicy.servedNumericsProfile
        else {
            throw MuseGlimmerServingLoadError.numericsProfile(model.numericsProfile)
        }
    }

    /// The slot's image service: the encoder over the installer's verified
    /// vision sources with the hashed `config.json` cross-checked, or the
    /// reason images are refused.
    static func imageService(
        installed: MuseGlimmerInstallation.Installed, directory: URL, modelID: String?,
        environment: [String: String]
    ) throws -> MuseGlimmerImageService {
        switch MuseGlimmerVisionArtifact.decision(
            snapshotDir: directory, modelID: modelID, environment: environment) {
        case .refused(let refusal):
            return .refused(refusal)
        case .serves(let configuration):
            do {
                return .serving(try MuseGlimmerImageEncoder.load(
                    installed: installed, checkpointConfiguration: configuration))
            } catch let error as MuseGlimmerImageError {
                throw MuseGlimmerServingLoadError.imageEncoder(error)
            }
        }
    }
}

/// What a loaded Muse Glimmer slot does with image parts.
enum MuseGlimmerImageService: Sendable {
    case serving(MuseGlimmerImageEncoder)
    case refused(MuseGlimmerVisionPolicy.Refusal)

    var encoder: MuseGlimmerImageEncoder? {
        if case .serving(let encoder) = self { return encoder }
        return nil
    }

    var refusal: MuseGlimmerVisionPolicy.Refusal? {
        if case .refused(let refusal) = self { return refusal }
        return nil
    }
}

/// The container's input processor: the chat template over text messages,
/// for the callers that hand a container a `UserInput`. Serving tokenizes
/// through the provider's own prompt pipeline. It also carries the slot's
/// image service, which the scheduler reads before any media work.
struct MuseGlimmerServingProcessor: UserInputProcessor {
    let tokenizer: any Tokenizer
    let images: MuseGlimmerImageService

    func prepare(input: UserInput) throws -> LMInput {
        let messages = DefaultMessageGenerator().generate(from: input)
        let tokens = try tokenizer.applyChatTemplate(
            messages: messages, tools: input.tools, additionalContext: input.additionalContext)
        return LMInput(tokens: MLXArray(tokens))
    }
}

enum MuseGlimmerServingLoadError: Error, Equatable, CustomStringConvertible {
    /// The tower did not report the served profile after the switch.
    case numericsProfile(String)
    /// Images are advertised for this snapshot, but its verified vision
    /// tensors do not load as the pinned stack.
    case imageEncoder(MuseGlimmerImageError)

    var description: String {
        switch self {
        case .numericsProfile(let profile): "Muse Glimmer numerics profile \(profile), not \(MuseGlimmerModelPolicy.servedNumericsProfile)"
        case .imageEncoder(let error): "Muse Glimmer image encoder: \(error)"
        }
    }
}
