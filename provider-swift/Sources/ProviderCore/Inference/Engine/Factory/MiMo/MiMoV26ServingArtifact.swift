import CryptoKit
import Foundation
import MLXVLM

/// Parse the artifact's real provenance schema. These metadata hashes bind the
/// installed source objects; they never assert an independent payload audit.
struct MiMoV26ServingArtifact {
    let provenance: MiMoV26ConvertedProvenance
    let visionEntries, audioEntries, speechEntries, mtpEntries: Int?
    let tensorCount, tensorBytes: Int?

    private struct Published: Decodable {
        let schema, original_model, original_revision: String
        let config_sha256, index_sha256: String
        let experts_requantized: Bool
        let vision_entries, audio_entries, mtp_entries: Int
    }

    static func parse(_ manifest: Data, file: String, configuration: Data, index: Data) throws -> Self {
        func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
        func hex(_ value: String, _ count: Int) -> Bool {
            value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        let configHash = hash(configuration), indexHash = hash(index), manifestHash = hash(manifest)
        let artifactID = "mimo-native-" + hash(Data((configHash + "\n" + indexHash + "\n" + manifestHash).utf8))
        if file == "conversion_manifest.json" {
            let d = try JSONDecoder().decode(MiMoV26ServingLoad.Manifest.self, from: manifest)
            guard d.source_repository == "XiaomiMiMo/MiMo-V2.6-Flash-RL",
                  hex(d.source_revision, 40), hex(d.source_config_sha256, 64),
                  d.experts == "original E2M1/E8M0 codes, group 32, no requantization",
                  d.dense == "FP8 dequantized to BF16; original BF16 unchanged",
                  d.mtp_embedded.architecture == "mimo_v2_nextn", d.mtp_embedded.storage == "embedded",
                  d.mtp_embedded.file == "model-mtp.safetensors", d.mtp_embedded.num_layers == 3,
                  d.output_tensor_count > 0, d.output_weight_bytes > 0,
                  let visual = d.modality_tensor_counts["visual"], visual > 0,
                  let audio = d.modality_tensor_counts["audio_encoder"], audio > 0,
                  let speech = d.modality_tensor_counts["speech_embeddings"], speech > 0 else {
                throw MiMoV26ServingLoadError.metadata
            }
            return .init(provenance: .init(artifactID: artifactID, sourceRepository: d.source_repository,
                sourceRevision: d.source_revision, conversionManifestSHA256: manifestHash),
                visionEntries: visual, audioEntries: audio, speechEntries: speech, mtpEntries: nil,
                tensorCount: d.output_tensor_count, tensorBytes: d.output_weight_bytes)
        }
        guard file == "artifact-provenance.json" else { throw MiMoV26ServingLoadError.metadata }
        let d = try JSONDecoder().decode(Published.self, from: manifest)
        guard d.schema == "mimo-v2-mlx-conversion-v1",
              ["XiaomiMiMo/MiMo-V2.6-Flash-MOPD", "XiaomiMiMo/MiMo-V2.6-Flash-RL"].contains(d.original_model),
              hex(d.original_revision, 40), d.config_sha256 == configHash, d.index_sha256 == indexHash,
              !d.experts_requantized, d.vision_entries > 0, d.audio_entries > 0, d.mtp_entries > 0 else {
            throw MiMoV26ServingLoadError.metadata
        }
        return .init(provenance: .init(artifactID: artifactID, sourceRepository: d.original_model,
            sourceRevision: d.original_revision, conversionManifestSHA256: manifestHash, layout: .mlxVLM),
            visionEntries: d.vision_entries, audioEntries: d.audio_entries, speechEntries: nil,
            mtpEntries: d.mtp_entries, tensorCount: nil, tensorBytes: nil)
    }

    func validate(_ plan: MiMoV26ConvertedLoadPlan) throws {
        let mlx = provenance.layout == .mlxVLM
        let keys = plan.descriptors.keys
        guard plan.provenance == provenance, plan.configuration.numNextnPredictLayers == 3,
              tensorCount.map({ $0 == keys.count }) ?? true,
              tensorBytes.map({ $0 == plan.tensorBytes }) ?? true,
              visionEntries == plan.components[.vision]?.count,
              audioEntries == (mlx ? plan.components[.audioPatch]?.count : keys.filter { $0.hasPrefix("audio_encoder.") }.count),
              speechEntries.map({ $0 == keys.filter { $0.hasPrefix("speech_embeddings.") }.count }) ?? true,
              mtpEntries.map({ $0 == plan.components[.mtp]?.count }) ?? true else {
            throw MiMoV26ServingLoadError.metadata
        }
    }
}
