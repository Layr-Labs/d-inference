import DarkbloomClusterPlacement
import Foundation

/// An artifact directory as placement reads it: tensor headers and the
/// configuration, nothing else. No weight byte is read and nothing is hashed,
/// so this takes milliseconds for a model of any size. It proves nothing
/// about the payload; the verified loader does that when a rank loads.
public enum ClusterPlacementArtifact {
    static let maximumHeaderBytes = 16 * 1024 * 1024
    static let maximumFiles = 512
    /// GLM NVFP4 declares per-expert packing in a roughly 10 MiB config.
    /// This is an IO ceiling only; each family's schema and identity gates
    /// still decide whether these bytes describe a supported artifact.
    static let maximumConfigurationBytes = 32 * 1024 * 1024

    static func configuration(directory: URL) throws -> Data {
        try BoundedProbeInput.data(directory.appendingPathComponent("config.json"),
            maximumBytes: maximumConfigurationBytes)
    }

    /// Every stored tensor named by the safetensors headers of a flat
    /// directory of regular files.
    public static func storedTensors(directory: URL) throws -> [ClusterPlacementStoredTensor] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".safetensors") }.sorted()
        guard !names.isEmpty, names.count <= maximumFiles else {
            throw ProbeError("The model directory has no safetensors file, or more than \(maximumFiles)")
        }
        var result: [ClusterPlacementStoredTensor] = [], seen = Set<String>()
        for name in names {
            let url = directory.appendingPathComponent(name)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular, let size = attributes[.size] as? Int, size >= 8 else {
                throw ProbeError("Not a regular safetensors file: \(name)")
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard let prefix = try handle.read(upToCount: 8), prefix.count == 8 else { throw ProbeError("Truncated safetensors file: \(name)") }
            let length64 = prefix.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
            guard length64 <= UInt64(maximumHeaderBytes), Int(length64) <= size - 8 else {
                throw ProbeError("Invalid or oversized safetensors header: \(name)")
            }
            let length = Int(length64)
            guard let bytes = try handle.read(upToCount: length), bytes.count == length,
                  let header = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                throw ProbeError("Invalid safetensors header: \(name)")
            }
            for (tensor, value) in header where tensor != "__metadata__" {
                guard seen.insert(tensor).inserted, let entry = value as? [String: Any],
                      let dtype = entry["dtype"] as? String, let shape = entry["shape"] as? [Int],
                      let offsets = entry["data_offsets"] as? [Int], offsets.count == 2,
                      offsets[0] >= 0, offsets[1] > offsets[0], offsets[1] <= size - 8 - length else {
                    throw ProbeError("Invalid or duplicate safetensors entry: \(tensor)")
                }
                result.append(.init(name: tensor, byteCount: offsets[1] - offsets[0], dtype: dtype, shape: shape))
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    /// For a request longer than the layout's planned one: the family's
    /// largest context and its every-rank request charge at `contextTokens`,
    /// or nil for a family that plans within its layout only.
    public static func requestedContext(directory: URL, contextTokens: Int) throws -> (largest: Int, charge: Int)? {
        let configuration = try Self.configuration(directory: directory)
        guard let family = try? QwenDensePlacementFamily(configuration: configuration),
              contextTokens <= family.largestContextTokens else { return nil }
        return (family.largestContextTokens, family.requestChargeEveryRankBytes(contextTokens: contextTokens))
    }

    /// The exact conservative charge and actual family bounds for a requested
    /// shape. Reads registered metadata only; no payload, model or device work.
    public static func requestedScope(directory: URL, promptTokens: Int, outputTokens: Int) throws -> ClusterPlacementRequestScope {
        let configuration = try Self.configuration(directory: directory)
        func scope(model: String, artifact: String, configurationHash: String,
                   profile: QwenLayerStageGenerationProfile, charge: (Int) throws -> Int) throws -> ClusterPlacementRequestScope {
            // Bound before adding or estimating memory, including hostile Int inputs.
            guard promptTokens > 0, outputTokens > 0,
                  promptTokens <= profile.maximumPromptTokens, outputTokens <= profile.maximumOutputTokens,
                  promptTokens <= profile.maximumContextTokens - outputTokens else {
                throw ProbeError("The requested scope is outside the model's request limits")
            }
            return try .init(runtimeModelID: model, artifactSHA256: artifact, configurationSHA256: configurationHash,
                promptTokens: promptTokens, outputTokens: outputTokens,
                maximumPromptTokens: profile.maximumPromptTokens, maximumOutputTokens: profile.maximumOutputTokens,
                maximumContextTokens: profile.maximumContextTokens,
                requestChargeEveryRankBytes: charge(promptTokens + outputTokens))
        }
        if GPTOSSRegisteredSpecification.handles(configuration: configuration) {
            let family = try GPTOSSPlacementFamily(configuration: configuration)
            return try scope(model: family.runtimeModelID, artifact: family.specification.artifactSHA256,
                configurationHash: family.specification.configurationSHA256, profile: family.profile) { _ in 0 }
        }
        if Gemma4RegisteredSpecification.isRegistered(configuration: configuration) {
            let manifestURL = directory.appendingPathComponent("manifest.json")
            let manifest = FileManager.default.fileExists(atPath: manifestURL.path)
                ? try BoundedProbeInput.data(manifestURL, maximumBytes: 4_194_304) : nil
            let family = try Gemma4PlacementFamily(configuration: configuration, manifest: manifest)
            return try scope(model: family.runtimeModelID, artifact: family.specification.artifactSHA256,
                configurationHash: family.specification.configurationSHA256, profile: family.profile) {
                try Gemma4StateBudget.estimate(maximumTokens: $0, chunkSize: family.maximumChunkTokens).stateAndBoundaryBytes
            }
        }
        // MiMo reserves its full advertised envelope already, and GLM uses
        // exact adapter quotations. Neither needs this reference extension.
        let definition = try QwenResidentModelDefinition(configuration: configuration)
        if definition.specification.model == .nemotron35Lightning {
            let family = try NemotronPlacementFamily(configuration: configuration)
            return try scope(model: family.runtimeModelID, artifact: definition.specification.artifactSHA256,
                configurationHash: definition.specification.configurationSHA256, profile: family.profile) {
                let charge = QwenPlacementCharge.wholeModelStateBytes(geometry: family.stateGeometry, contextTokens: $0,
                    chunk: family.maximumChunkTokens)
                guard charge > 0 else { throw ProbeError("Cannot price the registered request scope") }
                return charge
            }
        }
        let family = try QwenDensePlacementFamily(configuration: configuration)
        return try scope(model: family.runtimeModelID, artifact: definition.specification.artifactSHA256,
            configurationHash: definition.specification.configurationSHA256, profile: family.profile) {
            let charge = family.requestChargeEveryRankBytes(contextTokens: $0)
            guard charge > 0 else { throw ProbeError("Cannot price the registered request scope") }
            return charge
        }
    }

    /// The layout of the artifact in a directory, from its `config.json`, its
    /// tensor headers and, when present, its `manifest.json` (which tells two
    /// catalog entries that share a configuration apart).
    public static func layout(directory: URL,runtimeProfile: String? = nil) throws -> ClusterModelLayout {
        let configuration = try Self.configuration(directory: directory)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let manifest = FileManager.default.fileExists(atPath: manifestURL.path)
            ? try BoundedProbeInput.data(manifestURL, maximumBytes: 4_194_304) : nil
        return try ClusterPlacementLayouts.layout(configuration: configuration, tensors: storedTensors(directory: directory),
                                                  manifest: manifest,runtimeProfile:runtimeProfile)
    }
}
