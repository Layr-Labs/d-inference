import CryptoKit
import Darwin
import Foundation
import Testing
@testable import ProviderAppAttest
@testable import ProviderBenchmark
@testable import ProviderCore
@testable import ProviderCoreFoundation

/// Every chunked file read of the provider keeps no chunk resident once it
/// returns, even before its thread drains an autorelease pool. A test runs on
/// a Swift concurrency thread, which drains no pool inside one test: without a
/// pool per read, each case below leaves the whole file resident.
@Suite("Chunked read memory")
struct ChunkedReadMemoryTests {
    private static let fileBytes = 256 << 20
    private static let allowedGrowth: UInt64 = 64 << 20
    /// SHA-256 of 256 MiB of zero bytes.
    private static let zeroDigest = "a6d72ac7690f53be6ae46ba88506bd97302a093f7108472bd9efc3cefda06484"

    @Test("readDrained gives the bytes of read(upToCount:) and keeps none of them")
    func drainedRead() throws {
        try Self.withSparseFile { file in
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hasher = SHA256()
            var chunks = 0
            try Self.expectBoundedGrowth("readDrained") {
                while let chunk = try handle.readDrained(upToCount: 1 << 20), !chunk.isEmpty {
                    hasher.update(data: chunk)
                    chunks += 1
                }
            }
            #expect(chunks == 256)
            #expect(Self.hex(hasher.finalize()) == Self.zeroDigest)
        }
    }

    @Test("ManifestBuilder hashes a weight file in bounded memory")
    func manifestBuilderHash() throws {
        try Self.withSparseFile { file in
            let base = file.deletingLastPathComponent().standardizedFileURL.path + "/"
            let hashed = try Self.expectBoundedGrowth("ManifestBuilder.hashOne") {
                try ManifestBuilder.hashOne(file: file, basePrefix: base)
            }
            #expect(hashed.relativePath == file.lastPathComponent)
            #expect(hashed.sizeBytes == Int64(Self.fileBytes))
            #expect(Self.hex(hashed.digest) == Self.zeroDigest)
        }
    }

    @Test("SpecDecStore hashes an artifact file in bounded memory")
    func specDecStoreDigest() throws {
        try Self.withSparseFile { file in
            let digest = try Self.expectBoundedGrowth("SpecDecStore.digestRegularFile") {
                SpecDecStore.digestRegularFile(at: file)
            }
            let value = try #require(digest)
            #expect(Self.hex(value) == Self.zeroDigest)
        }
    }

    @Test("hashFile(atPath:) hashes a file in bounded memory")
    func binaryHasherDigest() throws {
        try Self.withSparseFile { file in
            let digest = Self.expectBoundedGrowth("hashFile(atPath:)") { hashFile(atPath: file.path) }
            #expect(digest == Self.zeroDigest)
        }
    }

    @Test("the metallib snapshot copies and hashes a file in bounded memory")
    func metallibSnapshotCopy() throws {
        try Self.withSparseFile { file in
            let snapshot = try Self.expectBoundedGrowth("makeRuntimeMetallibSnapshot") {
                try makeRuntimeMetallibSnapshot(
                    sourceURL: file, environment: ["TMPDIR": file.deletingLastPathComponent().path])
            }
            var copied = stat()
            #expect(fstat(snapshot.fileDescriptor, &copied) == 0)
            #expect(copied.st_size == off_t(Self.fileBytes))
            #expect(snapshot.digest == Self.zeroDigest)
        }
    }

    @Test("a streamed KV block read keeps none of its chunks")
    func ssdBlockChunkReads() throws {
        try Self.withSparseFile { file in
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hasher = SHA256()
            try Self.expectBoundedGrowth("SSDBlockStore.readExactly") {
                for _ in 0..<256 {
                    hasher.update(data: try SSDBlockStore.readExactly(1 << 20, from: handle, what: "chunk"))
                }
            }
            #expect(Self.hex(hasher.finalize()) == Self.zeroDigest)
        }
    }

    @Test("the cluster worker digest is read in bounded memory")
    func clusterWorkerDigest() throws {
        try Self.withSparseFile { file in
            let home = file.deletingLastPathComponent()
            let paths = try ClusterUserPaths(homeDirectory: home)
            let settings = ClusterSetupOperations.LiveSettings(
                providerConfiguration: home.appendingPathComponent("provider.toml"),
                darkbloomExecutable: home.appendingPathComponent("not-executed"), sessionArguments: [], pair: nil,
                dryRun: true, version: "fixture")
            let context = LiveContext(paths: paths, store: ClusterSetupStore(paths: .init(paths: paths)),
                                      settings: settings, clean: ClusterConsoleFreeText(homeDirectory: home.path))
            let digest = try Self.expectBoundedGrowth("LiveContext.workerSHA256") {
                try context.workerSHA256(file.path)
            }
            #expect(digest == Self.zeroDigest)
        }
    }

    @Test("the MTP benchmark hashes a weight file in bounded memory")
    func mtpBenchmarkDigest() throws {
        try Self.withSparseFile { file in
            let digest = try Self.expectBoundedGrowth("MTPBenchmarkDigest.sha256(file:)") {
                try MTPBenchmarkDigest.sha256(file: file)
            }
            #expect(digest == Self.zeroDigest)
        }
    }

    @Test("the App Attest worker hashes its executable in bounded memory")
    func workerExecutableDigest() throws {
        try Self.withSparseFile { file in
            let digest = try Self.expectBoundedGrowth("WorkerCodeIdentity.sha256Hex(of:)") {
                try WorkerCodeIdentity.sha256Hex(of: file)
            }
            #expect(digest == Self.zeroDigest)
        }
    }

    /// Calls `body` with a sparse file of `fileBytes` zero bytes, alone in an
    /// owner-only directory under the real temporary path: bytes to read,
    /// none on disk.
    private static func withSparseFile<T>(_ body: (URL) throws -> T) throws -> T {
        let temporary = try #require(realpath(NSTemporaryDirectory(), nil).map {
            defer { free($0) }
            return String(cString: $0)
        })
        let root = URL(fileURLWithPath: temporary, isDirectory: true)
            .appendingPathComponent("chunked-read-memory-\(UUID().uuidString.lowercased())", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("model.safetensors")
        try #require(fm.createFile(atPath: file.path, contents: nil))
        let writer = try FileHandle(forWritingTo: file)
        try writer.truncate(atOffset: UInt64(fileBytes))
        try writer.close()
        return try body(file)
    }

    /// Runs `body` and expects the process footprint to grow by less than
    /// `allowedGrowth`: one chunk at a time, never the file.
    @discardableResult
    private static func expectBoundedGrowth<T>(_ reader: String, _ body: () throws -> T) rethrows -> T {
        let before = footprint()
        let result = try body()
        let after = footprint()
        #expect(before != nil && after != nil, "task_info failed")
        if let before, let after {
            let growth = after > before ? after - before : 0
            #expect(growth < allowedGrowth, "\(reader) of \(fileBytes) bytes left \(growth) bytes resident")
        }
        return result
    }

    private static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
