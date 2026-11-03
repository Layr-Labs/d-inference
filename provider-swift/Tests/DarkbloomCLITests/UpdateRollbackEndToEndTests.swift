import Foundation
import Hummingbird
import NIOCore
import Testing
@testable import darkbloom
@testable import ProviderCore

/// `darkbloom update --rollback --yes` on two bundles of the built `darkbloom`
/// product, ad-hoc signed, in a temporary install root. Only the host (cluster
/// check, launchd, drain, restart) is faked. The restored binary is then run
/// itself: `--version`, and `update --check-only` against a loopback release
/// endpoint, with its home redirected into the scratch directory. No launchd
/// job, provider process or real install is touched.
@Suite("Update rollback end to end", .serialized)
struct UpdateRollbackEndToEndTests {
    @Test("the built CLI is rolled back to the old bundle, runs it, and its update check skips the rolled-back release")
    func rollbackOfBuiltBundles() async throws {
        let products = Bundle(for: EndToEndBundleSentinel.self).bundleURL.deletingLastPathComponent()
        let cli = products.appendingPathComponent("darkbloom")
        let enclave = products.appendingPathComponent("darkbloom-enclave")
        try #require(FileManager.default.isExecutableFile(atPath: cli.path), "built CLI missing: \(cli.path)")
        try #require(FileManager.default.isExecutableFile(atPath: enclave.path), "built enclave missing: \(enclave.path)")
        let patch = ProviderCore.version.split(separator: ".").compactMap { Int($0) }
        try #require(patch.count == 3, "ProviderCore.version is not MAJOR.MINOR.PATCH: \(ProviderCore.version)")
        // The restored release reports the built version; the release it replaces and a later one are newer labels.
        let old = ProviderCore.version
        let new = "\(patch[0]).\(patch[1]).\(patch[2] + 1)"
        let newer = "\(patch[0]).\(patch[1]).\(patch[2] + 2)"

        let fm = FileManager.default
        let scratch = URL(fileURLWithPath: try #require(realpath(fm.temporaryDirectory.path, nil).map {
            defer { free($0) }
            return String(cString: $0)
        })).appendingPathComponent("update-rollback-e2e-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }
        let root = scratch.appendingPathComponent("install", isDirectory: true)
        let liveApp = root.appendingPathComponent("Darkbloom.app", isDirectory: true)

        try Self.makeSignedApp(version: old, cli: cli, enclave: enclave, at: liveApp)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["darkbloom", "darkbloom-enclave", "mlx.metallib"] {
            try fm.createSymbolicLink(
                atPath: bin.appendingPathComponent(name).path,
                withDestinationPath: "../Darkbloom.app/Contents/MacOS/\(name)")
        }
        let oldTree = try UpdateAtomicFilesystem.treeHash(root: liveApp)

        // v`new` is installed over v`old` by the updater, which keeps v`old`, and is promoted.
        let release = scratch.appendingPathComponent("release", isDirectory: true)
        try Self.makeSignedApp(version: new, cli: cli, enclave: enclave,
                               at: release.appendingPathComponent("Darkbloom.app", isDirectory: true))
        let flat = release.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: flat, withIntermediateDirectories: true)
        for name in ["darkbloom", "darkbloom-enclave", "mlx.metallib"] {
            try Self.run("/bin/cp", ["-c", release.appendingPathComponent("Darkbloom.app/Contents/MacOS/\(name)").path,
                                     flat.appendingPathComponent(name).path])
        }
        let tarball = scratch.appendingPathComponent("release.tar.gz")
        try Self.run("/usr/bin/tar", ["czf", tarball.path, "-C", release.path, "."])
        let installer = SelfUpdater(
            coordinatorBaseURL: "http://127.0.0.1:9", installRoot: root, verifyCodeSignatures: false, currentVersion: old)
        let installed = installer.installBundleForTesting(
            from: tarball,
            release: ReleaseInfo(version: new, platform: "macos-arm64", url: "unused://", bundleHash: "unused"),
            installDir: root)
        guard case .success = installed else {
            Issue.record("v\(new) did not install: \(installed)")
            return
        }
        let store = UpdateRecoveryStore(installRoot: root, verifyCodeSignatures: false)
        var promoted = try store.loadState()
        promoted.promoteCandidate()
        try store.writeState(promoted)
        let newTree = try UpdateAtomicFilesystem.treeHash(root: liveApp)
        #expect(newTree != oldTree)
        #expect(try Self.bundleVersion(liveApp) == new)

        // `darkbloom update --rollback --yes`, with no terminal to ask on.
        let command = try #require(try Darkbloom.parseAsRoot(["update", "--rollback", "--yes"]) as? Update)
        let updater = SelfUpdater(
            coordinatorBaseURL: "http://127.0.0.1:9", installRoot: root, verifyCodeSignatures: false, currentVersion: new)
        let log = EndToEndLog()
        let host = UpdateRollback.Host(
            servesInCluster: { false },
            holdClusterOut: {
                try UpdateProcessLock.attempt(at: scratch.appendingPathComponent("service.lock"), operation: "operator-rollback").lock
            },
            provider: { .service },
            serviceProcess: { nil },
            holdProviderStartsOut: {
                try UpdateProcessLock.attempt(at: scratch.appendingPathComponent("provider.pid.lock"), operation: "operator-rollback")
            },
            canAsk: { false },
            readAnswer: { nil },
            drain: { log.record("drain") },
            restart: { log.record("restart") },
            waitForRestart: { log.record("wait") })
        try await UpdateRollback(updater: updater, host: host, say: { log.say($0) }).run(skipConfirmation: command.yes)

        #expect(log.events == ["drain", "restart", "wait"])
        #expect(log.lines.contains("Rolled back: v\(new) -> v\(old)."))
        // The live bundle is the old one, byte for byte, and its signature still verifies.
        #expect(try UpdateAtomicFilesystem.treeHash(root: liveApp) == oldTree)
        #expect(try Self.bundleVersion(liveApp) == old)
        try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", liveApp.path])
        let state = try store.loadState()
        #expect(state.current?.version == old)
        #expect(state.candidate == nil)
        #expect(state.predecessor?.release.version == old)
        #expect(state.quarantine?.version == new)
        #expect(state.quarantine?.reason.contains("update --rollback") == true)
        #expect(state.installGeneration == promoted.installGeneration + 1)
        let leftovers = try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".") }
        #expect(leftovers.isEmpty, "\(leftovers)")
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("recovery/transaction.json").path))

        // The restored CLI runs, from the operator's bin/ link.
        let home = scratch.appendingPathComponent("home", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let environment = [
            "HOME": home.path, "CFFIXED_USER_HOME": home.path, "PATH": "/usr/bin:/bin",
            "DARKBLOOM_NO_UPDATE_CHECK": "1", "NO_COLOR": "1",
        ]
        let restored = bin.appendingPathComponent("darkbloom").path
        #expect(try Self.run(restored, ["--version"], environment: environment).trimmingCharacters(in: .whitespacesAndNewlines) == old)

        // Its update check reads this root's recovery state and skips the rolled-back release.
        let config = scratch.appendingPathComponent("provider.toml")
        try ConfigManager.save(ProviderConfig(
            provider: ProviderSettings(name: "update-rollback-e2e", memoryReserveGB: 1),
            backend: BackendSettings(modelCacheDirectory: scratch.appendingPathComponent("hub").path),
            coordinator: CoordinatorSettings(url: "http://127.0.0.1:9", heartbeatIntervalSecs: 5)), to: config)
        let latest = LatestRelease(version: new)
        try await LatestRelease.serve(latest) { endpoint in
            let check = ["update", "--check-only", "--config", config.path, "--coordinator", endpoint.absoluteString]
            let blocked = try Self.run(restored, check, environment: environment)
            #expect(blocked.contains("Current version: \(old)"))
            #expect(blocked.contains("Latest release v\(new) is quarantined on this machine."))
            #expect(blocked.contains("Reason: rolled back by the operator to v\(old)"))
            #expect(!blocked.contains("Update available"))

            let overridden = try Self.run(restored, check + ["--override-quarantine"], environment: environment)
            #expect(overridden.contains("Update available: v\(old) -> v\(new)"))

            latest.version = newer
            let next = try Self.run(restored, check, environment: environment)
            #expect(next.contains("Update available: v\(old) -> v\(newer)"))
        }
        #expect(latest.requests == 3)
        // The child resolved its install root from its own bundle, never from its home.
        #expect(try fm.contentsOfDirectory(atPath: home.path).filter { $0.hasPrefix(".darkbloom") }.isEmpty)
    }

    /// A signed `Darkbloom.app` of the built CLI whose bundle version is `version`.
    private static func makeSignedApp(version: String, cli: URL, enclave: URL, at app: URL) throws {
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try run("/bin/cp", ["-c", cli.path, macOS.appendingPathComponent("darkbloom").path])
        try run("/bin/cp", ["-c", enclave.path, macOS.appendingPathComponent("darkbloom-enclave").path])
        // Hashed and swapped like the real library; nothing here loads it.
        try Data("mlx.metallib of the update rollback end-to-end test".utf8)
            .write(to: macOS.appendingPathComponent("mlx.metallib"))
        let info: [String: Any] = [
            "CFBundleIdentifier": "io.darkbloom.provider",
            "CFBundleExecutable": "darkbloom",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        for name in ["mlx.metallib", "darkbloom-enclave", "darkbloom"] {
            try run("/usr/bin/codesign", ["--force", "--sign", "-", macOS.appendingPathComponent(name).path])
        }
        try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    }

    private static func bundleVersion(_ app: URL) throws -> String? {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return plist?["CFBundleShortVersionString"] as? String
    }

    /// Runs a child to completion and returns its standard output; a nonzero exit is an error.
    @discardableResult
    private static func run(_ path: String, _ arguments: [String], environment: [String: String]? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ChildFailure(command: ([path] + arguments).joined(separator: " "),
                               status: process.terminationStatus, output: stdout + stderr)
        }
        return stdout
    }

    private struct ChildFailure: Error, CustomStringConvertible {
        let command: String
        let status: Int32
        let output: String
        var description: String { "\(command) exited \(status): \(output)" }
    }
}

private final class EndToEndBundleSentinel {}

private final class EndToEndLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [String] = []
    private var recordedLines: [String] = []
    var events: [String] { lock.withLock { recordedEvents } }
    var lines: [String] { lock.withLock { recordedLines } }
    func record(_ event: String) { lock.withLock { recordedEvents.append(event) } }
    func say(_ line: String) { lock.withLock { recordedLines.append(line) } }
}

/// `GET /v1/releases/latest` on an ephemeral loopback port.
private final class LatestRelease: @unchecked Sendable {
    private let lock = NSLock()
    private var current: String
    private var served = 0

    init(version: String) { current = version }

    var version: String {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    var requests: Int { lock.withLock { served } }

    private func body() -> Data {
        let version = lock.withLock { () -> String in
            served += 1
            return current
        }
        let object: [String: Any] = [
            "version": version, "platform": "macos-arm64",
            "url": "http://127.0.0.1:9/darkbloom-\(version).tar.gz", "bundle_hash": "bundle-\(version)",
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    static func serve(_ release: LatestRelease, _ body: (URL) async throws -> Void) async throws {
        let router = Router()
        router.get("/v1/releases/latest") { _, _ -> Response in
            Response(status: .ok, body: .init(byteBuffer: ByteBuffer(bytes: Array(release.body()))))
        }
        let (ports, port) = AsyncStream.makeStream(of: Int.self)
        let app = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: 0)),
            onServerRunning: { channel in
                port.yield(channel.localAddress?.port ?? 0)
                port.finish()
            })
        let server = Task { try await app.runService(gracefulShutdownSignals: []) }
        defer { server.cancel() }
        var iterator = ports.makeAsyncIterator()
        let bound = try #require(await iterator.next())
        try #require(bound >= 49152, "not an ephemeral port: \(bound)")
        try await body(URL(string: "http://127.0.0.1:\(bound)")!)
    }
}
