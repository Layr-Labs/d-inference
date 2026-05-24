import Foundation

/// Top-level manifest emitted by `darkbloom-publish hash`. Pinned by
/// `schemaVersion = 1` for now; bumping requires a coordinator-side reader
/// upgrade.
public struct ModelManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let modelID: String
    public let version: String
    public let r2Prefix: String
    public let aggregateSHA256: String
    public let totalSizeBytes: Int64
    public let fileCount: Int
    public let files: [ManifestFile]
    public let createdAt: Date

    public init(schemaVersion: Int, modelID: String, version: String, r2Prefix: String,
                aggregateSHA256: String, totalSizeBytes: Int64, fileCount: Int,
                files: [ManifestFile], createdAt: Date) {
        self.schemaVersion = schemaVersion
        self.modelID = modelID
        self.version = version
        self.r2Prefix = r2Prefix
        self.aggregateSHA256 = aggregateSHA256
        self.totalSizeBytes = totalSizeBytes
        self.fileCount = fileCount
        self.files = files
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case modelID = "model_id"
        case version
        case r2Prefix = "r2_prefix"
        case aggregateSHA256 = "aggregate_sha256"
        case totalSizeBytes = "total_size_bytes"
        case fileCount = "file_count"
        case files
        case createdAt = "created_at"
    }
}

/// Per-file entry in a `ModelManifest`. Relative paths use forward slashes so
/// the manifest is location-independent and portable between macOS providers
/// and the Linux publish VM.
public struct ManifestFile: Codable, Sendable, Equatable {
    public let path: String          // relative to model directory, forward-slash separated
    public let sizeBytes: Int64
    public let sha256: String        // lowercase hex
    public let role: String          // weight | tokenizer | config | template | preprocessor | index | other

    public init(path: String, sizeBytes: Int64, sha256: String, role: String) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.role = role
    }

    enum CodingKeys: String, CodingKey {
        case path
        case sizeBytes = "size_bytes"
        case sha256
        case role
    }
}
