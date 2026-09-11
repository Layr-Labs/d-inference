import Foundation
import Testing

@Suite("Live test metallib source selection")
struct LiveInferenceMetallibSourceTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metallib-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func stage(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture-only".utf8).write(to: url)
    }

    @Test("custom scratch accepts only the staged source beside its active configuration", arguments: ["debug", "release"])
    func customScratch(configuration: String) throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let build = root.appendingPathComponent("release-build/arm64-apple-macosx")
        let bundle = build.appendingPathComponent("\(configuration)/ProviderPackageTests.xctest")
        let other = configuration == "debug" ? "release" : "debug"
        try stage(bundle.appendingPathComponent("Contents/MacOS/mlx.metallib"))
        try stage(build.appendingPathComponent("\(other)/mlx.metallib"))
        #expect(LiveInferenceFixtures.findSourceMetallib(testBundleURL: bundle) == nil,
            "neither an old runner-local copy nor another configuration is authoritative")
        let source = build.appendingPathComponent("\(configuration)/mlx.metallib")
        try stage(source)
        #expect(LiveInferenceFixtures.findSourceMetallib(testBundleURL: bundle) == source)
    }

    @Test("standard .build fallback preserves the running configuration", arguments: ["debug", "release"])
    func standardBuildFallback(configuration: String) throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let build = root.appendingPathComponent(".build")
        let bundle = build.appendingPathComponent("arm64-apple-macosx/\(configuration)/ProviderPackageTests.xctest")
        let other = configuration == "debug" ? "release" : "debug"
        try stage(build.appendingPathComponent("\(other)/mlx.metallib"))
        #expect(LiveInferenceFixtures.findSourceMetallib(testBundleURL: bundle) == nil)
        let fallback = build.appendingPathComponent("\(configuration)/mlx.metallib")
        try stage(fallback)
        #expect(LiveInferenceFixtures.findSourceMetallib(testBundleURL: bundle) == fallback)
        let direct = bundle.deletingLastPathComponent().appendingPathComponent("mlx.metallib")
        try stage(direct)
        #expect(LiveInferenceFixtures.findSourceMetallib(testBundleURL: bundle) == direct)
    }

    @Test("unrecognized custom configuration does not discover arbitrary ancestor artifacts")
    func unknownConfiguration() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try stage(root.appendingPathComponent("mlx.metallib"))
        let bundle = root.appendingPathComponent("custom-scratch/optimized/ProviderPackageTests.xctest")
        try stage(bundle.deletingLastPathComponent().appendingPathComponent("mlx.metallib"))
        #expect(LiveInferenceFixtures.findSourceMetallib(testBundleURL: bundle) == nil)
    }
}
