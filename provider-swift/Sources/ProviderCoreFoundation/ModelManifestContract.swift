import Foundation

/// Schema-v1 transport and structure limits for model manifests.
///
/// The coordinator mirrors these values when it accepts a registry publish.
/// Keeping the contract next to the wire types lets both coordinator-backed
/// and direct-CDN provider paths use exactly the same validation.
public enum ModelManifestContract {
    public static let maximumEncodedBytes = 1 * 1024 * 1024
    public static let maximumFileCount = 16_384
    public static let maximumStringBytes = 256 * 1024

    public enum ValidationError: Error, CustomStringConvertible, LocalizedError, Sendable {
        case encodedSizeExceeded(actual: Int)
        case unsupportedSchemaVersion(Int)
        case fileCountOutOfRange(Int)
        case fileArrayCountOutOfRange(Int)
        case fileCountMismatch(declared: Int, actual: Int)
        case fieldTooLarge
        case negativeTotalSize(Int64)
        case negativeFileSize(path: String, size: Int64)
        case duplicateFilePath(path: String)
        case totalSizeOverflow
        case totalSizeMismatch(declared: Int64, actual: Int64)

        public var description: String {
            switch self {
            case .encodedSizeExceeded(let actual):
                return "manifest response is \(actual) bytes; limit is \(ModelManifestContract.maximumEncodedBytes)"
            case .unsupportedSchemaVersion(let version):
                return "unsupported manifest schema_version \(version)"
            case .fileCountOutOfRange(let count):
                return "manifest file_count \(count) is outside 1...\(ModelManifestContract.maximumFileCount)"
            case .fileArrayCountOutOfRange(let count):
                return "manifest files count \(count) is outside 1...\(ModelManifestContract.maximumFileCount)"
            case .fileCountMismatch(let declared, let actual):
                return "manifest file_count \(declared) does not match files count \(actual)"
            case .fieldTooLarge:
                return "manifest field exceeds provider structural bound"
            case .negativeTotalSize(let size):
                return "manifest total_size_bytes \(size) must be nonnegative"
            case .negativeFileSize(let path, let size):
                return "manifest file \(path) size_bytes \(size) must be nonnegative"
            case .duplicateFilePath(let path):
                return "manifest file path \(path) is duplicated"
            case .totalSizeOverflow:
                return "manifest file sizes overflow Int64"
            case .totalSizeMismatch(let declared, let actual):
                return "manifest total_size_bytes \(declared) does not match files sum \(actual)"
            }
        }

        public var errorDescription: String? { description }
    }

    public static func validateEncodedByteCount(_ count: Int) throws {
        guard count <= maximumEncodedBytes else {
            throw ValidationError.encodedSizeExceeded(actual: count)
        }
    }

    public static func validate(_ manifest: ModelManifest) throws {
        guard manifest.schemaVersion == 1 else {
            throw ValidationError.unsupportedSchemaVersion(manifest.schemaVersion)
        }
        guard (1...maximumFileCount).contains(manifest.fileCount) else {
            throw ValidationError.fileCountOutOfRange(manifest.fileCount)
        }
        guard (1...maximumFileCount).contains(manifest.files.count) else {
            throw ValidationError.fileArrayCountOutOfRange(manifest.files.count)
        }
        guard manifest.fileCount == manifest.files.count else {
            throw ValidationError.fileCountMismatch(
                declared: manifest.fileCount,
                actual: manifest.files.count)
        }

        let topLevelStrings = [
            manifest.modelID,
            manifest.version,
            manifest.r2Prefix,
            manifest.aggregateSHA256,
        ]
        guard topLevelStrings.allSatisfy({ $0.utf8.count <= maximumStringBytes }),
              manifest.files.allSatisfy({ file in
                  file.path.utf8.count <= maximumStringBytes
                      && file.sha256.utf8.count <= maximumStringBytes
                      && file.role.utf8.count <= maximumStringBytes
              })
        else {
            throw ValidationError.fieldTooLarge
        }

        guard manifest.totalSizeBytes >= 0 else {
            throw ValidationError.negativeTotalSize(manifest.totalSizeBytes)
        }
        let total = try checkedTotalSize(manifest.files)
        guard total == manifest.totalSizeBytes else {
            throw ValidationError.totalSizeMismatch(
                declared: manifest.totalSizeBytes,
                actual: total)
        }
    }

    public static func checkedTotalSize(_ files: [ManifestFile]) throws -> Int64 {
        var total: Int64 = 0
        var seenPaths = Set<String>()
        for file in files {
            guard file.sizeBytes >= 0 else {
                throw ValidationError.negativeFileSize(path: file.path, size: file.sizeBytes)
            }
            // Match the coordinator's lowercase uniqueness key for download destinations.
            guard seenPaths.insert(file.path.lowercased()).inserted else {
                throw ValidationError.duplicateFilePath(path: file.path)
            }
            let (next, overflow) = total.addingReportingOverflow(file.sizeBytes)
            guard !overflow else {
                throw ValidationError.totalSizeOverflow
            }
            total = next
        }
        return total
    }
}
