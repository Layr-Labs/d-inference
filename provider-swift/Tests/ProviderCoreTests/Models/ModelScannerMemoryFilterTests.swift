import Foundation
import Testing
@testable import ProviderCore
import ProviderCoreFoundation

/// The on-disk-detection half of the "invisible after interruption" fix: a model
/// that is fully downloaded but too large for available RAM must still be
/// discoverable on disk. `scanAllModels` (unfiltered) is what the picker /
/// `models` listing now use to compute the "downloaded" flag, while the
/// memory-filtered `scanModels(in:availableMemoryGB:)` governs only loadability.
@Suite("ModelScanner memory filter (downloaded != fits)", .serialized)
struct ModelScannerMemoryFilterTests {

    /// Build a minimal HuggingFace-cache model dir with a SPARSE weight file of
    /// `weightBytes` logical size (sparse via `truncate`, so the test never writes
    /// gigabytes to disk but the scanner still reads the full size).
    private func makeModel(in cacheDir: URL, id: String, weightBytes: Int64) throws {
        let dirName = "models--" + id.replacingOccurrences(of: "/", with: "--")
        let snapshot = cacheDir.appendingPathComponent(dirName)
            .appendingPathComponent("snapshots")
            .appendingPathComponent("local")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data(#"{"model_type":"llama"}"#.utf8).write(to: snapshot.appendingPathComponent("config.json"))
        let weight = snapshot.appendingPathComponent("model.safetensors")
        FileManager.default.createFile(atPath: weight.path, contents: nil)
        let fh = try FileHandle(forWritingTo: weight)
        try fh.truncate(atOffset: UInt64(weightBytes))
        try fh.close()
    }

    @Test("scanAllModels sees a too-big model that the memory-filtered scan drops")
    func unfilteredScanSeesTooBigModel() throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hf-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        // ~3 GiB weight → estimatedMemoryGb ≈ 3.6 GB (×1.2 overhead factor).
        let threeGiB: Int64 = 3 * 1024 * 1024 * 1024
        try makeModel(in: cacheDir, id: "test-org/too-big-4bit", weightBytes: threeGiB)

        // Unfiltered: the model is present on disk (this is what drives the
        // picker's "downloaded" flag now).
        let all = ModelScanner.scanAllModels(in: cacheDir)
        #expect(all.contains { $0.id == "test-org/too-big-4bit" },
                "unfiltered scan must see the downloaded model")

        // Memory-filtered with only 2 GB available: the model is dropped — which is
        // exactly why computing "downloaded" from the filtered scan made a present
        // model read "not downloaded".
        let fits = ModelScanner.scanModels(in: cacheDir, availableMemoryGB: 2)
        #expect(!fits.contains { $0.id == "test-org/too-big-4bit" },
                "memory-filtered scan drops the too-big model")

        // With ample memory it IS included — confirming the filter (not discovery)
        // is what removed it above.
        let roomy = ModelScanner.scanModels(in: cacheDir, availableMemoryGB: 64)
        #expect(roomy.contains { $0.id == "test-org/too-big-4bit" })
    }
}
