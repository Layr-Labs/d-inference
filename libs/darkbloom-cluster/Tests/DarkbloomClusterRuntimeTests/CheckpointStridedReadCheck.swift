import CryptoKit
import Darwin
import Foundation
// The model-free script check compiles this file against its own module name.
#if canImport(DarkbloomClusterRuntimeChecks)
@testable import DarkbloomClusterRuntimeChecks
#else
@testable import DarkbloomClusterRuntime
#endif

/// A rank's part of a tensor divided on an inner axis is one run per row. Uncached, each run read alone is a whole
/// aligned read: MiMo's expert `down_proj` (`[256, 4096, 256]` words, half a row each) is about a million of them per
/// tensor, which kept its tensor-parallel load past its startup deadline. Runs that share pages are read together,
/// within one scratch request, with the same bytes; runs a page or more apart are still read one at a time.
/// Real files through the pinned descriptor; no model, no MLX.
enum CheckpointStridedReadCheck {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func run() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("checkpoint-strided-read-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        // MiMo's row: 1,024 bytes, of which a rank reads 512. 20,001 rows: more than one scratch request, and a
        // file that does not end on a page.
        let rows = 20_001, row = 1_024, half = 512
        let narrow = seeded(rows * row, seed: 1)
        // Rows of 64 KiB, half each: runs a page or more apart.
        let wideRows = 64, wideRow = 65_536
        let wide = seeded(wideRows * wideRow, seed: 2)
        let checkpoint = try fixture(root: root, files: ["model-00001-of-00002.safetensors": narrow,
                                                         "model-00002-of-00002.safetensors": wide])
        try checkpoint.bypassTensorPayloadCache()
        guard let narrowFile = checkpoint.files["model-00001-of-00002.safetensors"],
              let wideFile = checkpoint.files["model-00002-of-00002.safetensors"] else {
            throw Failure(description: "the weight files are not pinned")
        }

        for rank in 0..<2 {
            let expected = runs(narrow, offset: rank * half, length: half, stride: row, count: rows)
            let (bytes, accounting) = try readRuns(narrowFile, offset: rank * half, length: half, stride: row, count: rows)
            guard bytes == expected else { throw Failure(description: "rank \(rank): the runs read back other bytes") }
            guard let accounting else { throw Failure(description: "rank \(rank): the runs did not take the uncached aligned path") }
            guard accounting.selectedBytes == rows * half else {
                throw Failure(description: "rank \(rank): \(accounting.selectedBytes) selected bytes, not \(rows * half)")
            }
            // 20 MB of rows in 8 MiB requests: three reads, not one per row.
            guard accounting.preadCalls <= 4 else {
                throw Failure(description: "rank \(rank): \(accounting.preadCalls) reads for \(rows) runs that share pages")
            }
            guard accounting.largestScratchAllocationBytes <= CheckpointAlignedReadPlan.maximumScratchAllocationBytes else {
                throw Failure(description: "rank \(rank): scratch above the host allowance")
            }
        }

        let wideExpected = runs(wide, offset: wideRow / 2, length: wideRow / 2, stride: wideRow, count: wideRows)
        let (wideBytes, wideAccounting) = try readRuns(wideFile, offset: wideRow / 2, length: wideRow / 2, stride: wideRow,
                                                       count: wideRows)
        guard wideBytes == wideExpected else { throw Failure(description: "runs a page apart read back other bytes") }
        guard wideAccounting?.preadCalls == wideRows else {
            throw Failure(description: "runs a page apart were read together (\(wideAccounting?.preadCalls ?? 0) reads)")
        }

        // An interrupted read retries the same window; a short one fails closed.
        let destination = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 * half, alignment: 1)
        defer { destination.deallocate() }
        var calls = 0
        _ = try CheckpointAlignedReader.read(descriptor: narrowFile.descriptor, fileSize: narrowFile.size, into: destination,
            offset: half, length: half, stride: row, count: 64, checkUnchanged: {},
            readCall: { descriptor, pointer, requested, at in
                calls += 1
                if calls == 1 { errno = EINTR; return -1 }
                return Darwin.pread(descriptor, pointer, requested, at)
            })
        guard Data(destination) == runs(narrow, offset: half, length: half, stride: row, count: 64) else {
            throw Failure(description: "the retried window read back other bytes")
        }
        do {
            _ = try CheckpointAlignedReader.read(descriptor: narrowFile.descriptor, fileSize: narrowFile.size,
                into: destination, offset: half, length: half, stride: row, count: 64, checkUnchanged: {},
                readCall: { _, _, _, _ in 0 })
            throw Failure(description: "a short window read was admitted")
        } catch is ProbeError {}
        do {
            _ = try narrowFile.read(into: destination, offset: narrow.count - half, length: half, stride: row, count: 64)
            throw Failure(description: "runs past the end of the file were admitted")
        } catch is ProbeError {}
    }

    private static func readRuns(_ file: VerifiedCheckpoint.File, offset: Int, length: Int, stride: Int, count: Int) throws
        -> (Data, CheckpointAlignedReadAccounting?) {
        var data = Data(count: length * count)
        let accounting = try data.withUnsafeMutableBytes {
            try file.read(into: $0, offset: offset, length: length, stride: stride, count: count)
        }
        return (data, accounting)
    }

    private static func runs(_ data: Data, offset: Int, length: Int, stride: Int, count: Int) -> Data {
        var result = Data(capacity: length * count)
        for run in 0..<count { result.append(data.subdata(in: (offset + run * stride)..<(offset + run * stride + length))) }
        return result
    }

    static func fixture(root: URL, files payloads: [String: Data]) throws -> VerifiedCheckpoint {
        let config = Data(#"{"arch":"strided-read-fixture"}"#.utf8)
        let files = [("config.json", config)] + payloads.map { ($0.key, $0.value) }
        var aggregate = SHA256()
        var entries: [[String: Any]] = []
        for (path, data) in files.sorted(by: { $0.0 < $1.0 }) {
            try data.write(to: root.appendingPathComponent(path), options: .withoutOverwriting)
            let digest = Data(SHA256.hash(data: data))
            aggregate.update(data: digest)
            entries.append(["path": path, "sha256": digest.map { String(format: "%02x", $0) }.joined(), "size_bytes": data.count])
        }
        let manifest: [String: Any] = ["aggregate_sha256": aggregate.finalize().map { String(format: "%02x", $0) }.joined(),
            "file_count": files.count, "total_size_bytes": files.reduce(0) { $0 + $1.1.count }, "files": entries]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
        return try VerifiedCheckpoint(directory: root, configurationData: config)
    }

    /// `count` bytes of a seeded sequence.
    static func seeded(_ count: Int, seed: UInt64) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { raw in
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15 ^ seed
            for offset in Swift.stride(from: 0, to: raw.count - 7, by: 8) {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                raw.storeBytes(of: state, toByteOffset: offset, as: UInt64.self)
            }
        }
        return data
    }
}
