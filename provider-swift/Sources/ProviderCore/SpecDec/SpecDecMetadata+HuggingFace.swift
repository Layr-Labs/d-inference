import Foundation

extension SpecDecMetadata {
    /// The registry manifest remains the byte authority for both sources.
    /// Never derive an assistant repository from the target or use a branch.
    static func pinnedHuggingFaceArtifact(_ value: JSONValue?) throws -> HuggingFaceArtifact? {
        guard let value else { return nil }
        if case .null = value { return nil }
        guard case .object(let pairs) = value,
            Set(pairs.map(\.0)).count == pairs.count
        else { throw malformedHuggingFaceArtifact() }
        let values = Dictionary(uniqueKeysWithValues: pairs)
        guard case .string(let repoID)? = values["repo_id"],
            case .string(let revision)? = values["revision"]
        else { throw malformedHuggingFaceArtifact() }
        let pathPrefix: String?
        switch values["path_prefix"] {
        case nil, .null?: pathPrefix = nil
        case .string(let value)?: pathPrefix = value
        default: throw malformedHuggingFaceArtifact()
        }
        let artifact = HuggingFaceArtifact(repoID: repoID, revision: revision, pathPrefix: pathPrefix)
        // Reuse ordinary-weight URL validation, including the immutable SHA
        // and safe repository/path rules, before scheduling any network IO.
        _ = try artifact.downloadURL(for: "config.json")
        return artifact
    }

    private static func malformedHuggingFaceArtifact() -> SpecDecMetadataError {
        .init(reason: .metadataMalformed, description: "hugging_face_artifact is malformed")
    }
}
