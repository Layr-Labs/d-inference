import CryptoKit
import Darwin
import Foundation

struct CheckpointManifest: Codable {
    struct Entry: Codable {
        let path: String
        let sha256: String
        let size_bytes: Int
    }
    let aggregate_sha256: String
    let file_count: Int
    let total_size_bytes: Int
    let files: [Entry]
}

/// Pins verified file descriptors until loading finishes, including across path replacement.
final class VerifiedCheckpoint {
    final class File {
        let path: String
        let descriptor: Int32
        let size: Int
        private let identity: stat
        private var bypassesPayloadCache = false

        init(url: URL, path: String, expectedSize: Int) throws {
            descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
            guard descriptor >= 0 else { throw ProbeError("Cannot open checkpoint file \(path)") }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                info.st_size == expectedSize, expectedSize >= 0
            else { close(descriptor); throw ProbeError("Checkpoint file size/type mismatch: \(path)") }
            self.path = path; size = expectedSize; identity = info
        }

        deinit { close(descriptor) }

        /// The selected loader owns this descriptor until its source is released.
        /// Keep payload reads uncached so resident MLX storage is not duplicated
        /// in newly populated file-cache pages. Existing cached pages are not evicted.
        func bypassPayloadCache() throws {
            guard fcntl(descriptor, F_NOCACHE, 1) == 0 else {
                throw ProbeError("Cannot disable checkpoint payload caching: \(path)")
            }
            bypassesPayloadCache = true
        }

        func checkUnchanged() throws {
            var current = stat()
            guard fstat(descriptor, &current) == 0,
                current.st_ino == identity.st_ino, current.st_dev == identity.st_dev,
                current.st_size == identity.st_size,
                current.st_mtimespec.tv_sec == identity.st_mtimespec.tv_sec,
                current.st_mtimespec.tv_nsec == identity.st_mtimespec.tv_nsec,
                current.st_ctimespec.tv_sec == identity.st_ctimespec.tv_sec,
                current.st_ctimespec.tv_nsec == identity.st_ctimespec.tv_nsec
            else { throw ProbeError("Checkpoint changed during verification/loading: \(path)") }
        }

        func read(into destination: UnsafeMutableRawBufferPointer, offset: Int) throws {
            guard offset >= 0, offset <= size, destination.count <= size - offset else {
                throw ProbeError("Checkpoint read out of range: \(path)")
            }
            var done = 0
            while done < destination.count {
                let count = pread(descriptor, destination.baseAddress!.advanced(by: done),
                                  destination.count - done, off_t(offset + done))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ProbeError("Short checkpoint read: \(path)") }
                done += count
            }
        }

        func data(offset: Int, count: Int) throws -> Data {
            var result = Data(count: count)
            try result.withUnsafeMutableBytes { try read(into: $0, offset: offset) }
            return result
        }

        func digest() throws -> SHA256.Digest {
            // This freshly opened descriptor is exclusively owned during hashing.
            // Avoid retaining newly read checksum pages; this does not evict old cache.
            guard fcntl(descriptor, F_NOCACHE, 1) == 0 else {
                throw ProbeError("Cannot disable checkpoint checksum caching: \(path)")
            }
            do {
                var hash = SHA256()
                let blockSize = 4 * 1024 * 1024
                var buffer = Data(count: min(blockSize, size))
                var offset = 0
                while offset < size {
                    let count = min(blockSize, size - offset)
                    try buffer.withUnsafeMutableBytes { bytes in
                        let block = UnsafeMutableRawBufferPointer(rebasing: bytes[..<count])
                        try read(into: block, offset: offset)
                        hash.update(bufferPointer: UnsafeRawBufferPointer(block))
                    }
                    offset += count
                }
                try checkUnchanged()
                let digest = hash.finalize()
                // Ordinary callers keep cached payload reads; an explicitly
                // uncached selected loader keeps its policy even across rehashing.
                guard bypassesPayloadCache || fcntl(descriptor, F_NOCACHE, 0) == 0 else {
                    throw ProbeError("Cannot restore checkpoint read caching: \(path)")
                }
                return digest
            } catch {
                // Never replace a primary read/identity error with cleanup failure.
                // Constructor failure releases this owned descriptor; no success escapes.
                if !bypassesPayloadCache { _ = fcntl(descriptor, F_NOCACHE, 0) }
                throw error
            }
        }
    }

    let aggregate: String
    /// Exact configuration bytes verified against the manifest and its open file.
    let configurationSHA256: String
    /// Non-nil only after an independently expected raw manifest matched and all files verified.
    let verifiedManifestSHA256: String?
    let files: [String: File]

    init(directory: URL, configurationData: Data,
         expectedAggregateSHA256: String? = nil, maximumPayloadBytes: Int? = nil,
         expectedManifestSHA256: String? = nil) throws {
        if let expectedAggregateSHA256 {
            guard expectedAggregateSHA256.utf8.count == 64,
                  expectedAggregateSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw ProbeError("Expected aggregate must be a lowercase SHA256")
            }
        }
        if let maximumPayloadBytes, maximumPayloadBytes < 0 {
            throw ProbeError("Checkpoint payload limit must be nonnegative")
        }
        try QwenCheckpointManifestPin.validateExpected(expectedManifestSHA256)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let manifestData: Data
        if maximumPayloadBytes != nil || expectedManifestSHA256 != nil {
            // Opt-in bounded admission must bound the manifest itself before
            // decoding its claimed payload sizes. Existing callers keep their IO.
            let maximumManifestBytes = 4 * 1024 * 1024
            let handle = try FileHandle(forReadingFrom: manifestURL)
            defer { try? handle.close() }
            manifestData = try handle.read(upToCount: maximumManifestBytes + 1) ?? Data()
            guard manifestData.count <= maximumManifestBytes else {
                throw ProbeError("Checkpoint manifest exceeds the 4 MiB metadata byte limit")
            }
        } else {
            manifestData = try Data(contentsOf: manifestURL)
        }
        let matchedManifest = try QwenCheckpointManifestPin.match(manifestData, expected: expectedManifestSHA256)
        let manifest = try JSONDecoder().decode(CheckpointManifest.self, from: manifestData)
        guard manifest.file_count == manifest.files.count,
            Set(manifest.files.map(\.path)).count == manifest.files.count,
            manifest.files.allSatisfy({ $0.size_bytes >= 0 }), manifest.total_size_bytes >= 0
        else { throw ProbeError("Invalid checkpoint manifest counts") }
        var payloadBytes = 0
        for entry in manifest.files {
            let sum = payloadBytes.addingReportingOverflow(entry.size_bytes)
            guard !sum.overflow else { throw ProbeError("Checkpoint payload byte count overflow") }
            payloadBytes = sum.partialValue
        }
        guard payloadBytes == manifest.total_size_bytes else { throw ProbeError("Invalid checkpoint manifest counts") }
        if let expectedAggregateSHA256, manifest.aggregate_sha256 != expectedAggregateSHA256 {
            throw ProbeError("Checkpoint manifest differs from expected aggregate")
        }
        if let maximumPayloadBytes, payloadBytes > maximumPayloadBytes {
            throw ProbeError("Checkpoint payload exceeds the requested byte limit")
        }
        let configurationSHA256 = sha256(configurationData)
        guard let config = manifest.files.first(where: { $0.path == "config.json" }),
            configurationSHA256 == config.sha256 else {
            throw ProbeError("Loaded configuration is not the manifest's exact configuration")
        }
        var verified: [String: File] = [:]
        var aggregateHasher = SHA256()
        for entry in manifest.files.sorted(by: { $0.path < $1.path }) {
            guard !entry.path.hasPrefix("/"),
                entry.path.split(separator: "/", omittingEmptySubsequences: false)
                    .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
            else { throw ProbeError("Invalid manifest relative path") }
            let url = directory.appendingPathComponent(entry.path)
            guard url.resolvingSymlinksInPath().path.hasPrefix(
                directory.resolvingSymlinksInPath().path + "/") else {
                throw ProbeError("Manifest path leaves checkpoint directory")
            }
            let file = try File(url: url, path: entry.path, expectedSize: entry.size_bytes)
            let digest = try file.digest()
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            guard hex == entry.sha256 else { throw ProbeError("Checkpoint SHA256 mismatch: \(entry.path)") }
            digest.withUnsafeBytes { aggregateHasher.update(bufferPointer: $0) }
            verified[entry.path] = file
        }
        let aggregate = aggregateHasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard aggregate == manifest.aggregate_sha256 else { throw ProbeError("Checkpoint aggregate mismatch") }
        if let expectedAggregateSHA256, aggregate != expectedAggregateSHA256 {
            throw ProbeError("Verified checkpoint differs from expected aggregate")
        }
        self.configurationSHA256 = configurationSHA256
        self.aggregate = aggregate; files = verified
        self.verifiedManifestSHA256 = matchedManifest
    }

    /// Reuse verified descriptors only with the exact configuration already verified.
    func requireConfiguration(_ data: Data) throws {
        guard sha256(data) == configurationSHA256 else {
            throw ProbeError("Reused checkpoint configuration differs from verified configuration")
        }
    }

    func checkUnchanged() throws { for file in files.values { try file.checkUnchanged() } }

    /// Called after admission and before any selected-stage payload is read.
    /// Failure propagates before materialization; closing these owned descriptors
    /// ends the policy, with no global cache or filesystem setting to restore.
    func bypassTensorPayloadCache() throws {
        for file in files.values.sorted(by: { $0.path < $1.path })
        where file.path.hasSuffix(".safetensors") {
            try file.bypassPayloadCache()
        }
    }
}
