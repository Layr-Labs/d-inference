import Foundation
import Testing
@testable import ProviderCore
import ProviderCoreFoundation

/// Regression for #260: `FileManager.contentsOfDirectory(at:)` throws
/// (NSCocoaErrorDomain 256 / POSIX ENOTDIR) when the cache directory's FINAL
/// path component is itself a symlink — e.g. `~/.cache/huggingface/hub` ->
/// `/Volumes/External Models/huggingface-hub`. Discovery logged a warning and
/// returned an empty fleet, so a fully-downloaded provider crash-looped on
/// "no models" until the daemon was restarted into the same wall.
@Suite("ModelScanner symlinked cache dir (#260)", .serialized)
struct ModelScannerSymlinkedCacheDirTests {

    /// Minimal HF-cache model: sparse weight file + config.json. Same fixture
    /// shape as ModelScannerMemoryFilterTests.
    private func makeModel(in cacheDir: URL, id: String, weightBytes: Int64 = 1 << 20) throws {
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

    @Test("scanAllModels finds models when the cache root itself is a symlink")
    func symlinkedCacheRootIsListed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hf-cache-symlink-\(UUID().uuidString)", isDirectory: true)
        let realDir = root.appendingPathComponent("real-hub", isDirectory: true)
        // The broken layout: `hub` is a symlink to a directory, and discovery
        // is pointed at `hub` (final component = symlink).
        let link = root.appendingPathComponent("hub", isDirectory: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try makeModel(in: realDir, id: "test-org/symlinked-model")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realDir)

        let all = ModelScanner.scanAllModels(in: link)
        #expect(all.contains { $0.id == "test-org/symlinked-model" },
                "unfiltered scan must see the model behind a symlinked cache root")

        let fits = ModelScanner.scanModels(in: link, availableMemoryGB: 64)
        #expect(fits.contains { $0.id == "test-org/symlinked-model" },
                "memory-filtered scan must see the model behind a symlinked cache root")
    }
}
