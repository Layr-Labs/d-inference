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
}
