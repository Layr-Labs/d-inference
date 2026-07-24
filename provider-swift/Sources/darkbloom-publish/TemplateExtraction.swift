import Crypto
import Foundation
import ProviderCoreFoundation

/// Pure logic for the `extract-template` republish flow: pull the chat
/// template out of a tokenizer_config.json, validate it is safe to republish,
/// and derive a new manifest version from an old manifest's per-file digests
/// plus the extracted template file — without ever reading weight bytes.
///
/// Kept IO-free so DarkbloomPublishTests can exercise every branch; the
/// command (`ExtractTemplateCommand`) does the file reads/writes.
enum TemplateExtraction {

    /// The standalone template filename `PromptContractIdentity` requires.
    static let templateFilename = "chat_template.jinja"

    enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case manifestAlreadyHasTemplate(modelID: String)
        case unsupportedSchemaVersion(Int)
        case invalidModelID(String)
        case invalidManifestFilePath(String)
        case duplicateManifestFilePath(String)
        case invalidManifestFileDigest(path: String)
        case inconsistentManifest(String)
        case tokenizerConfigNotJSONObject
        case chatTemplateKeyMissing
        case chatTemplateEmpty
        case chatTemplateArrayWithoutDefault
        case chatTemplateUnsupportedShape
        case dynamicDateTemplate
        case aggregateComputationFailed

        var description: String {
            switch self {
            case .manifestAlreadyHasTemplate(let modelID):
                return "model \(modelID) already has a standalone \(templateFilename) in its manifest — nothing to republish"
            case .unsupportedSchemaVersion(let v):
                return "unsupported manifest schema_version \(v) (expected \(ManifestBuilder.schemaVersion))"
            case .invalidModelID(let reason):
                return "old manifest model_id is invalid: \(reason)"
            case .invalidManifestFilePath(let path):
                return "old manifest file path \(path) is invalid (must be a clean relative POSIX path)"
            case .duplicateManifestFilePath(let path):
                return "old manifest file path \(path) is duplicated (case-insensitive)"
            case .invalidManifestFileDigest(let path):
                return "old manifest file \(path) has an invalid sha256 (must be 64 lowercase hex characters)"
            case .inconsistentManifest(let reason):
                return "old manifest is internally inconsistent (\(reason)) — refusing to derive a new version from it"
            case .tokenizerConfigNotJSONObject:
                return "tokenizer_config.json is not a JSON object"
            case .chatTemplateKeyMissing:
                return "tokenizer_config.json has no \"chat_template\" key — nothing to extract"
            case .chatTemplateEmpty:
                return "tokenizer_config.json \"chat_template\" is empty"
            case .chatTemplateArrayWithoutDefault:
                return "tokenizer_config.json \"chat_template\" is a template list without a \"default\" entry"
            case .chatTemplateUnsupportedShape:
                return "tokenizer_config.json \"chat_template\" is neither a string nor a [{name, template}] list"
            case .dynamicDateTemplate:
                return "template contains strftime_now — dynamic-date templates cannot produce deterministic prompt contracts and must not be republished"
            case .aggregateComputationFailed:
                return "failed to recompute the aggregate hash from per-file digests"
            }
        }
    }

    // MARK: - Old-manifest validation

    /// Reject manifests the republish flow cannot or must not process: wrong
    /// schema, an existing standalone template entry, per-file digests the
    /// coordinator would reject (non-lowercase / non-hex), or internal
    /// inconsistency (aggregate / file_count / total_size not matching the
    /// file list — the same checks the coordinator runs on register). The new
    /// manifest is derived purely from these digests, so garbage in must not
    /// become a registered version.
    static func validateOldManifest(_ manifest: ModelManifest) throws {
        guard manifest.schemaVersion == ManifestBuilder.schemaVersion else {
            throw Error.unsupportedSchemaVersion(manifest.schemaVersion)
        }
        do {
            try ManifestBuilder.validateModelID(manifest.modelID)
        } catch let ManifestBuilder.Error.invalidModelID(_, reason) {
            throw Error.invalidModelID(reason)
        }
        // Case-insensitive, like the coordinator's duplicate-path check — a
        // manifest carrying any casing of chat_template.jinja would collide
        // with the file this flow adds.
        if manifest.files.contains(where: { $0.path.lowercased() == templateFilename }) {
            throw Error.manifestAlreadyHasTemplate(modelID: manifest.modelID)
        }
        var seenPaths = Set<String>()
        for file in manifest.files {
            guard isValidRelativePath(file.path) else {
                throw Error.invalidManifestFilePath(file.path)
            }
            guard seenPaths.insert(file.path.lowercased()).inserted else {
                throw Error.duplicateManifestFilePath(file.path)
            }
            guard isLowerSHA256Hex(file.sha256) else {
                throw Error.invalidManifestFileDigest(path: file.path)
            }
            guard file.sizeBytes >= 0 else {
                throw Error.inconsistentManifest(
                    "negative size_bytes for \(file.path)")
            }
        }
        guard manifest.fileCount == manifest.files.count else {
            throw Error.inconsistentManifest(
                "file_count \(manifest.fileCount) != files length \(manifest.files.count)")
        }
        let totalSize = manifest.files.reduce(Int64(0)) { $0 + $1.sizeBytes }
        guard manifest.totalSizeBytes == totalSize else {
            throw Error.inconsistentManifest(
                "total_size_bytes \(manifest.totalSizeBytes) != files sum \(totalSize)")
        }
        guard let aggregate = WeightHasher.aggregateFromDigests(
            manifest.files.map { (path: $0.path, sha256Hex: $0.sha256) }
        ), aggregate == manifest.aggregateSHA256 else {
            throw Error.inconsistentManifest("aggregate_sha256 does not match the per-file digests")
        }
    }

    // MARK: - Template extraction

    /// Extract the chat template string from tokenizer_config.json bytes.
    ///
    /// Handles both shapes the ecosystem produces:
    /// - `"chat_template": "<template>"` (plain string), and
    /// - `"chat_template": [{"name": ..., "template": ...}, ...]` (named
    ///   list — the entry named "default" is taken; a list without one is an
    ///   error rather than a guess).
    ///
    /// The returned string is the decoded template exactly as the JSON
    /// decoder unescapes it (\n, \", \uXXXX handled); callers write it as
    /// UTF-8 with no added trailing newline so the standalone file is
    /// byte-exact.
    static func extractTemplate(fromTokenizerConfig data: Data) throws -> String {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Error.tokenizerConfigNotJSONObject
        }
        guard let value = json["chat_template"] else {
            throw Error.chatTemplateKeyMissing
        }
        if let template = value as? String {
            guard !template.isEmpty else { throw Error.chatTemplateEmpty }
            return template
        }
        if let entries = value as? [Any] {
            for entry in entries {
                guard let dict = entry as? [String: Any] else { continue }
                if dict["name"] as? String == "default", let template = dict["template"] as? String {
                    guard !template.isEmpty else { throw Error.chatTemplateEmpty }
                    return template
                }
            }
            throw Error.chatTemplateArrayWithoutDefault
        }
        throw Error.chatTemplateUnsupportedShape
    }

    /// Templates that read the wall clock render differently on every day,
    /// so their prompt contract is not deterministic — refuse to republish.
    static func validateDeterministic(template: String) throws {
        if template.contains("strftime_now") {
            throw Error.dynamicDateTemplate
        }
    }

    // MARK: - New-manifest derivation

    /// Build the republished manifest: same model id, old files plus the new
    /// template entry, new version, the canonical r2_prefix for that version
    /// (same derivation as `ManifestBuilder.build` and the coordinator's
    /// `modelR2Prefix`), and the aggregate recomputed from per-file digests
    /// only.
    static func buildRepublishManifest(
        oldManifest: ModelManifest,
        newVersion: String,
        templateFile: ManifestFile
    ) throws -> ModelManifest {
        var files = oldManifest.files + [templateFile]
        files.sort {
            if $0.path != $1.path { return $0.path < $1.path }
            return $0.sha256 < $1.sha256
        }

        guard let aggregate = WeightHasher.aggregateFromDigests(
            files.map { (path: $0.path, sha256Hex: $0.sha256) }
        ) else {
            throw Error.aggregateComputationFailed
        }

        let r2Prefix = "v2/\(ManifestBuilder.safeModelID(oldManifest.modelID))/\(newVersion)"

        return ModelManifest(
            schemaVersion: ManifestBuilder.schemaVersion,
            modelID: oldManifest.modelID,
            version: newVersion,
            r2Prefix: r2Prefix,
            aggregateSHA256: aggregate,
            totalSizeBytes: files.reduce(0) { $0 + $1.sizeBytes },
            fileCount: files.count,
            files: files,
            createdAt: Date()
        )
    }

    /// Whether the old manifest's r2_prefix still matches today's derivation
    /// for its own (model id, version). A mismatch is not fatal — the new
    /// prefix is derived independently and is what the coordinator will
    /// expect — but it is surprising enough to surface to the operator.
    static func oldPrefixMatchesDerivation(_ manifest: ModelManifest) -> Bool {
        manifest.r2Prefix == "v2/\(ManifestBuilder.safeModelID(manifest.modelID))/\(manifest.version)"
    }

    private static func isLowerSHA256Hex(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { ("0" ... "9").contains($0) || ("a" ... "f").contains($0) }
    }

    /// Mirror of the coordinator's `validManifestRelativePath`: non-empty,
    /// relative, forward-slash separated, no empty / "." / ".." segments.
    private static func isValidRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
