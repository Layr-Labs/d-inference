import Crypto
import XCTest

@testable import ProviderCoreFoundation

/// Per-file concurrent hashing (T4-03) is digest-identical to the serial
/// definition — per-file SHA-256 digests combined in sorted-key order — and
/// keeps the failure contract (any unreadable file ⇒ nil). The wall-time
/// win is pinned by an env-gated bench (`DARKBLOOM_HASH_BENCH=1`) that needs
/// no cached model.
final class WeightHasherParallelTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("weight-hasher-parallel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Deterministic pseudo-random bytes so fixtures never repeat: one
    /// xorshift-filled 64 KiB block per seed, tiled to `count` (SHA-256
    /// cost does not depend on the content, and a per-byte generator is
    /// far too slow in a debug build for the 1 GiB bench fixture).
    private func bytes(count: Int, seed: UInt64) -> Data {
        let blockSize = 64 * 1024
        var block = [UInt64](repeating: 0, count: blockSize / 8)
        var state = seed | 1
        for index in block.indices {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            block[index] = state
        }
        let blockData = block.withUnsafeBytes { Data($0) }
        var out = Data(capacity: count)
        while out.count + blockSize <= count {
            out.append(blockData)
        }
        if out.count < count {
            out.append(blockData.prefix(count - out.count))
        }
        return out
    }

    private func makeFiles(count: Int, size: Int) throws -> [(file: URL, sortKey: String)] {
        var files: [(file: URL, sortKey: String)] = []
        for index in 0..<count {
            let name = String(format: "model-%05d-of-%05d.safetensors", index, count)
            let file = root.appendingPathComponent(name)
            try bytes(count: size, seed: UInt64(1_000 + index)).write(to: file)
            files.append((file: file, sortKey: name))
        }
        // Reverse so the caller-order ≠ sort-order path is exercised.
        return files.reversed()
    }

    /// The documented algorithm, written out serially: the reference the
    /// concurrent implementation must reproduce byte-for-byte.
    private func serialReference(_ files: [(file: URL, sortKey: String)]) -> String? {
        var final = SHA256()
        for entry in files.sorted(by: { $0.sortKey < $1.sortKey }) {
            guard let digest = WeightHasher.hashSingleFile(at: entry.file) else { return nil }
            digest.withUnsafeBytes { final.update(bufferPointer: $0) }
        }
        return final.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func testConcurrentDigestMatchesTheSerialDefinitionForOneThreeAndEightFiles() throws {
        for count in [1, 3, 8] {
            let files = try makeFiles(count: count, size: 3 * 1024 * 1024 + count * 977)
            let concurrent = WeightHasher.hashFilesWithRelativeKey(files)
            XCTAssertNotNil(concurrent)
            XCTAssertEqual(concurrent, serialReference(files), "digest drift with \(count) files")
            // Stable across repeated calls (no ordering nondeterminism leaks in).
            XCTAssertEqual(concurrent, WeightHasher.hashFilesWithRelativeKey(files))
            for entry in files { try FileManager.default.removeItem(at: entry.file) }
        }
    }

    func testFilesLargerThanTheReadBufferHashCorrectly() throws {
        // > 1 MiB so the read(2) loop crosses buffer boundaries, with a
        // non-multiple size so the final short read is exercised.
        let files = try makeFiles(count: 2, size: 5 * 1024 * 1024 + 12_345)
        let expected = serialReference(files)
        XCTAssertEqual(WeightHasher.hashFilesWithRelativeKey(files), expected)
        // Cross-check one file against CryptoKit over the whole contents.
        let whole = try Data(contentsOf: files[0].file)
        let direct = SHA256.hash(data: whole).map { String(format: "%02x", $0) }.joined()
        let viaHasher = try XCTUnwrap(WeightHasher.hashSingleFile(at: files[0].file))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(direct, viaHasher)
    }

    func testOneUnreadableFileAmongManyYieldsNilNotAPartialCombination() throws {
        var files = try makeFiles(count: 4, size: 256 * 1024)
        files.append((file: root.appendingPathComponent("missing.safetensors"), sortKey: "zzz-missing"))
        XCTAssertNil(WeightHasher.hashFilesWithRelativeKey(files))
    }

    /// Env-gated change-detector for the wall-time win: serial per-file
    /// hashing vs the concurrent implementation over 4 × 256 MiB. Reads
    /// ≈1.0 before T4-03 and well under 0.75 after on any multi-core box.
    /// Skipped unless DARKBLOOM_HASH_BENCH=1 (≈1 GiB of temp files).
    func testBenchConcurrentBeatsSerialByAtLeastAQuarter() throws {
        guard ProcessInfo.processInfo.environment["DARKBLOOM_HASH_BENCH"] == "1" else {
            throw XCTSkip("set DARKBLOOM_HASH_BENCH=1 to run the hashing bench")
        }
        let files = try makeFiles(count: 4, size: 256 * 1024 * 1024)

        // Warm the page cache so both arms measure compute, not the SSD.
        _ = serialReference(files)

        let serialStart = Date()
        let serial = serialReference(files)
        let serialSeconds = Date().timeIntervalSince(serialStart)

        let concurrentStart = Date()
        let concurrent = WeightHasher.hashFilesWithRelativeKey(files)
        let concurrentSeconds = Date().timeIntervalSince(concurrentStart)

        XCTAssertEqual(serial, concurrent)
        let ratio = concurrentSeconds / serialSeconds
        print(
            "hash bench: serial=\(String(format: "%.3f", serialSeconds))s "
                + "concurrent=\(String(format: "%.3f", concurrentSeconds))s ratio=\(String(format: "%.2f", ratio))")
        XCTAssertLessThan(ratio, 0.75, "concurrent per-file hashing should beat serial by ≥25 %")
    }
}
