import Foundation

/// An exact retained-header profile. It is never a payload or native execution permit.
struct Gemma4ArtifactMetadata {
    static let configurationSHA256 = "29910322dd085f45c8f95c6c0f1611b20f722d6f6c8394321b34817e98a972fa"
    static let manifestSHA256 = "c1fefb1fa593fa3ca83e72a1124fb3afca10a59eed272c7ac2ac4a57f8018dfd"
    static let indexSHA256 = "5455e83705bbdd4e3702c7d4f9d49d4900e84533036628f74500538075dd5c80"
    static let artifactAggregateSHA256 = "2468a0cb3049a871f42052f4d9f9380bf12a0792f64c7a29f768559fc7d28785"
    static let headerSHA256 = [
        "model-00001-of-00003.safetensors": "5b3e8f2c593f5b291ffa3322540141bf909f454c917888957816273c53c9c735",
        "model-00002-of-00003.safetensors": "f1624d695581287157a8472d87224197d0a67d50ce5fd439af3ff45444ddd6dc",
        "model-00003-of-00003.safetensors": "52b3a65b791a2f0a1dd345291979ed5429388992ad12d824032b923bf9300a7a",
    ]
    let originalConfiguration: Data
    let text: Gemma4TextMetadata
    let sources: [LayerStageSourceTensor]
    let excludedSourceNames: [String]
    let sourceInventorySHA256: String
    let fingerprint: String
    let actualPayloadVerificationEstablished = false
    let runtimeExecutionAuthorized = false

    private init(configuration: Data, text: Gemma4TextMetadata, sources: [LayerStageSourceTensor], excluded: [String]) throws {
        originalConfiguration = configuration; self.text = text
        self.sources = sources; excludedSourceNames = excluded
        sourceInventorySHA256 = sha256(try canonicalJSONData(sources))
        fingerprint = sha256(Data(["gemma4-26b-retained-header-profile-v1", Self.configurationSHA256,
            Self.manifestSHA256, Self.indexSHA256, Self.artifactAggregateSHA256, sourceInventorySHA256,
            "payloadVerified=false", "executionAuthorized=false"].joined(separator: "\n").utf8))
    }

    static func admit(configuration: Data, manifest: Data, index: Data,
                      headers: [LayerStageCapturedTensorHeader]) throws -> Self {
        guard (1...1_048_576).contains(configuration.count), (1...1_048_576).contains(manifest.count),
              (1...2_097_152).contains(index.count), sha256(configuration) == configurationSHA256,
              sha256(manifest) == manifestSHA256, sha256(index) == indexSHA256,
              headers.count == 3, Set(headers.map(\.sourceFile)) == Set(headerSHA256.keys),
              headers.allSatisfy({ (1...2_097_152).contains($0.data.count) && sha256($0.data) == headerSHA256[$0.sourceFile] }) else {
            throw ProbeError("Gemma retained config/manifest/index/header identity differs")
        }
        try validateWorkerJSON(manifest)
        let declared = try JSONDecoder().decode(CheckpointManifest.self, from: manifest)
        guard declared.aggregate_sha256 == artifactAggregateSHA256, declared.file_count == 10,
              declared.total_size_bytes == 15_641_239_295,
              declared.files.count == 10,
              try QwenLongPrefillCheckedBytes.sum(declared.files.map(\.size_bytes)) == declared.total_size_bytes,
              declared.files.first(where: { $0.path == "config.json" })?.sha256 == configurationSHA256 else {
            throw ProbeError("Gemma declared manifest semantics differ")
        }
        let text = try Gemma4TextMetadata.decode(configuration)
        let sources = try LayerStageCapturedTensorHeaders.parse(manifest: declared, index: index, headers: headers)
        let excluded = try validateSourceInventory(sources, text: text)
        return try .init(configuration: configuration, text: text, sources: sources, excluded: excluded)
    }

    static func validateSourceInventory(_ sources: [LayerStageSourceTensor], text: Gemma4TextMetadata) throws -> [String] {
        let expected = try Gemma4TensorInventory.expectedText(text)
        let actual = sources.filter { $0.layout.canonicalName.hasPrefix("language_model.") }
        let excluded = sources.filter { !$0.layout.canonicalName.hasPrefix("language_model.") }
        guard sources.count == 1697, Set(sources.map { $0.layout.canonicalName }).count == sources.count,
              actual.count == 1339, expected.count == actual.count,
              Set(actual.map { $0.layout.canonicalName }) == Set(expected.keys),
              actual.allSatisfy({ expected[$0.layout.canonicalName] == $0.layout }),
              excluded.count == 358,
              excluded.filter({ $0.layout.canonicalName.hasPrefix("vision_tower.") }).count == 355,
              excluded.filter({ $0.layout.canonicalName.hasPrefix("embed_vision.") }).count == 3,
              try QwenLongPrefillCheckedBytes.sum(actual.map { $0.layout.byteCount }) == 14_467_688_508 else {
            throw ProbeError("Gemma source tensor ownership, packed geometry or exclusions differ")
        }
        return excluded.map { $0.layout.canonicalName }.sorted()
    }
}
