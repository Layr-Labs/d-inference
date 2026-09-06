import Foundation
@testable import ProviderCore

/// A per-test cache shared by the fixture writer and the real prefetch scan/hash
/// path. Never changes HOME or consults the operator's HuggingFace cache.
struct PrefetchTestModelCache: Sendable {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("darkbloom-prefetch-cache-\(UUID().uuidString)", isDirectory: true)
        // Keep cleanup scoped to this fresh per-test root.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    func seedSnapshot(modelID: String, includeWeights: Bool = true) throws {
        let model = modelDirectory(for: modelID)
        let snapshot = model.appendingPathComponent("snapshots/local", isDirectory: true)
        let refs = model.appendingPathComponent("refs", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
        try Data(#"{"model_type":"gpt_oss"}"#.utf8)
            .write(to: snapshot.appendingPathComponent("config.json"))
        if includeWeights {
            try Data("fake mlx weight bytes".utf8)
                .write(to: snapshot.appendingPathComponent("model.safetensors"))
        }
        try "local".write(to: refs.appendingPathComponent("main"), atomically: true, encoding: .utf8)
    }

    func resolveSnapshot(_ modelID: String) -> URL? {
        ModelScanner.findLatestSnapshot(
            in: modelDirectory(for: modelID).appendingPathComponent("snapshots", isDirectory: true))
    }

    /// Call from a defer installed before seeding or awaiting fixture setup.
    func remove() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func modelDirectory(for modelID: String) -> URL {
        let safe = modelID.replacingOccurrences(of: "/", with: "--")
        return root.appendingPathComponent("models--\(safe)", isDirectory: true)
    }
}
