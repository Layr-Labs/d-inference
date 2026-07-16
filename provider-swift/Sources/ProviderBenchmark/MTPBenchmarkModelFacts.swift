import Foundation
import ProviderCore

public enum MTPBenchmarkModelFacts {
    public static func inspect(
        modelID: String?,
        directory: URL
    ) throws -> MTPBenchmarkArtifactFacts {
        let resolved = directory.resolvingSymlinksInPath().standardizedFileURL
        let inferredID = huggingFaceModelID(snapshot: resolved)
        if let modelID, let inferredID, modelID != inferredID {
            throw MTPBenchmarkError.artifactIdentity(
                "model ID does not match the Hugging Face snapshot path")
        }
        guard let effectiveModelID = modelID ?? inferredID, !effectiveModelID.isEmpty else {
            throw MTPBenchmarkError.artifactIdentity(
                "model ID is required when it cannot be inferred from the snapshot path")
        }

        let configURL = resolved.appendingPathComponent("config.json")
        let data = try Data(contentsOf: configURL)
        let configSize = try regularFileSize(configURL.resolvingSymlinksInPath())
        let configSHA256 = MTPBenchmarkDigest.sha256(data)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let quantization = (object?["quantization"] as? [String: Any])
            ?? (object?["quantization_config"] as? [String: Any])
        let quantizationFacts = quantization.map {
            var overrides: [String: Int] = [:]
            for value in $0.values {
                collectNestedBitOverrides(value, into: &overrides)
            }
            return MTPBenchmarkArtifactFacts.Quantization(
                bits: integer($0["bits"]),
                groupSize: integer($0["group_size"]),
                mode: $0["mode"] as? String,
                perLayerOverridesByBits: overrides)
        }

        let entries = try FileManager.default.contentsOfDirectory(
            at: resolved,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles])
        let weights = try entries
            .filter { $0.pathExtension == "safetensors" }
            .map { url -> MTPBenchmarkArtifactFacts.WeightFile in
                let resolvedWeight = url.resolvingSymlinksInPath().standardizedFileURL
                let bytes = try regularFileSize(resolvedWeight)
                let identity = try weightIdentity(
                    snapshotEntry: url,
                    resolvedWeight: resolvedWeight,
                    snapshot: resolved)
                return .init(
                    name: url.lastPathComponent,
                    sizeBytes: bytes,
                    identityKind: identity.kind,
                    contentIdentity: identity.value)
            }
            .sorted { $0.name < $1.name }
        guard !weights.isEmpty else {
            throw MTPBenchmarkError.artifactIdentity("artifact has no safetensors weights")
        }

        let revision = revision(from: resolved)
        let fingerprint = MTPBenchmarkDigest.artifactFingerprint(
            modelID: effectiveModelID,
            revision: revision,
            configSizeBytes: configSize,
            configSHA256: configSHA256,
            weightFiles: weights)
        let architectures = object?["architectures"] as? [String]
        return MTPBenchmarkArtifactFacts(
            modelID: effectiveModelID,
            resolvedPath: resolved.path,
            revision: revision,
            modelType: object?["model_type"] as? String,
            architecture: architectures?.first,
            dtype: object?["dtype"] as? String,
            quantization: quantizationFacts,
            configSizeBytes: configSize,
            configSHA256: configSHA256,
            weightFiles: weights,
            artifactFingerprint: fingerprint)
    }

    public static func validateUnchanged(
        _ expected: MTPBenchmarkArtifactFacts,
        label: String
    ) throws {
        guard expected.hasVerifiableProvenance else {
            throw MTPBenchmarkError.artifactIdentity("\(label) lacks immutable provenance")
        }
        let refreshed: MTPBenchmarkArtifactFacts
        do {
            refreshed = try inspect(
                modelID: expected.modelID,
                directory: URL(fileURLWithPath: expected.resolvedPath, isDirectory: true))
        } catch {
            throw MTPBenchmarkError.artifactDrift(label)
        }
        guard refreshed.resolvedPath == expected.resolvedPath,
              refreshed.configSHA256 == expected.configSHA256,
              refreshed.weightFiles == expected.weightFiles,
              refreshed.artifactFingerprint == expected.artifactFingerprint
        else {
            throw MTPBenchmarkError.artifactDrift(label)
        }
    }

    public static func hardware() throws -> MTPBenchmarkHardware {
        let value = try HardwareDetector.detect()
        return MTPBenchmarkHardware(
            machineModel: value.machineModel,
            chipName: value.chipName,
            chipFamily: value.chipFamily.rawValue,
            chipTier: value.chipTier.rawValue,
            memoryGB: value.memoryGb,
            gpuCores: value.gpuCores,
            memoryBandwidthGBps: value.memoryBandwidthGbs)
    }

    private static func regularFileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
            throw MTPBenchmarkError.artifactIdentity("artifact member is not a nonempty file")
        }
        return Int64(size)
    }

    private static func weightIdentity(
        snapshotEntry: URL,
        resolvedWeight: URL,
        snapshot: URL
    ) throws -> (
        kind: MTPBenchmarkArtifactFacts.WeightFile.IdentityKind,
        value: String
    ) {
        let values = try snapshotEntry.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values.isSymbolicLink == true,
           snapshot.deletingLastPathComponent().lastPathComponent == "snapshots"
        {
            let repository = snapshot.deletingLastPathComponent().deletingLastPathComponent()
            let blobRoot = repository.appendingPathComponent("blobs", isDirectory: true)
                .standardizedFileURL
            let candidate = resolvedWeight.lastPathComponent.lowercased()
            if resolvedWeight.deletingLastPathComponent() == blobRoot,
               candidate.allSatisfy(\.isHexDigit)
            {
                if candidate.count == 64 {
                    return (.hfBlobSHA256, candidate)
                }
                if candidate.count == 40 {
                    return (.hfBlobGitSHA1, candidate)
                }
            }
        }
        return (.sha256, try MTPBenchmarkDigest.sha256(file: resolvedWeight))
    }

    private static func huggingFaceModelID(snapshot: URL) -> String? {
        let snapshots = snapshot.deletingLastPathComponent()
        guard snapshots.lastPathComponent == "snapshots" else { return nil }
        let repositoryName = snapshots.deletingLastPathComponent().lastPathComponent
        guard repositoryName.hasPrefix("models--") else { return nil }
        let encoded = repositoryName.dropFirst("models--".count)
        let components = encoded.components(separatedBy: "--")
        guard components.count >= 2, components.allSatisfy({ !$0.isEmpty }) else { return nil }
        return components.joined(separator: "/")
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }

    private static func collectNestedBitOverrides(
        _ value: Any,
        into counts: inout [String: Int]
    ) {
        if let object = value as? [String: Any] {
            if let bits = integer(object["bits"]) {
                counts[String(bits), default: 0] += 1
            }
            for child in object.values {
                collectNestedBitOverrides(child, into: &counts)
            }
        } else if let values = value as? [Any] {
            for child in values {
                collectNestedBitOverrides(child, into: &counts)
            }
        }
    }

    private static func revision(from directory: URL) -> String? {
        let name = directory.lastPathComponent
        guard name.count == 40, name.allSatisfy(\.isHexDigit) else { return nil }
        return name.lowercased()
    }
}
