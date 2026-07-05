/// ModelCatalog -- coordinator-side catalog client and on-disk model
/// download / removal.
///
/// The coordinator owns the canonical catalog at `GET /v1/models/catalog`.
/// Providers fetch it to know which model IDs are servable; the same
/// endpoint is consumed by the console UI and the `darkbloom models`
/// CLI verb.
///
/// Downloads pull from R2 directly (the coordinator never fronts model
/// weights). The model lives in the standard HuggingFace cache layout
/// at `~/.cache/huggingface/hub/models--{org}--{name}/snapshots/{hash}/`,
/// matching what `ModelScanner` already discovers.

import Foundation

// MARK: - Download progress tracking & rendering
//
// Progress state (`FileProgress`, `ManifestDownloadProgress`) and terminal
// rendering (`ProgressRenderer`) live in `ModelDownloadProgress.swift` so this
// file stays focused on catalog + download orchestration.

// MARK: - Catalog model

public struct CatalogModel: Codable, Sendable, Equatable {
    public let id: String
    public let s3Name: String
    public let displayName: String
    public let modelType: String
    public let sizeGb: Double
    public let architecture: String?
    public let description: String?
    public let minRamGb: Int?
    public let active: Bool?
    public let weightHash: String?
    public let version: String?
    public let r2Prefix: String?
    public let aggregateSHA256: String?
    public let totalSizeBytes: Int64?
    public let fileCount: Int?
    public let family: String?
    public let quantization: String?
    public let maxContextLength: Int?
    public let maxOutputLength: Int?
    public let capabilities: [String]?
    public let runtimeParameters: [String: JSONValue]?
    public let metadata: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case id
        case s3Name = "s3_name"
        case displayName = "display_name"
        case modelType = "model_type"
        case sizeGb = "size_gb"
        case architecture
        case description
        case minRamGb = "min_ram_gb"
        case active
        case weightHash = "weight_hash"
        case version
        case r2Prefix = "r2_prefix"
        case aggregateSHA256 = "aggregate_sha256"
        case totalSizeBytes = "total_size_bytes"
        case fileCount = "file_count"
        case family
        case quantization
        case maxContextLength = "max_context_length"
        case maxOutputLength = "max_output_length"
        case capabilities
        case runtimeParameters = "runtime_parameters"
        case metadata
    }

    public init(
        id: String,
        s3Name: String,
        displayName: String,
        modelType: String = "text",
        sizeGb: Double,
        architecture: String? = nil,
        description: String? = nil,
        minRamGb: Int? = nil,
        active: Bool? = nil,
        weightHash: String? = nil,
        version: String? = nil,
        r2Prefix: String? = nil,
        aggregateSHA256: String? = nil,
        totalSizeBytes: Int64? = nil,
        fileCount: Int? = nil,
        family: String? = nil,
        quantization: String? = nil,
        maxContextLength: Int? = nil,
        maxOutputLength: Int? = nil,
        capabilities: [String]? = nil,
        runtimeParameters: [String: JSONValue]? = nil,
        metadata: [String: JSONValue]? = nil
    ) {
        self.id = id
        self.s3Name = s3Name
        self.displayName = displayName
        self.modelType = modelType
        self.sizeGb = sizeGb
        self.architecture = architecture
        self.description = description
        self.minRamGb = minRamGb
        self.active = active
        self.weightHash = weightHash
        self.version = version
        self.r2Prefix = r2Prefix
        self.aggregateSHA256 = aggregateSHA256
        self.totalSizeBytes = totalSizeBytes
        self.fileCount = fileCount
        self.family = family
        self.quantization = quantization
        self.maxContextLength = maxContextLength
        self.maxOutputLength = maxOutputLength
        self.capabilities = capabilities
        self.runtimeParameters = runtimeParameters
        self.metadata = metadata
    }
}

public struct CatalogAlias: Codable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let desiredBuild: String
    public let previousBuild: String?
    public let retiredBuilds: [String]?
    public let primaryBuild: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case desiredBuild = "desired_build"
        case previousBuild = "previous_build"
        case retiredBuilds = "retired_builds"
        case primaryBuild = "primary_build"
    }
}

public struct CatalogSnapshot: Sendable, Equatable {
    public let models: [CatalogModel]
    public let aliases: [CatalogAlias]
}

internal struct CatalogResponse: Codable {
    let models: [CatalogModel]
    let aliases: [CatalogAlias]?
}

// MARK: - Errors

public enum ModelCatalogError: Error, CustomStringConvertible, LocalizedError, Sendable {
    case unreachable(String)
    case http(Int, String)
    case decodeFailed(String)
    case modelNotInCatalog(String)
    case downloadFailed(String)

    public var description: String {
        switch self {
        case .unreachable(let d):           "coordinator unreachable: \(d)"
        case .http(let code, let body):     "coordinator HTTP \(code): \(body)"
        case .decodeFailed(let d):          "could not decode catalog response: \(d)"
        case .modelNotInCatalog(let id):    "model '\(id)' is not in the coordinator catalog"
        case .downloadFailed(let d):        "download failed: \(d)"
        }
    }

    public var errorDescription: String? { description }
}

