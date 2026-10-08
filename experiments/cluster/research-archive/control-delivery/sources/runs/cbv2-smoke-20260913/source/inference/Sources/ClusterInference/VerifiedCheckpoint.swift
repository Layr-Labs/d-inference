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
            var hash = SHA256()
            let blockSize = 4 * 1024 * 1024
            var offset = 0
            while offset < size {
                let block = try data(offset: offset, count: min(blockSize, size - offset))
                hash.update(data: block)
                offset += block.count
            }
            try checkUnchanged()
            return hash.finalize()
        }
    }

    let aggregate: String
    let files: [String: File]

    init(directory: URL, configurationData: Data) throws {
        let manifest = try JSONDecoder().decode(CheckpointManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        guard manifest.file_count == manifest.files.count,
            Set(manifest.files.map(\.path)).count == manifest.files.count,
            manifest.files.allSatisfy({ $0.size_bytes >= 0 }),
            manifest.files.reduce(Int64(0), { $0 + Int64($1.size_bytes) }) == manifest.total_size_bytes
        else { throw ProbeError("Invalid checkpoint manifest counts") }
        guard let config = manifest.files.first(where: { $0.path == "config.json" }),
            sha256(configurationData) == config.sha256 else {
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
        self.aggregate = aggregate; files = verified
    }

    func checkUnchanged() throws { for file in files.values { try file.checkUnchanged() } }
}
