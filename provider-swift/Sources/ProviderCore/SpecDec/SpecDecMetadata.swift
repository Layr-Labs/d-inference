import Foundation

struct SpecDecArtifactReference: Sendable, Equatable, Hashable {
    let r2Prefix: String
    let manifestSHA256: String
    let expectedTotalBytes: UInt64
    let expectedFileCount: Int
    let maximumFileCount: Int
    let allowedFileRoles: Set<String>
    let configSHA256: String
    let revision: String
}

struct SpecDecMetadataError: Error, Sendable, CustomStringConvertible {
    let reason: MTPFallbackReason
    let description: String
}

enum SpecDecMetadata {
    static func reference(for model: CatalogModel) -> Result<SpecDecArtifactReference, SpecDecMetadataError> {
        guard let raw = model.metadata?["spec_dec"] else {
            return .failure(.init(reason: .metadataMissing, description: "spec_dec is absent"))
        }
        guard case .object(let pairs) = raw else {
            return .failure(.init(reason: .metadataMalformed, description: "spec_dec is not an object"))
        }
        let keys = pairs.map(\.0)
        guard Set(keys).count == keys.count else {
            return .failure(.init(reason: .metadataMalformed, description: "spec_dec has duplicate keys"))
        }
        let values = Dictionary(uniqueKeysWithValues: pairs)

        guard case .string(let rawPrefix)? = values["r2_prefix"] else {
            return .failure(.init(reason: .metadataMalformed, description: "r2_prefix is missing or not a string"))
        }
        let prefix = rawPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validPrefix(prefix) else {
            return .failure(.init(reason: .metadataMalformed, description: "r2_prefix is invalid"))
        }

        func digest(_ key: String) -> Result<String?, SpecDecMetadataError> {
            guard let value = values[key] else { return .success(nil) }
            guard case .string(let raw) = value, isSHA256(raw) else {
                return .failure(.init(reason: .metadataMalformed, description: "\(key) is not a SHA-256 hex digest"))
            }
            return .success(raw.lowercased())
        }

        let manifestDigest: String
        let configDigest: String
        switch digest("manifest_sha256") {
        case .success(let value):
            guard let value else {
                return .failure(.init(
                    reason: .metadataMalformed,
                    description: "manifest_sha256 is required"))
            }
            manifestDigest = value
        case .failure(let error): return .failure(error)
        }
        let configDigestResult = values["config_sha256"] != nil
            ? digest("config_sha256") : digest("family_digest")
        switch configDigestResult {
        case .success(let value):
            guard let value else {
                return .failure(.init(
                    reason: .metadataMalformed,
                    description: "config_sha256 or family_digest is required"))
            }
            configDigest = value
        case .failure(let error): return .failure(error)
        }

        let expectedBytes: UInt64
        switch boundedUInt(values["total_size_bytes"], maximum: SpecDecLimits.maximumArtifactBytes) {
        case .success(let value):
            guard let value else {
                return .failure(.init(
                    reason: .metadataMalformed,
                    description: "total_size_bytes is required"))
            }
            expectedBytes = value
        case .failure(let error): return .failure(error)
        }
        let expectedCount: Int
        switch boundedInt(values["file_count"], maximum: SpecDecLimits.maximumFileCount) {
        case .success(let value):
            guard let value else {
                return .failure(.init(
                    reason: .metadataMalformed,
                    description: "file_count is required"))
            }
            expectedCount = value
        case .failure(let error): return .failure(error)
        }
        let maximumCount: Int
        switch boundedInt(values["max_file_count"], maximum: SpecDecLimits.maximumFileCount) {
        case .success(let value):
            guard let value else {
                return .failure(.init(
                    reason: .metadataMalformed,
                    description: "max_file_count is required"))
            }
            maximumCount = value
        case .failure(let error): return .failure(error)
        }
        if expectedCount > maximumCount {
            return .failure(.init(reason: .metadataMalformed, description: "file_count exceeds max_file_count"))
        }

        guard let rawRoles = values["allowed_file_types"] ?? values["allowed_file_roles"],
            case .array(let array) = rawRoles, !array.isEmpty,
            array.count <= SpecDecLimits.allowedRoles.count
        else {
            return .failure(.init(reason: .metadataMalformed, description: "allowed_file_types is required and must be bounded"))
        }
        var roles = Set<String>()
        for item in array {
            guard case .string(let role) = item, role.utf8.count <= 32,
                SpecDecLimits.allowedRoles.contains(role), roles.insert(role).inserted
            else {
                return .failure(.init(reason: .metadataMalformed, description: "allowed_file_types contains a duplicate or unsupported role"))
            }
        }
        guard roles.contains("config"), roles.contains("weight") else {
            return .failure(.init(reason: .metadataMalformed, description: "assistant requires config and weight file roles"))
        }

        guard case .string(let revision)? = values["revision"], !revision.isEmpty,
            revision.utf8.count <= SpecDecLimits.maximumRevisionBytes,
            validIdentifier(revision)
        else {
            return .failure(.init(reason: .metadataMalformed, description: "revision is required and must be valid"))
        }

        return .success(
            SpecDecArtifactReference(
                r2Prefix: prefix,
                manifestSHA256: manifestDigest,
                expectedTotalBytes: expectedBytes,
                expectedFileCount: expectedCount,
                maximumFileCount: maximumCount,
                allowedFileRoles: roles,
                configSHA256: configDigest,
                revision: revision))
    }

    static func validPrefix(_ prefix: String) -> Bool {
        guard !prefix.isEmpty, prefix.utf8.count <= SpecDecLimits.maximumPrefixBytes,
            !prefix.hasPrefix("/"), !prefix.contains("\\"),
            !prefix.contains("?"), !prefix.contains("#")
        else { return false }
        let parts = prefix.split(separator: "/", omittingEmptySubsequences: false)
        return parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".."
                && part.utf8.count <= SpecDecLimits.maximumFileNameBytes
                && validIdentifier(String(part))
        }
    }

    static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }

    private static func boundedUInt(
        _ value: JSONValue?, maximum: UInt64
    ) -> Result<UInt64?, SpecDecMetadataError> {
        guard let value else { return .success(nil) }
        guard case .int(let raw) = value, raw > 0, UInt64(raw) <= maximum else {
            return .failure(.init(reason: .metadataMalformed, description: "numeric metadata is out of bounds"))
        }
        return .success(UInt64(raw))
    }

    private static func boundedInt(
        _ value: JSONValue?, maximum: Int
    ) -> Result<Int?, SpecDecMetadataError> {
        guard let value else { return .success(nil) }
        guard case .int(let raw) = value, raw > 0, raw <= Int64(maximum) else {
            return .failure(.init(reason: .metadataMalformed, description: "count metadata is out of bounds"))
        }
        return .success(Int(raw))
    }
}
