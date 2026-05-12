import Foundation
import Testing
@testable import ProviderCore

@Suite("SelfUpdater")
struct SelfUpdaterTests {

    @Test("release endpoint preserves bundle, binary, and metallib hashes")
    func releaseEndpointPreservesAllHashes() async throws {
        let mock = MockCoordinator(release: MockReleaseFixture(
            version: "99.0.0",
            bundleHash: String(repeating: "a", count: 64),
            binaryHash: String(repeating: "b", count: 64),
            metallibHash: String(repeating: "c", count: 64)
        ))
        let baseURL = try await mock.start()
        defer { Task { await mock.shutdown() } }

        let updater = SelfUpdater(coordinatorBaseURL: baseURL.absoluteString)
        let result = await updater.checkForUpdate()

        guard case .updateAvailable(_, let latest) = result else {
            Issue.record("expected updateAvailable, got \(result)")
            return
        }
        #expect(latest.bundleHash == String(repeating: "a", count: 64))
        #expect(latest.binaryHash == String(repeating: "b", count: 64))
        #expect(latest.metallibHash == String(repeating: "c", count: 64))
    }

    @Test("ReleaseInfo sha256 compatibility returns bundle hash")
    func releaseInfoShaCompatibility() {
        let hash = String(repeating: "d", count: 64)
        let release = ReleaseInfo(
            version: "1.0.0",
            platform: "macos-arm64",
            url: "https://example.test/bundle.tar.gz",
            bundleHash: hash
        )
        #expect(release.sha256 == hash)
    }

    @Test("installBundle installs all bundle files and verifies component hashes")
    func installBundleInstallsBundleFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("self-updater-test-\(UUID().uuidString)", isDirectory: true)
        let stage = root.appendingPathComponent("stage", isDirectory: true)
        let bin = stage.appendingPathComponent("bin", isDirectory: true)
        let install = root.appendingPathComponent("install", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
        let darkbloom = bin.appendingPathComponent("darkbloom")
        let enclave = bin.appendingPathComponent("darkbloom-enclave")
        let metallib = bin.appendingPathComponent("mlx.metallib")
        try Data("new darkbloom".utf8).write(to: darkbloom)
        try Data("new enclave".utf8).write(to: enclave)
        try Data("new metallib".utf8).write(to: metallib)

        let tarball = root.appendingPathComponent("bundle.tar.gz")
        try runTarCreate(sourceDir: stage, tarball: tarball)

        let release = ReleaseInfo(
            version: "1.0.0",
            platform: "macos-arm64",
            url: "file://unused",
            bundleHash: sha256Hex(try Data(contentsOf: tarball)),
            binaryHash: sha256Hex(try Data(contentsOf: darkbloom)),
            metallibHash: sha256Hex(try Data(contentsOf: metallib))
        )
        let updater = SelfUpdater(coordinatorBaseURL: "https://api.example.test")

        let result = updater.installBundleForTesting(
            from: tarball,
            release: release,
            installDir: install
        )
        guard case .success = result else {
            Issue.record("installBundleForTesting failed: \(result)")
            return
        }

        #expect((try String(contentsOf: install.appendingPathComponent("darkbloom"), encoding: .utf8)) == "new darkbloom")
        #expect((try String(contentsOf: install.appendingPathComponent("darkbloom-enclave"), encoding: .utf8)) == "new enclave")
        #expect((try String(contentsOf: install.appendingPathComponent("mlx.metallib"), encoding: .utf8)) == "new metallib")
        #expect(FileManager.default.fileExists(atPath: install.appendingPathComponent("eigeninference-enclave").path))
    }
}

private func runTarCreate(sourceDir: URL, tarball: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    process.arguments = ["czf", tarball.path, "-C", sourceDir.path, "."]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}
