import Foundation

/// Exact artifact bytes; separate from the upstream repository used for metadata.
/// Only public, ungated repositories are needed: no publisher credentials are sent.
public struct HuggingFaceArtifact: Codable, Sendable, Equatable {
    public let repoID: String
    public let revision: String
    public let pathPrefix: String?

    public init(repoID: String, revision: String, pathPrefix: String? = nil) {
        self.repoID = repoID
        self.revision = revision
        self.pathPrefix = pathPrefix
    }

    enum CodingKeys: String, CodingKey {
        case repoID = "repo_id"
        case revision
        case pathPrefix = "path_prefix"
    }

    internal func downloadURL(for relativePath: String) throws -> URL {
        let components = repoID.split(separator: "/", omittingEmptySubsequences: false)
        guard repoID.utf8.count <= 192, components.count == 2,
              components.allSatisfy({ Self.validComponent(String($0)) }),
              revision.utf8.count == 40,
              revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ModelCatalogError.downloadFailed("invalid Hugging Face repository or commit revision")
        }
        let prefix = pathPrefix ?? ""
        guard prefix.utf8.count <= 1024,
              prefix.isEmpty || prefix.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy({ Self.validComponent(String($0)) }) else {
            throw ModelCatalogError.downloadFailed("invalid Hugging Face artifact path_prefix")
        }
        let path = try ModelDownloader.validatedManifestRelativePath(relativePath)
        let artifactPath = prefix.isEmpty ? path : "\(prefix)/\(path)"
        // Escape per component, including literal percent, query and fragment characters.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let escaped = artifactPath.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "/")
        guard let url = URL(string: "https://huggingface.co/\(repoID)/resolve/\(revision)/\(escaped)") else {
            throw ModelCatalogError.downloadFailed("invalid Hugging Face file URL")
        }
        return url
    }

    private static func validComponent(_ value: String) -> Bool {
        guard let first = value.utf8.first,
              (48...57).contains(first) || (65...90).contains(first)
                || (97...122).contains(first) || first == 95,
              !value.contains("..") else { return false }
        return value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || $0 == 95 || $0 == 45 || $0 == 46
        }
    }
}
