// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import MLXLLM
import MLXLMCommon
import ProviderCoreFoundation

/// Whether a Muse Glimmer snapshot serves images on this provider. There is
/// no switch: these are the artifact's integrity checks, the policy's
/// identity and configuration rules
/// (`MuseGlimmerVisionPolicy.configurationRefusal`), then the pinned bytes of
/// `config.json`, `processor_config.json` and the index. Each file is read as
/// a bounded regular file, never through a symlink, exactly as the installer
/// reads its own metadata. Discovery and the managed load make the same
/// decision from the same files; the load additionally verifies every shard.
/// Reads metadata only, never a tensor.
enum MuseGlimmerVisionArtifact {
    enum Decision: Equatable {
        /// Images are served. `configuration` is the hashed `config.json`,
        /// which the encoder load cross-checks.
        case serves(configuration: Data)
        case refused(MuseGlimmerVisionPolicy.Refusal)

        var refusal: MuseGlimmerVisionPolicy.Refusal? {
            if case .refused(let refusal) = self { return refusal }
            return nil
        }
    }

    struct Pins: Equatable {
        var configuration = MuseGlimmerVisionPolicy.pinnedConfigurationSHA256
        var processorConfiguration = MuseGlimmerVisionPolicy.pinnedProcessorConfigurationSHA256
        var index = MuseGlimmerCheckpointPin.index
    }

    static let configurationFile = "config.json"
    static let processorConfigurationFile = "processor_config.json"
    static let indexFile = "model.safetensors.index.json"

    /// Bounds well above the pinned sizes (88,682, 1,084 and 213,580 bytes).
    static let maximumConfigurationBytes = 1 << 20
    static let maximumProcessorConfigurationBytes = 64 << 10
    static let maximumIndexBytes = 4 << 20

    static func decision(snapshotDir: URL, modelID: String?, pins: Pins = .init()) -> Decision {
        guard let configuration = pinnedBytes(snapshotDir, configurationFile,
                maximumBytes: maximumConfigurationBytes, sha256: pins.configuration),
            let object = (try? JSONSerialization.jsonObject(with: configuration)) as? [String: Any]
        else { return .refused(.unpinnedArtifact(file: configurationFile)) }
        if let refusal = MuseGlimmerVisionPolicy.configurationRefusal(object, modelID: modelID) {
            return .refused(refusal)
        }
        guard pinnedBytes(snapshotDir, processorConfigurationFile,
                maximumBytes: maximumProcessorConfigurationBytes, sha256: pins.processorConfiguration) != nil
        else { return .refused(.unpinnedArtifact(file: processorConfigurationFile)) }
        guard pinnedBytes(snapshotDir, indexFile, maximumBytes: maximumIndexBytes, sha256: pins.index) != nil
        else { return .refused(.unpinnedArtifact(file: indexFile)) }
        return .serves(configuration: configuration)
    }

    /// Discovery's `is_vision` for a Muse Glimmer snapshot.
    static func advertisesImages(snapshotDir: URL, modelID: String?, modelType: String?) -> Bool {
        MuseGlimmerModelPolicy.matches(modelId: modelID, modelType: modelType)
            && decision(snapshotDir: snapshotDir, modelID: modelID).refusal == nil
    }

    private static func pinnedBytes(_ directory: URL, _ name: String, maximumBytes: Int, sha256: String) -> Data? {
        guard let data = try? ModelOptIndexedCheckpoint.readRegularFile(
                at: directory.appendingPathComponent(name), maximumBytes: maximumBytes),
            SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256
        else { return nil }
        return data
    }
}
