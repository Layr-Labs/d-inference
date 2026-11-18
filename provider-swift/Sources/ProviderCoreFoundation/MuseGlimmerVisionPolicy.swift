// Copyright © 2026 Eigen Labs.

import CoreFoundation
import Foundation

/// Image input for Muse Glimmer 30B on one Mac.
///
/// Images are always on: there is no switch. Discovery advertises image input
/// (`is_vision`) whenever the artifact passes its integrity checks:
/// - the exact serving identity (registry id and `model_type`);
/// - `config.json` declares the pinned vision stack (`configurationRefusal`);
/// - `config.json`, `processor_config.json` and the index are the pinned
///   artifact's bytes (`MuseGlimmerVisionArtifact`, which reads them bounded).
///
/// The managed load then verifies every shard, the vision tensors included,
/// and loads the image encoder from that verified installation with the
/// same decision, so a slot serves images exactly when discovery advertised
/// them; an encoder that does not load fails the whole load. Otherwise image
/// parts are refused with a typed 400; the reason (`Refusal.reason`) is in
/// the error's description and this Mac's log, never on the wire. Video is
/// refused until the SDK takes it.
///
/// Pure: no MLX and no file access, so discovery and tests share it.
public enum MuseGlimmerVisionPolicy {
    /// `<|patch|>`: the template writes one per image part.
    public static let imageTokenID = 200_092
    /// `<|video|>`: refused until the SDK takes video.
    public static let videoTokenID = 200_091
    /// `max_image_tokens` of the pinned `processor_config.json`.
    public static let maximumImageTokens = 4_096
    /// `<|image_start|>` and `<|image_end|>` around each image's patch run.
    public static let framingTokens = 2
    /// The most prompt tokens one image adds. Admission and the media memory
    /// reserve this per image before any decode, so no image is under-counted.
    public static let maximumPromptTokensPerImage = maximumImageTokens + framingTokens

    /// SHA-256 of the pinned artifact's `config.json` (revision
    /// 47818374517751c48c55cde2621594926b1888b6). The index pin is the SDK's
    /// `MuseGlimmerCheckpointPin.index`; the installer pins every shard.
    public static let pinnedConfigurationSHA256 =
        "f3add3cfff62038fc7087e72f7df5a560660707aba7c8e65761bfa6bf8f08774"
    /// SHA-256 of the pinned `processor_config.json`. The SDK preprocesses
    /// with that file's values as constants, so another processor
    /// configuration is another model.
    public static let pinnedProcessorConfigurationSHA256 =
        "97e2a486dd9866b81f40cf4b8bc0c9ced9a7cd8a5bc65aa4cc2f4de0712dae77"

    /// Why this provider does not take a request's media for Muse Glimmer.
    /// Each reason is fixed text: no request content, path or value.
    public enum Refusal: Equatable, Sendable, CustomStringConvertible {
        /// Not the exact serving identity (registry id and `model_type`).
        case notServingIdentity
        /// `config.json` declares no vision stack, or not the pinned one.
        case configuration
        /// A metadata file is missing, unsafe or not the pinned bytes.
        case unpinnedArtifact(file: String)
        /// The loaded slot carries no image encoder.
        case encoderUnavailable
        /// Video parts.
        case video

        public var reason: String {
            switch self {
            case .notServingIdentity: "image input is served only for the pinned Muse Glimmer identity"
            case .configuration: "the checkpoint does not declare the pinned vision stack"
            case .unpinnedArtifact(let file): "the checkpoint's \(file) is not the pinned artifact"
            case .encoderUnavailable: "the loaded model has no image encoder"
            case .video: "video input is not supported yet"
            }
        }

        public var description: String { reason }
    }

    /// The refusal a configuration and identity alone imply, before any file
    /// is hashed; nil when they declare the pinned vision stack for the exact
    /// serving identity.
    public static func configurationRefusal(_ configuration: [String: Any], modelID: String?) -> Refusal? {
        // The exact spelling: the type rule trims and lowercases for wire
        // protocol rules, but media follows the pinned artifact only.
        guard configuration["model_type"] as? String == MuseGlimmerModelPolicy.modelType,
            MuseGlimmerModelPolicy.matchesModelID(modelID)
        else { return .notServingIdentity }
        guard declaresPinnedVision(configuration) else { return .configuration }
        return nil
    }

    /// The vision fields upstream's processor and the SDK encoder depend on.
    /// The config bytes are also hash-pinned; this keeps a text-only overlay
    /// or a hand-edited configuration from ever advertising media.
    static func declaresPinnedVision(_ configuration: [String: Any]) -> Bool {
        if let overlay = configuration["language_model_only"] {
            guard let flag = overlay as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(),
                !flag.boolValue
            else { return false }
        }
        guard let vision = configuration["vision_config"] as? [String: Any],
            integer(configuration["image_token_id"]) == imageTokenID,
            integer(configuration["video_token_id"]) == videoTokenID,
            vision["model_type"] as? String == "muse_glimmer_vision",
            integer(vision["patch_size"]) == 14,
            integer(vision["merge_size"]) == 2,
            integer(vision["patch_temporal"]) == 2,
            integer(vision["hidden_size"]) == 1_536,
            integer(vision["num_hidden_layers"]) == 50
        else { return false }
        return true
    }

    /// An integer JSON number; a Boolean or a fraction is not one.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            let exact = Int(exactly: number.doubleValue)
        else { return nil }
        return exact
    }
}
