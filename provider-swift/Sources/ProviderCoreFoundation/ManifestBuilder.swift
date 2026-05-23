import Crypto
import Foundation
import Logging

/// Builds a `ModelManifest` for a HuggingFace snapshot directory. Used by the
/// `darkbloom-publish hash` subcommand on the GCP publish VM.
public enum ManifestBuilder {

    private static let logger = Logger(label: "darkbloom.ManifestBuilder")

    public enum Error: Swift.Error, CustomStringConvertible {
        case directoryNotFound(URL)
        case noFilesFound(URL)
        case fileReadFailed(URL, Swift.Error)
        case invalidModelID(String, reason: String)
        case invalidVersion(String, reason: String)

        public var description: String {
            switch self {
            case .directoryNotFound(let url):
                return "Model directory not found: \(url.path)"
            case .noFilesFound(let url):
                return "No integrity-relevant files found under: \(url.path)"
            case .fileReadFailed(let url, let underlying):
                return "Failed to read \(url.path): \(underlying)"
            case .invalidModelID(let id, let reason):
                return "Invalid model id \"\(id)\": \(reason)"
            case .invalidVersion(let v, let reason):
                return "Invalid version \"\(v)\": \(reason)"
            }
        }
    }

    /// ASCII alphanumeric scalar set used by `validateModelID` and
    /// `validateVersion`. We deliberately restrict to ASCII so the resulting
    /// R2 prefix and manifest are byte-identical regardless of the publisher's
    /// locale.
    private static func isAllowedIDByte(_ ch: Character, allowSlash: Bool) -> Bool {
        guard let ascii = ch.asciiValue else { return false }
        // 0-9
        if ascii >= 0x30 && ascii <= 0x39 { return true }
        // A-Z
        if ascii >= 0x41 && ascii <= 0x5A { return true }
        // a-z
        if ascii >= 0x61 && ascii <= 0x7A { return true }
        // . _ -
        if ascii == 0x2E || ascii == 0x5F || ascii == 0x2D { return true }
        if allowSlash && ascii == 0x2F { return true }
        return false
    }

    /// Validate a model ID. Allowed characters: `A-Z`, `a-z`, `0-9`, `.`, `_`,
    /// `-`, and `/` (HuggingFace's `org/name` separator). Must be non-empty,
    /// must not begin with `/`, and must not contain `..` segments.
    ///
    /// Throws `Error.invalidModelID` on rejection.
    public static func validateModelID(_ id: String) throws {
        if id.isEmpty {
            throw Error.invalidModelID(id, reason: "must be non-empty")
        }
        if id.hasPrefix("/") {
            throw Error.invalidModelID(id, reason: "must not start with '/'")
        }
        if id.contains("..") {
            throw Error.invalidModelID(id, reason: "must not contain '..'")
        }
        for ch in id {
            if !isAllowedIDByte(ch, allowSlash: true) {
                throw Error.invalidModelID(id, reason: "contains disallowed character '\(ch)'")
            }
        }
    }

    /// Validate a version tag. Allowed characters: `A-Z`, `a-z`, `0-9`, `.`,
    /// `_`, `-`. Must be non-empty and must not contain `..` or `/`.
    public static func validateVersion(_ version: String) throws {
        if version.isEmpty {
            throw Error.invalidVersion(version, reason: "must be non-empty")
        }
        if version.contains("..") {
            throw Error.invalidVersion(version, reason: "must not contain '..'")
        }
        if version.hasPrefix("/") {
            throw Error.invalidVersion(version, reason: "must not start with '/'")
        }
        for ch in version {
            if !isAllowedIDByte(ch, allowSlash: false) {
                throw Error.invalidVersion(version, reason: "contains disallowed character '\(ch)'")
            }
        }
    }

    /// Schema version emitted by `build(...)`. Bump only when manifest
    /// semantics change in a backwards-incompatible way.
    public static let schemaVersion = 1

    /// Scan `modelDirectory`, hash every integrity file (with the expanded
    /// allow-list and recursion), and produce a `ModelManifest`.
    ///
    /// - `r2_prefix = "v2/\(safeID)/\(version)"` where `safeID` is a
    ///   human-readable model slug plus a short SHA-256 suffix. The suffix
    ///   prevents collisions such as `foo/bar` vs. `foo__bar`.
    /// - `aggregate_sha256` = SHA-256 over the concatenated raw 32-byte
    ///   per-file digests, sorted by relative POSIX path. Location-independent
    ///   so the same bytes laid out under a different parent path produce
    ///   the same hash.
    public static func build(modelDirectory: URL, modelID: String, version: String) async throws -> ModelManifest {
        // 0) Defense-in-depth: even if the CLI already validated these, reject
        // unsafe inputs here so library callers can't slip past validation.
        try validateModelID(modelID)
        try validateVersion(version)

        let fm = FileManager.default

        // 1) Ensure directory exists.
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: modelDirectory.path, isDirectory: &isDir), isDir.boolValue else {
            throw Error.directoryNotFound(modelDirectory)
        }

        // 2) Collect integrity files (recursive, allow-listed).
        let (_, absolutePaths) = ModelScanner.collectWeightFiles(in: modelDirectory)
        guard !absolutePaths.isEmpty else {
            throw Error.noFilesFound(modelDirectory)
        }

        // 3) Compute the standardised base path so we can derive relative POSIX
        // paths for each manifest entry. We deliberately DO NOT resolve
        // symlinks here: HuggingFace caches lay out every file as
        // `snapshots/<hash>/<filename>` symlinked to `blobs/<blob_hash>`, and
        // resolving those would point outside the snapshot directory, causing
        // the prefix-strip to fail and the relative path to collapse to a
        // bare filename (dropping subdirectory information like
        // `adapters/lora.safetensors` → `lora.safetensors`). The enumerator
        // returns URLs that share this same standardised (symlink-preserving)
        // prefix, so prefix stripping is correct without resolution.
        let basePath = modelDirectory.standardizedFileURL.path
        let basePrefix = basePath.hasSuffix("/") ? basePath : basePath + "/"

        // 4) Hash every file in parallel via a TaskGroup so we get cores on
        // the publish VM. Each task reads the file, computes its SHA-256
        // digest, and emits a (relativePath, digest, size) tuple.
        struct Hashed: Sendable {
            let relativePath: String
            let digest: SHA256Digest
            let sizeBytes: Int64
            let role: String
        }

        let hashed: [Hashed] = try await withThrowingTaskGroup(of: Hashed.self) { group in
            for file in absolutePaths {
                group.addTask {
                    let result = try Self.hashOne(file: file, basePrefix: basePrefix)
                    return Hashed(
                        relativePath: result.relativePath,
                        digest: result.digest,
                        sizeBytes: result.sizeBytes,
                        role: result.role
                    )
                }
            }
            var collected: [Hashed] = []
            collected.reserveCapacity(absolutePaths.count)
            for try await item in group {
                collected.append(item)
            }
            return collected
        }

        // 5) Sort by relative POSIX path (lexicographic) so manifest order and
        // aggregate hash order are stable and location-independent. Break
        // ties on the per-file digest as defense-in-depth — once the B1 fix
        // is in place, relative paths within a manifest should be unique,
        // but the tiebreaker keeps us deterministic even if a caller hands
        // us a directory layout where two enumerated entries collapse to
        // the same relative path.
        let sorted = hashed.sorted {
            if $0.relativePath != $1.relativePath { return $0.relativePath < $1.relativePath }
            let aHex = $0.digest.map { String(format: "%02x", $0) }.joined()
            let bHex = $1.digest.map { String(format: "%02x", $0) }.joined()
            return aHex < bHex
        }

        // 6) Aggregate hash: SHA-256 over the concatenated raw 32-byte digests
        // in sorted order. This is the same shape as
        // `WeightHasher.hashFilesSorted`, just keyed on relative path instead
        // of absolute path. (Cross-checked against
        // `WeightHasher.hashFilesWithRelativeKey` in tests.)
        var aggregator = SHA256()
        var totalSize: Int64 = 0
        var files: [ManifestFile] = []
        files.reserveCapacity(sorted.count)

        for entry in sorted {
            entry.digest.withUnsafeBytes { aggregator.update(bufferPointer: $0) }
            totalSize += entry.sizeBytes
            let hex = entry.digest.map { String(format: "%02x", $0) }.joined()
            files.append(ManifestFile(
                path: entry.relativePath,
                sizeBytes: entry.sizeBytes,
                sha256: hex,
                role: entry.role
            ))
        }

        let aggregateHex = aggregator.finalize().map { String(format: "%02x", $0) }.joined()

        // 7) Build manifest.
        let safeID = safeModelID(modelID)
        let r2Prefix = "v2/\(safeID)/\(version)"

        logger.info("Built manifest for \(modelID) v\(version): \(files.count) files, \(totalSize) bytes, aggregate \(aggregateHex.prefix(12))")

        return ModelManifest(
            schemaVersion: schemaVersion,
            modelID: modelID,
            version: version,
            r2Prefix: r2Prefix,
            aggregateSHA256: aggregateHex,
            totalSizeBytes: totalSize,
            fileCount: files.count,
            files: files,
            createdAt: Date()
        )
    }

    // MARK: - Internals

    public static func safeModelID(_ modelID: String) -> String {
        var slug = ""
        slug.reserveCapacity(modelID.count)
        for ch in modelID {
            if let ascii = ch.asciiValue,
               (ascii >= 0x30 && ascii <= 0x39 || ascii >= 0x41 && ascii <= 0x5A || ascii >= 0x61 && ascii <= 0x7A || ascii == 0x2E || ascii == 0x5F || ascii == 0x2D) {
                slug.append(ch)
            } else if ch == "/" {
                slug.append("-")
            } else {
                slug.append("-")
            }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty {
            slug = "model"
        }
        let digest = SHA256.hash(data: Data(modelID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(slug)--\(digest.prefix(12))"
    }

    private static func hashOne(file: URL, basePrefix: String) throws -> (relativePath: String, digest: SHA256Digest, sizeBytes: Int64, role: String) {
        let fm = FileManager.default

        // (a) Compute the manifest-relative path against the symlink-preserving
        // standardised path. The HuggingFace cache stores every file as a
        // symlink into a `blobs/` directory that lives outside the snapshot
        // root; resolving the symlink here would push the path out from
        // under `basePrefix` and collapse subdirectory information.
        let unresolvedAbsolute = file.standardizedFileURL.path

        let relative: String
        if unresolvedAbsolute.hasPrefix(basePrefix) {
            relative = String(unresolvedAbsolute.dropFirst(basePrefix.count))
        } else if unresolvedAbsolute == basePrefix.dropLast() {
            relative = ""
        } else {
            // The enumerator is contractually supposed to yield URLs under
            // the directory it was rooted at, so this branch should be
            // unreachable. Fall back to the last path component rather than
            // crashing.
            relative = file.lastPathComponent
        }

        // POSIX-normalise just to be defensive — FileManager already uses `/`
        // separators on every supported platform, but a future caller might
        // hand us a Windows-style path.
        let relativePosix = relative.replacingOccurrences(of: "\\", with: "/")

        // (b) Resolve symlinks ONLY when opening the file for reading bytes
        // and stat'ing the size. This is the point where we want to follow
        // the HF cache `snapshots/.../foo` → `blobs/<hash>` indirection.
        let readURL = file.resolvingSymlinksInPath()

        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try fm.attributesOfItem(atPath: readURL.path)
        } catch {
            throw Error.fileReadFailed(file, error)
        }
        let sizeBytes: Int64
        if let size = attrs[.size] as? Int64 {
            sizeBytes = size
        } else if let size = attrs[.size] as? UInt64 {
            sizeBytes = Int64(size)
        } else if let size = attrs[.size] as? NSNumber {
            sizeBytes = size.int64Value
        } else {
            sizeBytes = 0
        }

        // (S9) Wrap FileHandle open errors so callers see the underlying cause.
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: readURL)
        } catch {
            throw Error.fileReadFailed(file, error)
        }
        defer { try? handle.close() }

        // Stream the file in 64 KiB chunks so we don't slurp multi-GB
        // safetensors shards into memory.
        var hasher = SHA256()
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: 65536) ?? Data()
            } catch {
                throw Error.fileReadFailed(file, error)
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()

        let role = ModelScanner.roleFor(filename: file.lastPathComponent)
        return (relativePosix, digest, sizeBytes, role)
    }
}
