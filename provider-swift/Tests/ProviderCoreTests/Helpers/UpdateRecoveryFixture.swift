import Foundation
import Testing
@testable import ProviderCore

struct UpdateRecoveryFixture {
    let root: URL
    let installRoot: URL
    let tarball: URL
    let artifact: Data
    let release: ReleaseInfo
    let oldVersion: String
    let newVersion: String
    /// Layout of the initially-installed (predecessor) tree.
    let layout: VerifiedPredecessor.Layout
    /// Layout of the release the update installs. Defaults to `layout`; set it
    /// differently to model a legacy flat install updating to an .app candidate
    /// (the flat→app→rollback path).
    let candidateLayout: VerifiedPredecessor.Layout
    private let preservedFiles: [String: String] = [
        "provider.toml": "provider-config",
        "auth-token": "provider-token",
        "loaded-models.json": "[\"model-a\"]",
        "models/model-a/cache.bin": "model-cache",
        "io.darkbloom.provider.plist": "launchd-selection",
    ]

    init(
        oldVersion: String = "1.0.0",
        newVersion: String = "2.0.0",
        layout: VerifiedPredecessor.Layout = .app,
        candidateLayout: VerifiedPredecessor.Layout? = nil
    ) throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent(
            "update-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        installRoot = root.appendingPathComponent("install", isDirectory: true)
        tarball = root.appendingPathComponent("release.tar.gz")
        self.oldVersion = oldVersion
        self.newVersion = newVersion
        self.layout = layout
        self.candidateLayout = candidateLayout ?? layout

        if layout == .app {
            try Self.writeApp(version: oldVersion, root: installRoot)
            try Self.writeCanonicalLinks(root: installRoot)
        } else {
            try Self.writeFlat(version: oldVersion, root: installRoot)
        }
        for (relativePath, contents) in preservedFiles {
            let file = installRoot.appendingPathComponent(relativePath)
            try fm.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: file)
        }

        let releaseSource = root.appendingPathComponent("release-source", isDirectory: true)
        let flatBin = releaseSource.appendingPathComponent("bin", isDirectory: true)
        if self.candidateLayout == .app {
            try Self.writeApp(version: newVersion, root: releaseSource)
            try fm.createDirectory(at: flatBin, withIntermediateDirectories: true)
            let appBin = releaseSource.appendingPathComponent("Darkbloom.app/Contents/MacOS")
            for name in ["darkbloom", "darkbloom-enclave", "mlx.metallib"] {
                try fm.copyItem(
                    at: appBin.appendingPathComponent(name),
                    to: flatBin.appendingPathComponent(name)
                )
            }
        } else {
            try Self.writeFlat(version: newVersion, root: releaseSource)
        }

        try Self.runTar(source: releaseSource, destination: tarball)
        artifact = try Data(contentsOf: tarball)
        release = ReleaseInfo(
            version: newVersion,
            platform: "macos-arm64",
            url: "mock://release-artifact",
            bundleHash: sha256Hex(artifact),
            binaryHash: sha256Hex(try Data(contentsOf: flatBin.appendingPathComponent("darkbloom"))),
            metallibHash: sha256Hex(try Data(contentsOf: flatBin.appendingPathComponent("mlx.metallib")))
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func updater(baseURL: URL) -> SelfUpdater {
        SelfUpdater(
            coordinatorBaseURL: baseURL.absoluteString,
            installRoot: installRoot,
            verifyCodeSignatures: false,
            currentVersion: oldVersion,
            now: { 100 }
        )
    }

    func mockReleaseFixture() -> MockReleaseFixture {
        MockReleaseFixture(
            version: release.version,
            platform: release.platform,
            url: release.url,
            bundleHash: release.bundleHash,
            binaryHash: release.binaryHash,
            metallibHash: release.metallibHash
        )
    }

    func liveBinaryContents() throws -> String {
        let relative = layout == .app
            ? "Darkbloom.app/Contents/MacOS/darkbloom"
            : "bin/darkbloom"
        return try String(
            contentsOf: installRoot.appendingPathComponent(relative),
            encoding: .utf8
        )
    }

    /// Contents that `bin/darkbloom` RESOLVES to (following any symlink into a
    /// Darkbloom.app). After a flat rollback this must be the flat predecessor's
    /// real binary, not a symlink pointing back into a leftover candidate app.
    func liveFlatBinaryResolvedContents() throws -> String {
        try String(
            contentsOf: installRoot.appendingPathComponent("bin/darkbloom"),
            encoding: .utf8
        )
    }

    /// Whether a `Darkbloom.app` bundle is present at the install root.
    func appBundleExists() -> Bool {
        FileManager.default.fileExists(
            atPath: installRoot.appendingPathComponent("Darkbloom.app").path
        )
    }

    func persistentStateIsIntact() throws -> Bool {
        for (relativePath, expected) in preservedFiles {
            let contents = try String(
                contentsOf: installRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            if contents != expected { return false }
        }
        return true
    }

    static func writeApp(version: String, root: URL) throws {
        let fm = FileManager.default
        let contents = root.appendingPathComponent("Darkbloom.app/Contents")
        let appBin = contents.appendingPathComponent("MacOS")
        try fm.createDirectory(at: appBin, withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: contents.appendingPathComponent("Info.plist"))
        try Data("\(version)-darkbloom".utf8).write(to: appBin.appendingPathComponent("darkbloom"))
        try Data("\(version)-enclave".utf8).write(to: appBin.appendingPathComponent("darkbloom-enclave"))
        try Data("\(version)-metallib".utf8).write(to: appBin.appendingPathComponent("mlx.metallib"))
    }

    static func writeCanonicalLinks(root: URL) throws {
        let fm = FileManager.default
        let bin = root.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            atPath: bin.appendingPathComponent("darkbloom").path,
            withDestinationPath: "../Darkbloom.app/Contents/MacOS/darkbloom"
        )
        try fm.createSymbolicLink(
            atPath: bin.appendingPathComponent("darkbloom-enclave").path,
            withDestinationPath: "../Darkbloom.app/Contents/MacOS/darkbloom-enclave"
        )
        try fm.createSymbolicLink(
            atPath: bin.appendingPathComponent("mlx.metallib").path,
            withDestinationPath: "../Darkbloom.app/Contents/MacOS/mlx.metallib"
        )
        try fm.createSymbolicLink(
            atPath: bin.appendingPathComponent("eigeninference-enclave").path,
            withDestinationPath: "darkbloom-enclave"
        )
    }

    static func writeFlat(version: String, root: URL) throws {
        let fm = FileManager.default
        let bin = root.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("\(version)-darkbloom".utf8).write(
            to: bin.appendingPathComponent("darkbloom")
        )
        try Data("\(version)-enclave".utf8).write(
            to: bin.appendingPathComponent("darkbloom-enclave")
        )
        try Data("\(version)-metallib".utf8).write(
            to: bin.appendingPathComponent("mlx.metallib")
        )
        try fm.createSymbolicLink(
            atPath: bin.appendingPathComponent("eigeninference-enclave").path,
            withDestinationPath: "darkbloom-enclave"
        )
    }

    private static func runTar(source: URL, destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["czf", destination.path, "-C", source.path, "."]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

/// One-shot latch for fault injectors: the first `claim()` wins, replays
/// (e.g. transaction recovery through the same store) do not re-fire.
final class OneShotFault: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func claim() -> Bool {
        lock.withLock {
            guard !fired else { return false }
            fired = true
            return true
        }
    }
}

final class RecoveryRestartCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    @discardableResult
    func increment() -> Int {
        lock.withLock {
            storage += 1
            return storage
        }
    }
}
