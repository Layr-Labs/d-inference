import CryptoKit
import Foundation
import Logging
import ProviderCoreFoundation

enum SpecDecStore {
    static let manifestFileName = "manifest.json"
    private static let logger = Logger(label: "darkbloom.SpecDecStore")

    private struct InlineWeightIndex: Decodable {
        let metadata: [String: Int64]?
        let weightMap: [String: String]

        enum CodingKeys: String, CodingKey {
            case metadata = "metadata"
            case weightMap = "weight_map"
        }
    }

    struct Verification: Sendable {
        let manifest: ModelManifest
        let manifestSHA256: String
        let artifactBytes: UInt64
    }

    struct VerificationError: Error, Sendable, CustomStringConvertible {
        let reason: MTPFallbackReason
        let description: String
    }

    /// Inline-artifact inspection failure carrying the concrete reason and
    /// file path. Inline MTP going missing silently poisons measurement and
    /// serving sessions (the drafter simply never activates), so every
    /// rejection is BOTH returned to the caller and logged at warning level.
    struct InlineArtifactRejection: Error, Sendable, CustomStringConvertible {
        let description: String
    }

    static func defaultRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".darkbloom", isDirectory: true)
            .appendingPathComponent("spec-dec", isDirectory: true)
    }

    /// Full SHA-256 avoids aliasing two immutable prefixes into one directory.
    static func key(forR2Prefix prefix: String) -> String {
        SHA256.hash(data: Data(prefix.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func artifactDirectory(root: URL, r2Prefix: String) -> URL {
        root.appendingPathComponent(key(forR2Prefix: r2Prefix), isDirectory: true)
    }

    static func stagingDirectory(root: URL, r2Prefix: String) -> URL {
        root.appendingPathComponent(
            ".staging-\(key(forR2Prefix: r2Prefix))-\(UUID().uuidString)",
            isDirectory: true)
    }

    static func verifyPublishedArtifact(
        at directory: URL,
        reference: SpecDecArtifactReference
    ) -> Result<Verification, VerificationError> {
        let fm = FileManager.default
        guard !Task.isCancelled else {
            return .failure(.init(reason: .warmArtifactCorrupt, description: "artifact verification was cancelled"))
        }
        guard isDirectoryWithoutSymlink(directory) else {
            return .failure(.init(reason: .warmArtifactCorrupt, description: "artifact directory is missing or is a symlink"))
        }
        let manifestURL = directory.appendingPathComponent(manifestFileName, isDirectory: false)
        guard let manifestSize = regularFileSize(manifestURL),
            manifestSize > 0, manifestSize <= UInt64(SpecDecLimits.maximumManifestBytes)
        else {
            return .failure(.init(reason: .warmArtifactCorrupt, description: "manifest file is missing, non-regular, or oversized"))
        }
        let manifestData: Data
        do {
            manifestData = try Data(contentsOf: manifestURL)
        } catch {
            return .failure(.init(reason: .warmArtifactCorrupt, description: "manifest file is unreadable"))
        }
        let manifest: ModelManifest
        do {
            manifest = try ModelCatalogClient.manifestDecoder.decode(ModelManifest.self, from: manifestData)
        } catch {
            return .failure(.init(reason: .manifestMalformed, description: "manifest JSON is invalid"))
        }
        switch validateManifest(manifest, data: manifestData, reference: reference) {
        case .failure(let error): return .failure(error)
        case .success: break
        }

        let expectedNames = Set(manifest.files.map(\.path) + [manifestFileName])
        guard let actualURLs = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: []),
            Set(actualURLs.map(\.lastPathComponent)) == expectedNames
        else {
            return .failure(.init(reason: .warmArtifactCorrupt, description: "artifact contains missing or unexpected files"))
        }

        var aggregate = SHA256()
        var configDigest: String?
        for file in manifest.files.sorted(by: { $0.path < $1.path }) {
            guard !Task.isCancelled else {
                return .failure(.init(reason: .warmArtifactCorrupt, description: "artifact verification was cancelled"))
            }
            let url = directory.appendingPathComponent(file.path, isDirectory: false)
            guard let size = regularFileSize(url), size == UInt64(file.sizeBytes) else {
                return .failure(.init(reason: .warmArtifactCorrupt, description: "stored file size/type mismatch"))
            }
            guard let digest = digestRegularFile(at: url), hex(digest) == file.sha256.lowercased() else {
                return .failure(.init(reason: .fileDigestMismatch, description: "stored file digest mismatch"))
            }
            digest.withUnsafeBytes { aggregate.update(bufferPointer: $0) }
            if file.path == "config.json" {
                configDigest = hex(digest)
            }
        }
        guard hex(aggregate.finalize()) == manifest.aggregateSHA256.lowercased() else {
            return .failure(.init(reason: .fileDigestMismatch, description: "stored aggregate digest mismatch"))
        }
        guard configDigest == reference.configSHA256 else {
            return .failure(.init(reason: .fileDigestMismatch, description: "assistant config digest mismatch"))
        }
        return .success(
            Verification(
                manifest: manifest,
                manifestSHA256: sha256Hex(manifestData),
                artifactBytes: UInt64(manifest.totalSizeBytes)))
    }

    static func validateManifest(
        _ manifest: ModelManifest,
        data: Data,
        reference: SpecDecArtifactReference
    ) -> Result<Void, VerificationError> {
        guard data.count <= SpecDecLimits.maximumManifestBytes, manifest.schemaVersion == 1 else {
            return .failure(.init(reason: .manifestMalformed, description: "unsupported or oversized manifest"))
        }
        let manifestDigest = sha256Hex(data)
        if manifestDigest != reference.manifestSHA256 {
            return .failure(.init(reason: .manifestDigestMismatch, description: "manifest digest does not match catalog metadata"))
        }
        guard manifest.r2Prefix == reference.r2Prefix,
            reference.revision == manifest.version,
            !manifest.modelID.isEmpty, manifest.modelID.utf8.count <= 512,
            !manifest.version.isEmpty,
            manifest.version.utf8.count <= SpecDecLimits.maximumRevisionBytes,
            manifest.modelID.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy({ SpecDecMetadata.validIdentifier(String($0)) }),
            SpecDecMetadata.validIdentifier(manifest.version)
        else {
            return .failure(.init(reason: .manifestBindingMismatch, description: "manifest identity does not match metadata"))
        }
        guard manifest.fileCount == manifest.files.count,
            manifest.fileCount > 0,
            manifest.fileCount <= reference.maximumFileCount,
            manifest.fileCount <= SpecDecLimits.maximumFileCount,
            reference.expectedFileCount == manifest.fileCount
        else {
            return .failure(.init(reason: .fileCountInvalid, description: "manifest file count is invalid"))
        }
        guard manifest.totalSizeBytes > 0,
            UInt64(manifest.totalSizeBytes) <= SpecDecLimits.maximumArtifactBytes,
            reference.expectedTotalBytes == UInt64(manifest.totalSizeBytes)
        else {
            return .failure(.init(reason: .artifactOversize, description: "manifest total size is invalid"))
        }
        guard SpecDecMetadata.isSHA256(manifest.aggregateSHA256) else {
            return .failure(.init(reason: .manifestMalformed, description: "aggregate digest is invalid"))
        }

        var names = Set<String>()
        var total: UInt64 = 0
        var hasConfig = false
        var hasWeights = false
        for file in manifest.files {
            guard let safe = try? ModelDownloader.validatedManifestRelativePath(file.path),
                safe == file.path, !safe.contains("/"),
                safe.utf8.count <= SpecDecLimits.maximumFileNameBytes,
                SpecDecMetadata.validIdentifier(safe),
                names.insert(safe).inserted
            else {
                return .failure(.init(reason: .pathInvalid, description: "manifest path is unsafe or duplicated"))
            }
            guard file.sizeBytes > 0, SpecDecMetadata.isSHA256(file.sha256),
                file.role.utf8.count <= 32
            else {
                return .failure(.init(reason: .manifestMalformed, description: "manifest file facts are invalid"))
            }
            guard SpecDecLimits.allowedRoles.contains(file.role),
                reference.allowedFileRoles.contains(file.role)
            else {
                return .failure(.init(reason: .fileTypeDisallowed, description: "manifest file role is disallowed"))
            }
            if file.role == "config" {
                guard file.path == "config.json",
                    UInt64(file.sizeBytes) <= SpecDecLimits.maximumConfigBytes
                else {
                    return .failure(.init(reason: .fileTypeDisallowed, description: "config role must be config.json"))
                }
                hasConfig = true
            } else if file.role == "weight" {
                guard file.path.hasSuffix(".safetensors") else {
                    return .failure(.init(reason: .fileTypeDisallowed, description: "weight role must be safetensors"))
                }
                hasWeights = true
            }
            let (sum, overflow) = total.addingReportingOverflow(UInt64(file.sizeBytes))
            guard !overflow, sum <= SpecDecLimits.maximumArtifactBytes else {
                return .failure(.init(reason: .artifactOversize, description: "manifest file sizes overflow the artifact bound"))
            }
            total = sum
        }
        guard hasConfig, hasWeights, total == UInt64(manifest.totalSizeBytes) else {
            return .failure(.init(reason: .manifestMalformed, description: "manifest totals or required files are invalid"))
        }
        return .success(())
    }

    /// Inspect an operator-provided local assistant without trusting names or
    /// directory aggregate size. Only the exact files consumed by the engine
    /// loader are allowed and charged.
    static func inspectLocalArtifact(path: String) -> SpecDecArtifact? {
        guard path.utf8.count <= 4096 else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        let directory = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        let canonicalDirectory = directory.resolvingSymlinksInPath()
        guard isDirectoryWithoutSymlink(directory),
            let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: []),
            !urls.isEmpty, urls.count <= SpecDecLimits.maximumFileCount
        else { return nil }

        var total: UInt64 = 0
        var hasConfig = false
        var configDigest: String?
        var weightDigests: [String: String] = [:]
        for url in urls {
            guard !Task.isCancelled else { return nil }
            let name = url.lastPathComponent
            let standardized = url.standardizedFileURL
            guard !isSymbolicLink(standardized),
                standardized.resolvingSymlinksInPath().deletingLastPathComponent()
                    == canonicalDirectory,
                let size = regularFileSize(standardized), size > 0,
                let digest = digestRegularFile(at: standardized)
            else { return nil }
            let digestHex = hex(digest)
            if name == "config.json" {
                guard size <= SpecDecLimits.maximumConfigBytes else { return nil }
                hasConfig = true
                configDigest = digestHex
            } else if name.hasSuffix(".safetensors") {
                weightDigests[name] = digestHex
            } else {
                return nil
            }
            let (sum, overflow) = total.addingReportingOverflow(size)
            guard !overflow, sum <= SpecDecLimits.maximumArtifactBytes else { return nil }
            total = sum
        }
        guard hasConfig, !weightDigests.isEmpty, let configDigest else { return nil }
        return SpecDecArtifact(
            directory: directory,
            source: .local,
            revision: "local-\(configDigest.prefix(16))",
            artifactBytes: total,
            residentBytes: SpecDecLimits.residentEstimate(artifactBytes: total),
            manifestSHA256: nil,
            localWeightSHA256: weightDigests,
            localConfigSHA256: configDigest)
    }

    /// Inspect an inline Qwen MTP payload without copying or re-hashing the
    /// combined target shards. The target model manifest/weight hash already
    /// authenticates those files; this inspection pins the config + index,
    /// validates every selected key/path, and charges the index's declared
    /// MTP payload bytes rather than the whole 20 GiB checkpoint.
    ///
    /// Symlinked members are RESOLVED, not rejected: HF-cache snapshots store
    /// every shard as a symlink into `blobs/`, and that is the layout the
    /// already-verified target checkpoint normally arrives in. (Operator
    /// -provided local overrides — `inspectLocalArtifact` — still reject
    /// symlinks: there the directory itself is untrusted input.) Every
    /// rejection names its concrete reason and file path; nothing here fails
    /// status-only.
    static func inspectInlineArtifact(
        directory: URL
    ) -> Result<SpecDecArtifact, InlineArtifactRejection> {
        let directory = directory.standardizedFileURL
        guard isDirectoryResolvingSymlinks(directory) else {
            return rejectInline(
                "checkpoint directory is missing or not a directory: \(directory.path)")
        }
        let configURL = directory.appendingPathComponent("config.json")
        let indexURL = directory.appendingPathComponent("model.safetensors.index.json")
        guard let configSize = resolvedRegularFileSize(configURL), configSize > 0 else {
            return rejectInline(
                "config.json is missing, empty, not a regular file, or a broken symlink: \(configURL.path)")
        }
        guard configSize <= SpecDecLimits.maximumConfigBytes else {
            return rejectInline(
                "config.json exceeds the \(SpecDecLimits.maximumConfigBytes)-byte cap: \(configURL.path)")
        }
        guard let indexSize = resolvedRegularFileSize(indexURL), indexSize > 0 else {
            return rejectInline(
                "model.safetensors.index.json is missing, empty, not a regular file, or a broken symlink: \(indexURL.path)")
        }
        guard indexSize <= UInt64(SpecDecLimits.maximumManifestBytes) else {
            return rejectInline(
                "model.safetensors.index.json exceeds the \(SpecDecLimits.maximumManifestBytes)-byte cap: \(indexURL.path)")
        }
        guard let configData = try? Data(contentsOf: configURL) else {
            return rejectInline("config.json is unreadable: \(configURL.path)")
        }
        guard let indexData = try? Data(contentsOf: indexURL) else {
            return rejectInline(
                "model.safetensors.index.json is unreadable: \(indexURL.path)")
        }
        guard let root = try? JSONSerialization.jsonObject(with: configData) as? [String: Any]
        else {
            return rejectInline("config.json is not a JSON object: \(configURL.path)")
        }
        guard let inline = root["mtplx_mtp"] as? [String: Any],
            inline["included"] as? Bool == true
        else {
            return rejectInline(
                "config.json does not declare mtplx_mtp.included=true — not an inline-MTP checkpoint: \(configURL.path)")
        }
        guard root["mtplx_mtp_quantization"] as? [String: Any] != nil else {
            return rejectInline(
                "config.json is missing the mtplx_mtp_quantization object: \(configURL.path)")
        }
        guard let index = try? JSONDecoder().decode(InlineWeightIndex.self, from: indexData)
        else {
            return rejectInline(
                "model.safetensors.index.json does not decode (weight_map): \(indexURL.path)")
        }

        let prefix = (inline["prefix"] as? String) ?? "mtp."
        guard !prefix.isEmpty, prefix.utf8.count <= 128,
            prefix.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || $0 == 46 || $0 == 95
            })
        else {
            return rejectInline(
                "mtplx_mtp.prefix is empty, oversized, or carries disallowed characters: \(configURL.path)")
        }

        var shardNames = Set<String>()
        var inlineCount = 0
        for (key, shard) in index.weightMap where key.hasPrefix(prefix) {
            guard key.utf8.count <= 1024 else {
                return rejectInline("inline tensor key exceeds 1024 bytes in \(indexURL.path)")
            }
            guard shard == URL(fileURLWithPath: shard).lastPathComponent,
                shard.hasSuffix(".safetensors"),
                shard.utf8.count <= SpecDecLimits.maximumFileNameBytes
            else {
                return rejectInline(
                    "weight_map entry '\(key)' names an invalid shard '\(shard)' in \(indexURL.path)")
            }
            guard resolvedRegularFileSize(directory.appendingPathComponent(shard)) != nil
            else {
                return rejectInline(
                    "inline shard is missing, not a regular file, or a broken symlink: \(directory.appendingPathComponent(shard).path)")
            }
            inlineCount += 1
            shardNames.insert(shard)
        }
        guard inlineCount > 0 else {
            return rejectInline(
                "weight_map declares no tensors with prefix '\(prefix)': \(indexURL.path)")
        }
        guard inlineCount <= 512 else {
            return rejectInline(
                "weight_map declares \(inlineCount) inline tensors — above the 512 cap: \(indexURL.path)")
        }

        guard let declaredBytes = inlineTensorBytes(
            directory: directory,
            prefix: prefix,
            weightMap: index.weightMap),
            declaredBytes > 0,
            declaredBytes <= SpecDecLimits.maximumArtifactBytes
        else {
            return rejectInline(
                "inline tensor payload is unreadable or outside (0, \(SpecDecLimits.maximumArtifactBytes)] bytes (safetensors headers): \(directory.path)")
        }

        let configDigest = sha256Hex(configData)
        let indexDigest = sha256Hex(indexData)
        return .success(
            SpecDecArtifact(
                directory: directory,
                source: .inline,
                revision: "inline-\(configDigest.prefix(8))-\(indexDigest.prefix(8))",
                artifactBytes: declaredBytes,
                residentBytes: SpecDecLimits.residentEstimate(artifactBytes: declaredBytes),
                manifestSHA256: nil,
                localConfigSHA256: configDigest,
                inlineIndexSHA256: indexDigest))
    }

    /// Cheap discriminator used before inline inspection. Ordinary Qwen
    /// targets can pair with separately published MTP artifacts, so absence
    /// of `mtplx_mtp.included=true` must fall through to the catalog resolver
    /// without being logged as an invalid inline payload.
    static func declaresInlineArtifact(directory: URL) -> Bool {
        let configURL = directory.standardizedFileURL
            .appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
            data.count <= SpecDecLimits.maximumConfigBytes,
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let inline = root["mtplx_mtp"] as? [String: Any]
        else { return false }
        return inline["included"] as? Bool == true
    }

    private static func rejectInline(
        _ reason: String
    ) -> Result<SpecDecArtifact, InlineArtifactRejection> {
        logger.warning("inline MTP artifact rejected: \(reason)")
        return .failure(InlineArtifactRejection(description: reason))
    }

    /// Sum only selected tensor payload ranges from safetensors headers. This
    /// reads at most 16 MiB of metadata per shard and never maps/evaluates the
    /// multi-GiB target arrays merely to size the inline assistant.
    private static func inlineTensorBytes(
        directory: URL,
        prefix: String,
        weightMap: [String: String]
    ) -> UInt64? {
        let selected = weightMap.filter { $0.key.hasPrefix(prefix) }
        var headers: [String: [String: Any]] = [:]
        var total: UInt64 = 0
        for (key, shard) in selected {
            let header: [String: Any]
            if let cached = headers[shard] {
                header = cached
            } else {
                let url = directory.appendingPathComponent(shard)
                guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
                defer { try? handle.close() }
                guard let lengthData = try? handle.read(upToCount: 8),
                    lengthData.count == 8
                else { return nil }
                let headerLength = lengthData.withUnsafeBytes { raw -> UInt64 in
                    raw.loadUnaligned(as: UInt64.self).littleEndian
                }
                guard headerLength > 0, headerLength <= 16 * 1024 * 1024,
                    let data = try? handle.read(upToCount: Int(headerLength)),
                    data.count == Int(headerLength),
                    let object = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any]
                else { return nil }
                headers[shard] = object
                header = object
            }
            guard let entry = header[key] as? [String: Any],
                let offsets = entry["data_offsets"] as? [NSNumber], offsets.count == 2
            else { return nil }
            let start = offsets[0].uint64Value
            let end = offsets[1].uint64Value
            guard end > start else { return nil }
            let (sum, overflow) = total.addingReportingOverflow(end - start)
            guard !overflow else { return nil }
            total = sum
        }
        return total
    }

    /// Re-inspect the exact bytes immediately before assistant construction.
    /// Catalog artifacts are verified against their retained immutable trust
    /// reference; mutable local overrides must still match the inspected size
    /// and config revision used for admission.
    static func revalidateForLoad(_ artifact: SpecDecArtifact) -> SpecDecResolution {
        switch artifact.source {
        case .catalog:
            guard let reference = artifact.catalogReference else {
                return .fallback(
                    .warmArtifactCorrupt,
                    detail: "catalog artifact has no retained trust reference")
            }
            switch verifyPublishedArtifact(at: artifact.directory, reference: reference) {
            case .failure(let error):
                return .fallback(.warmArtifactCorrupt, detail: error.description)
            case .success(let verification):
                let refreshed = SpecDecArtifact(
                    directory: artifact.directory,
                    source: .catalog,
                    revision: reference.revision,
                    artifactBytes: verification.artifactBytes,
                    residentBytes: SpecDecLimits.residentEstimate(
                        artifactBytes: verification.artifactBytes),
                    manifestSHA256: verification.manifestSHA256,
                    catalogReference: reference)
                guard refreshed.artifactBytes == artifact.artifactBytes,
                    refreshed.residentBytes == artifact.residentBytes,
                    refreshed.revision == artifact.revision,
                    refreshed.manifestSHA256 == artifact.manifestSHA256
                else {
                    return .fallback(
                        .warmArtifactCorrupt,
                        detail: "catalog artifact facts changed after admission")
                }
                return .resolved(refreshed)
            }
        case .local:
            guard let refreshed = inspectLocalArtifact(path: artifact.directory.path),
                refreshed.directory == artifact.directory,
                refreshed.artifactBytes == artifact.artifactBytes,
                refreshed.residentBytes == artifact.residentBytes,
                refreshed.revision == artifact.revision,
                refreshed.localWeightSHA256 == artifact.localWeightSHA256,
                refreshed.localConfigSHA256 == artifact.localConfigSHA256
            else {
                return .fallback(
                    .localArtifactInvalid,
                    detail: "local assistant changed after admission")
            }
            return .resolved(refreshed)
        case .inline:
            let refreshed: SpecDecArtifact
            switch inspectInlineArtifact(directory: artifact.directory) {
            case .failure(let rejection):
                return .fallback(.inlineArtifactInvalid, detail: rejection.description)
            case .success(let inspected):
                refreshed = inspected
            }
            guard refreshed.directory == artifact.directory,
                refreshed.artifactBytes == artifact.artifactBytes,
                refreshed.residentBytes == artifact.residentBytes,
                refreshed.revision == artifact.revision,
                refreshed.localConfigSHA256 == artifact.localConfigSHA256,
                refreshed.inlineIndexSHA256 == artifact.inlineIndexSHA256
            else {
                return .fallback(
                    .inlineArtifactInvalid,
                    detail: "inline assistant metadata changed after admission")
            }
            return .resolved(refreshed)
        }
    }

    static func publishImmutable(
        staging: URL,
        destination: URL,
        reference: SpecDecArtifactReference
    ) -> Result<Verification, VerificationError> {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            return verifyPublishedArtifact(at: destination, reference: reference)
        }
        do {
            try fm.moveItem(at: staging, to: destination)
        } catch {
            // Another process may have won the immutable publication race.
            if fm.fileExists(atPath: destination.path) {
                return verifyPublishedArtifact(at: destination, reference: reference)
            }
            return .failure(.init(reason: .publicationFailed, description: "atomic directory publication failed"))
        }
        return verifyPublishedArtifact(at: destination, reference: reference)
    }

    private static func isDirectoryWithoutSymlink(_ url: URL) -> Bool {
        guard !isSymbolicLink(url),
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let type = attrs[.type] as? FileAttributeType
        else { return false }
        return type == .typeDirectory
    }

    private static func regularFileSize(_ url: URL) -> UInt64? {
        guard !isSymbolicLink(url),
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let type = attrs[.type] as? FileAttributeType, type == .typeRegular,
            let number = attrs[.size] as? NSNumber
        else { return nil }
        return number.uint64Value
    }

    /// Size of a regular file, RESOLVING symlinks — `attributesOfItem` does
    /// not follow a symlink in the last path component, so resolve first. A
    /// broken link keeps its unresolvable component and the attribute read
    /// then reports `.typeSymbolicLink` → nil. Used only by the inline
    /// inspection path; local-override inspection stays symlink-rejecting.
    private static func resolvedRegularFileSize(_ url: URL) -> UInt64? {
        let resolved = url.resolvingSymlinksInPath()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolved.path),
            let type = attrs[.type] as? FileAttributeType, type == .typeRegular,
            let number = attrs[.size] as? NSNumber
        else { return nil }
        return number.uint64Value
    }

    /// Directory check that FOLLOWS symlinks (inline inspection only).
    private static func isDirectoryResolvingSymlinks(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolved.path),
            let type = attrs[.type] as? FileAttributeType
        else { return false }
        return type == .typeDirectory
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    /// Hash once per file, in bounded chunks, checking cancellation between
    /// chunks. The resulting digest serves both the per-file manifest check and
    /// aggregate digest, avoiding the prior second full artifact read.
    private static func digestRegularFile(at url: URL) -> SHA256Digest? {
        guard regularFileSize(url) != nil,
            let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            guard !Task.isCancelled else { return nil }
            do {
                guard let chunk = try handle.read(upToCount: 1024 * 1024) else {
                    return hasher.finalize()
                }
                if chunk.isEmpty { return hasher.finalize() }
                hasher.update(data: chunk)
            } catch {
                return nil
            }
        }
    }

    private static func hex(_ digest: SHA256Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
