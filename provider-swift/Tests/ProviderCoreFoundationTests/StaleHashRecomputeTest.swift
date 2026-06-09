import XCTest

@testable import ProviderCoreFoundation

/// Regression for the stale-model-hash bug: the provider daemon used to compute
/// weight hashes ONCE at startup and report that frozen value forever. When a
/// model was re-published and re-downloaded while the daemon ran, the daemon
/// kept reporting the old hash and the coordinator hard-untrusted it for a
/// "model swap" even though the disk was correct.
///
/// The fix re-runs `WeightHasher.computeHash(snapshotDir:)` at model (re)load.
/// This test pins the primitive that fix relies on: re-hashing the same
/// snapshot directory reflects changed bytes, and is stable when nothing
/// changed.
final class StaleHashRecomputeTest: XCTestCase {

    private var snapshotDir: URL!

    override func setUpWithError() throws {
        snapshotDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-hash-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        try Data("{\"model_type\":\"test\"}".utf8)
            .write(to: snapshotDir.appendingPathComponent("config.json"))
        try Data("original-weights-v1".utf8)
            .write(to: snapshotDir.appendingPathComponent("model.safetensors"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: snapshotDir)
    }

    func testRecomputeIsStableWhenFilesUnchanged() throws {
        let first = WeightHasher.computeHash(snapshotDir: snapshotDir)
        let second = WeightHasher.computeHash(snapshotDir: snapshotDir)
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second, "re-hashing unchanged files must be deterministic")
    }

    func testRecomputeReflectsChangedWeights() throws {
        let before = WeightHasher.computeHash(snapshotDir: snapshotDir)
        XCTAssertNotNil(before)

        // Simulate a model re-publish landing on disk: same file name, new bytes.
        try Data("republished-weights-v2".utf8)
            .write(to: snapshotDir.appendingPathComponent("model.safetensors"))

        let after = WeightHasher.computeHash(snapshotDir: snapshotDir)
        XCTAssertNotNil(after)
        XCTAssertNotEqual(
            before, after,
            "recompute must reflect the bytes on disk — a frozen value here is the stale-hash bug")

        // Restoring the original bytes restores the original hash (content-,
        // not mtime-, addressed).
        try Data("original-weights-v1".utf8)
            .write(to: snapshotDir.appendingPathComponent("model.safetensors"))
        XCTAssertEqual(WeightHasher.computeHash(snapshotDir: snapshotDir), before)
    }

    func testSnapshotFingerprintDetectsChange() throws {
        // The fingerprint is the cheap stand-in that lets reloads skip the full
        // re-hash: it must be stable while files are untouched and change when
        // a file is rewritten (size or mtime moves).
        let first = WeightHasher.snapshotFingerprint(snapshotDir: snapshotDir)
        XCTAssertNotNil(first)
        XCTAssertEqual(WeightHasher.snapshotFingerprint(snapshotDir: snapshotDir), first)

        // Rewrite with different content (size changes).
        try Data("republished-weights-v2-longer".utf8)
            .write(to: snapshotDir.appendingPathComponent("model.safetensors"))
        let after = WeightHasher.snapshotFingerprint(snapshotDir: snapshotDir)
        XCTAssertNotNil(after)
        XCTAssertNotEqual(first, after, "fingerprint must change when a weight file is rewritten")

        // Empty/missing dir → nil (callers must re-hash).
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("fp-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        XCTAssertNil(WeightHasher.snapshotFingerprint(snapshotDir: empty))
    }

    /// TOCTOU regression: the provider hashes the weights about to be loaded, then
    /// `loadModelContainer` reads them. If a re-download lands in that window, the
    /// recorded hash describes the OLD bytes while the loaded model is the NEW
    /// ones. The fix re-checks the snapshot fingerprint AFTER the load and, on a
    /// drift, recomputes. This pins the primitives that fix relies on:
    ///   1. the fingerprint captured at hash time differs from the fingerprint
    ///      observed after a mid-window rewrite (so the drift check fires), and
    ///   2. recomputing then yields the hash of the bytes actually on disk.
    func testFingerprintAfterLoadDetectsMidWindowRewrite() throws {
        // "Hash time": capture the hash + the fingerprint it corresponds to.
        let hashAtHashTime = WeightHasher.computeHash(snapshotDir: snapshotDir)
        let fingerprintAtHashTime = WeightHasher.snapshotFingerprint(snapshotDir: snapshotDir)
        XCTAssertNotNil(hashAtHashTime)
        XCTAssertNotNil(fingerprintAtHashTime)

        // A re-download lands BETWEEN hashing and loading: same file name, new
        // bytes. (Size differs so even a coarse stat-only fingerprint catches it.)
        try Data("re-downloaded-mid-load-v2".utf8)
            .write(to: snapshotDir.appendingPathComponent("model.safetensors"))

        // "After load": the post-load fingerprint must NOT equal the one captured
        // at hash time — this inequality is exactly what triggers the recompute.
        let fingerprintAfterLoad = WeightHasher.snapshotFingerprint(snapshotDir: snapshotDir)
        XCTAssertNotNil(fingerprintAfterLoad)
        XCTAssertNotEqual(
            fingerprintAfterLoad, fingerprintAtHashTime,
            "post-load fingerprint must differ after a mid-window rewrite — otherwise the TOCTOU recompute never fires")

        // The triggered recompute must reflect the bytes actually loaded, not the
        // stale hash captured before the rewrite.
        let recomputed = WeightHasher.computeHash(snapshotDir: snapshotDir)
        XCTAssertNotNil(recomputed)
        XCTAssertNotEqual(
            recomputed, hashAtHashTime,
            "recompute after drift must reflect the loaded bytes, not the pre-rewrite hash")
    }

    /// Negative case: when NO rewrite happens between hash and load, the
    /// fingerprint is identical, so the after-load check does no extra hashing.
    func testFingerprintAfterLoadStableWhenNoRewrite() throws {
        _ = WeightHasher.computeHash(snapshotDir: snapshotDir)
        let fingerprintAtHashTime = WeightHasher.snapshotFingerprint(snapshotDir: snapshotDir)
        XCTAssertNotNil(fingerprintAtHashTime)

        // No rewrite occurs (the common case). The post-load fingerprint must
        // equal the one at hash time so the recompute is skipped.
        let fingerprintAfterLoad = WeightHasher.snapshotFingerprint(snapshotDir: snapshotDir)
        XCTAssertEqual(
            fingerprintAfterLoad, fingerprintAtHashTime,
            "unchanged weights must yield an identical fingerprint so the after-load recompute is skipped")
    }
}
