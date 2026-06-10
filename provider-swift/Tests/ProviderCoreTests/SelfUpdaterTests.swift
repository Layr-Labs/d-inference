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

    @Test("installBundle installs flat bundle files into bin/ subdirectory")
    func installBundleInstallsBundleFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("self-updater-test-\(UUID().uuidString)", isDirectory: true)
        let stage = root.appendingPathComponent("stage", isDirectory: true)
        let bin = stage.appendingPathComponent("bin", isDirectory: true)
        // installDir is now the darkbloom root (parent of bin/)
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

        let installedBin = install.appendingPathComponent("bin")
        #expect((try String(contentsOf: installedBin.appendingPathComponent("darkbloom"), encoding: .utf8)) == "new darkbloom")
        #expect((try String(contentsOf: installedBin.appendingPathComponent("darkbloom-enclave"), encoding: .utf8)) == "new enclave")
        #expect((try String(contentsOf: installedBin.appendingPathComponent("mlx.metallib"), encoding: .utf8)) == "new metallib")
        #expect(FileManager.default.fileExists(atPath: installedBin.appendingPathComponent("eigeninference-enclave").path))
    }

    @Test("installBundle with .app bundle creates symlinks from bin/ to .app")
    func installBundleWithAppBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("self-updater-app-test-\(UUID().uuidString)", isDirectory: true)
        let stage = root.appendingPathComponent("stage", isDirectory: true)
        let install = root.appendingPathComponent("install", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Create an .app bundle layout inside the staging area.
        let appMacOS = stage.appendingPathComponent("Darkbloom.app/Contents/MacOS")
        let binFlat = stage.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: appMacOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binFlat, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)

        // Write Info.plist for the .app bundle.
        let infoDir = stage.appendingPathComponent("Darkbloom.app/Contents")
        try Data("<plist/>".utf8).write(to: infoDir.appendingPathComponent("Info.plist"))

        // Write the binaries inside the .app bundle.
        try Data("app darkbloom".utf8).write(to: appMacOS.appendingPathComponent("darkbloom"))
        try Data("app enclave".utf8).write(to: appMacOS.appendingPathComponent("darkbloom-enclave"))
        try Data("app metallib".utf8).write(to: appMacOS.appendingPathComponent("mlx.metallib"))

        // Also create flat copies in bin/ (as the real tarball does).
        try Data("flat darkbloom".utf8).write(to: binFlat.appendingPathComponent("darkbloom"))
        try Data("flat enclave".utf8).write(to: binFlat.appendingPathComponent("darkbloom-enclave"))
        try Data("flat metallib".utf8).write(to: binFlat.appendingPathComponent("mlx.metallib"))

        let tarball = root.appendingPathComponent("bundle.tar.gz")
        try runTarCreate(sourceDir: stage, tarball: tarball)

        let release = ReleaseInfo(
            version: "1.0.0",
            platform: "macos-arm64",
            url: "file://unused",
            bundleHash: sha256Hex(try Data(contentsOf: tarball)),
            // Hash is from the flat copy (matches release workflow).
            binaryHash: sha256Hex(try Data(contentsOf: binFlat.appendingPathComponent("darkbloom"))),
            metallibHash: sha256Hex(try Data(contentsOf: binFlat.appendingPathComponent("mlx.metallib")))
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

        // .app bundle should be installed at the root.
        let installedAppBin = install.appendingPathComponent("Darkbloom.app/Contents/MacOS")
        #expect((try String(contentsOf: installedAppBin.appendingPathComponent("darkbloom"), encoding: .utf8)) == "app darkbloom")

        // bin/ should contain symlinks to the .app bundle, not flat copies.
        let installedBin = install.appendingPathComponent("bin")
        let linkDest = try FileManager.default.destinationOfSymbolicLink(
            atPath: installedBin.appendingPathComponent("darkbloom").path
        )
        #expect(linkDest == "../Darkbloom.app/Contents/MacOS/darkbloom")

        // Content should come from the .app bundle (not the flat copy).
        #expect((try String(contentsOf: installedBin.appendingPathComponent("darkbloom"), encoding: .utf8)) == "app darkbloom")
        #expect((try String(contentsOf: installedBin.appendingPathComponent("darkbloom-enclave"), encoding: .utf8)) == "app enclave")

        // Legacy symlink should exist.
        let legacyDest = try FileManager.default.destinationOfSymbolicLink(
            atPath: installedBin.appendingPathComponent("eigeninference-enclave").path
        )
        #expect(legacyDest == "darkbloom-enclave")
    }

    // MARK: - Stage / Commit

    /// Build a minimal valid .app-bundle tarball plus a populated "live"
    /// install dir, returning (tarball, release, installDir).
    private func makeAppBundleFixture(root: URL) throws -> (URL, ReleaseInfo, URL) {
        let fm = FileManager.default
        let stage = root.appendingPathComponent("tarball-src", isDirectory: true)
        let install = root.appendingPathComponent("install", isDirectory: true)

        let appMacOS = stage.appendingPathComponent("Darkbloom.app/Contents/MacOS")
        let binFlat = stage.appendingPathComponent("bin")
        try fm.createDirectory(at: appMacOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: binFlat, withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(
            to: stage.appendingPathComponent("Darkbloom.app/Contents/Info.plist"))
        try Data("new app darkbloom".utf8).write(to: appMacOS.appendingPathComponent("darkbloom"))
        try Data("new app enclave".utf8).write(to: appMacOS.appendingPathComponent("darkbloom-enclave"))
        try Data("new app metallib".utf8).write(to: appMacOS.appendingPathComponent("mlx.metallib"))
        try Data("new flat darkbloom".utf8).write(to: binFlat.appendingPathComponent("darkbloom"))
        try Data("new flat enclave".utf8).write(to: binFlat.appendingPathComponent("darkbloom-enclave"))
        try Data("new flat metallib".utf8).write(to: binFlat.appendingPathComponent("mlx.metallib"))

        // Populate the "live" install with an old .app bundle + symlinks.
        let liveMacOS = install.appendingPathComponent("Darkbloom.app/Contents/MacOS")
        let liveBin = install.appendingPathComponent("bin")
        try fm.createDirectory(at: liveMacOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: liveBin, withIntermediateDirectories: true)
        try Data("old darkbloom".utf8).write(to: liveMacOS.appendingPathComponent("darkbloom"))
        try Data("old metallib".utf8).write(to: liveMacOS.appendingPathComponent("mlx.metallib"))
        try fm.createSymbolicLink(
            atPath: liveBin.appendingPathComponent("mlx.metallib").path,
            withDestinationPath: "../Darkbloom.app/Contents/MacOS/mlx.metallib")

        let tarball = root.appendingPathComponent("bundle.tar.gz")
        try runTarCreate(sourceDir: stage, tarball: tarball)

        let release = ReleaseInfo(
            version: "2.0.0",
            platform: "macos-arm64",
            url: "file://unused",
            bundleHash: sha256Hex(try Data(contentsOf: tarball)),
            binaryHash: sha256Hex(try Data(contentsOf: binFlat.appendingPathComponent("darkbloom"))),
            metallibHash: sha256Hex(try Data(contentsOf: binFlat.appendingPathComponent("mlx.metallib")))
        )
        return (tarball, release, install)
    }

    @Test("staging extracts and verifies WITHOUT touching the live layout")
    func stagingDoesNotTouchLiveLayout() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("self-updater-stage-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (tarball, release, install) = try makeAppBundleFixture(root: root)
        let updater = SelfUpdater(coordinatorBaseURL: "https://api.example.test")

        let result = updater.stageBundleForTesting(from: tarball, release: release, installDir: install)
        guard case .success(let staged) = result else {
            Issue.record("stageBundleForTesting failed: \(result)")
            return
        }

        // The live layout is untouched: old binary + metallib still in place,
        // symlink still resolves to the OLD content.
        let liveMacOS = install.appendingPathComponent("Darkbloom.app/Contents/MacOS")
        #expect((try String(contentsOf: liveMacOS.appendingPathComponent("darkbloom"), encoding: .utf8)) == "old darkbloom")
        #expect((try String(contentsOf: liveMacOS.appendingPathComponent("mlx.metallib"), encoding: .utf8)) == "old metallib")
        #expect((try String(contentsOf: install.appendingPathComponent("bin/mlx.metallib"), encoding: .utf8)) == "old metallib")

        // The staged contents are verified and complete, off to the side.
        #expect(staged.stagingRoot.lastPathComponent.hasPrefix(".update-staging-"))
        #expect(FileManager.default.fileExists(
            atPath: staged.stagingRoot.appendingPathComponent("Darkbloom.app/Contents/MacOS/darkbloom").path))

        staged.discard()
        #expect(!FileManager.default.fileExists(atPath: staged.stagingRoot.path))
    }

    @Test("commit swaps the staged bundle into the live layout and cleans up")
    func commitSwapsStagedBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("self-updater-commit-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (tarball, release, install) = try makeAppBundleFixture(root: root)
        let updater = SelfUpdater(coordinatorBaseURL: "https://api.example.test")

        guard case .success(let staged) = updater.stageBundleForTesting(
            from: tarball, release: release, installDir: install)
        else {
            Issue.record("stageBundleForTesting failed")
            return
        }

        let result = updater.commitStagedBundle(staged)
        guard case .success = result else {
            Issue.record("commitStagedBundle failed: \(result)")
            return
        }

        // Live layout now serves the NEW bundle, via the bin/ symlinks.
        let installedBin = install.appendingPathComponent("bin")
        #expect((try String(contentsOf: installedBin.appendingPathComponent("darkbloom"), encoding: .utf8)) == "new app darkbloom")
        #expect((try String(contentsOf: installedBin.appendingPathComponent("mlx.metallib"), encoding: .utf8)) == "new app metallib")

        // No staging or backup residue left in the install dir.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: install.path)
            .filter { $0.hasPrefix(".update-staging-") || $0.hasPrefix(".update-backup-") }
        #expect(leftovers.isEmpty)
    }

    @Test("a later staging pass removes OLD orphaned staging dirs but spares young (possibly live) ones")
    func stagingCleansUpOrphanedDirs() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("self-updater-orphan-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let (tarball, release, install) = try makeAppBundleFixture(root: root)
        let updater = SelfUpdater(coordinatorBaseURL: "https://api.example.test")

        // Simulate a crash between stage and commit: an orphaned staging dir,
        // backdated past the stale-age threshold.
        let orphan = install.appendingPathComponent(".update-staging-orphan", isDirectory: true)
        try fm.createDirectory(at: orphan, withIntermediateDirectories: true)
        try fm.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -2 * 60 * 60)],
            ofItemAtPath: orphan.path)

        // A FRESH dir could belong to a live cycle in another process (e.g.
        // the serving daemon mid-update while a foreground `darkbloom update`
        // runs) and must be left alone.
        let live = install.appendingPathComponent(".update-staging-live", isDirectory: true)
        try fm.createDirectory(at: live, withIntermediateDirectories: true)

        guard case .success(let staged) = updater.stageBundleForTesting(
            from: tarball, release: release, installDir: install)
        else {
            Issue.record("stageBundleForTesting failed")
            return
        }
        defer { staged.discard() }

        #expect(!fm.fileExists(atPath: orphan.path))
        #expect(fm.fileExists(atPath: live.path))
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
