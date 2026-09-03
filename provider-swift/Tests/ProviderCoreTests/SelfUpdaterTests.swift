import Foundation
import Testing
@testable import ProviderCore

private struct ReleaseFixtureCorpus {
    let cases: [ReleaseFixtureCase]
}

private struct ReleaseFixtureCase {
    let name: String
    let coordinatorEncodes: Bool
    let response: [String: Any]
    let expected: ReleaseFixtureExpected?
    let errorContains: String?
}

private struct ReleaseFixtureExpected {
    let version: String
    let platform: String
    let url: String
    let bundleHash: String
    let binaryHash: String?
    let metallibHash: String?
}

private enum ReleaseFixtureError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let description):
            return description
        }
    }
}

private final class ReleaseFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var payload = Data()
    nonisolated(unsafe) static var lastURL: URL?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastURL = request.url
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func releaseFixtureData() throws -> Data {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0 ..< 4 { root.deleteLastPathComponent() }
    return try Data(contentsOf: root.appendingPathComponent(
        "fixtures/release/v1/latest_response.json"
    ))
}

private func releaseFixtureRequiredString(
    _ key: String,
    in object: [String: Any],
    context: String
) throws -> String {
    guard let value = object[key] as? String else {
        throw ReleaseFixtureError.invalid("\(context) is missing string field \(key)")
    }
    return value
}

private func releaseFixtureOptionalString(
    _ key: String,
    in object: [String: Any],
    context: String
) throws -> String? {
    guard let rawValue = object[key] else { return nil }
    guard let value = rawValue as? String else {
        throw ReleaseFixtureError.invalid("\(context) field \(key) is not a string")
    }
    return value
}

private func decodeReleaseFixtureCorpus(_ data: Data) throws -> ReleaseFixtureCorpus {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ReleaseFixtureError.invalid("release fixture root is not an object")
    }
    guard let schemaVersion = root["schema_version"] as? Int, schemaVersion == 1 else {
        throw ReleaseFixtureError.invalid(
            "unsupported or missing release fixture schema version"
        )
    }
    guard let rawCases = root["cases"] as? [[String: Any]] else {
        throw ReleaseFixtureError.invalid("release fixture cases are missing")
    }

    let cases = try rawCases.map { rawCase in
        let name = try releaseFixtureRequiredString(
            "name",
            in: rawCase,
            context: "release fixture case"
        )
        guard let coordinatorEncodes = rawCase["coordinator_encodes"] as? Bool,
              let response = rawCase["response"] as? [String: Any]
        else {
            throw ReleaseFixtureError.invalid(
                "release fixture case \(name) has invalid metadata or response"
            )
        }

        let expected: ReleaseFixtureExpected?
        if let rawExpected = rawCase["expected"] {
            guard let object = rawExpected as? [String: Any] else {
                throw ReleaseFixtureError.invalid(
                    "release fixture case \(name) has an invalid expected result"
                )
            }
            expected = try ReleaseFixtureExpected(
                version: releaseFixtureRequiredString(
                    "version", in: object, context: "release fixture case \(name) expected"
                ),
                platform: releaseFixtureRequiredString(
                    "platform", in: object, context: "release fixture case \(name) expected"
                ),
                url: releaseFixtureRequiredString(
                    "url", in: object, context: "release fixture case \(name) expected"
                ),
                bundleHash: releaseFixtureRequiredString(
                    "bundle_hash", in: object, context: "release fixture case \(name) expected"
                ),
                binaryHash: releaseFixtureOptionalString(
                    "binary_hash", in: object, context: "release fixture case \(name) expected"
                ),
                metallibHash: releaseFixtureOptionalString(
                    "metallib_hash", in: object, context: "release fixture case \(name) expected"
                )
            )
        } else {
            expected = nil
        }

        return try ReleaseFixtureCase(
            name: name,
            coordinatorEncodes: coordinatorEncodes,
            response: response,
            expected: expected,
            errorContains: releaseFixtureOptionalString(
                "error_contains", in: rawCase, context: "release fixture case \(name)"
            )
        )
    }
    return ReleaseFixtureCorpus(cases: cases)
}

private func releaseFixtureCorpus() throws -> ReleaseFixtureCorpus {
    try decodeReleaseFixtureCorpus(releaseFixtureData())
}

@Suite("SelfUpdater")
struct SelfUpdaterTests {
    @Test("production public init always verifies code signatures")
    func productionInitVerifiesSignatures() {
        // The only way to disable the signature pin is the internal
        // `verifyCodeSignatures:` seam used by tests/fixtures; the public
        // production initializer must never select the unsigned path.
        #expect(SelfUpdater(coordinatorBaseURL: "https://api.example").verifiesCodeSignatures)
        #expect(
            SelfUpdater(
                coordinatorBaseURL: "https://api.example",
                urlSession: SelfUpdater.watchdogURLSession()
            ).verifiesCodeSignatures
        )
    }

    @Test("effective installed version prefers the newer of process and durable record")
    func effectiveInstalledVersionSelection() {
        // Surviving watchdog: process is older than the promoted disk install.
        #expect(SelfUpdater.effectiveInstalledVersion(
            processVersion: "1.0.0",
            recorded: "2.0.0"
        ) == "2.0.0")
        // Manual reinstall bypassed recovery state: process is newer.
        #expect(SelfUpdater.effectiveInstalledVersion(
            processVersion: "3.0.0",
            recorded: "1.0.0"
        ) == "3.0.0")
        // No durable record (fresh install) → process version.
        #expect(SelfUpdater.effectiveInstalledVersion(
            processVersion: "1.0.0",
            recorded: nil
        ) == "1.0.0")
        // Invalid durable record → process version.
        #expect(SelfUpdater.effectiveInstalledVersion(
            processVersion: "1.0.0",
            recorded: "not-a-version"
        ) == "1.0.0")
        // Invalid process version → durable record.
        #expect(SelfUpdater.effectiveInstalledVersion(
            processVersion: "dev",
            recorded: "2.0.0"
        ) == "2.0.0")
    }

    @Test("SemVer prerelease ordering is exact")
    func semverPrereleaseOrdering() {
        #expect(SelfUpdater.isNewer(
            latest: "0.8.0-dev.2",
            current: "0.8.0-dev.1"
        ))
        #expect(SelfUpdater.isNewer(
            latest: "0.8.0",
            current: "0.8.0-dev.9"
        ))
        #expect(!SelfUpdater.isNewer(
            latest: "0.8.0-dev.1",
            current: "0.8.0"
        ))
        #expect(SelfUpdater.isNewer(
            latest: "0.8.0-rc.1",
            current: "0.8.0-beta.11"
        ))
        #expect(!SelfUpdater.isNewer(
            latest: "0.8.0-dev.01",
            current: "0.8.0-dev.1"
        ))
    }

    #if canImport(Darwin)
    @Test("real packaged code signature is verified and production pin rejects ad hoc signer")
    func realPackagedSignatureVerification() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codesign-fixture-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Darkbloom.app")
        let contents = app.appendingPathComponent("Contents")
        let bin = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(
            at: bin,
            withIntermediateDirectories: true
        )
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>io.darkbloom.provider</string>
        <key>CFBundleExecutable</key><string>darkbloom</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        </dict></plist>
        """
        try Data(plist.utf8).write(
            to: contents.appendingPathComponent("Info.plist")
        )
        for name in ["darkbloom", "darkbloom-enclave", "mlx.metallib"] {
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: "/usr/bin/true"),
                to: bin.appendingPathComponent(name)
            )
        }
        try runCodesign(["--force", "--deep", "--sign", "-", app.path])

        try DarkbloomCodeSignature.verify(
            app,
            deep: true,
            policy: .structuralForIsolatedTest
        )
        #expect(throws: (any Error).self) {
            try DarkbloomCodeSignature.verify(app, deep: true)
        }
    }
    #endif

    @Test("shared release responses decode current and legacy hash shapes")
    func sharedReleaseResponseDecoding() throws {
        let corpus = try releaseFixtureCorpus()
        let caseNames = Set(corpus.cases.map(\.name))
        #expect(caseNames.count == corpus.cases.count)
        #expect(caseNames.contains("current_mlx_swift_signed_bundle"))
        #expect(caseNames.contains("legacy_vllm_runtime_hashes"))
        #expect(corpus.cases.contains { $0.coordinatorEncodes })

        for fixture in corpus.cases {
            let data = try JSONSerialization.data(withJSONObject: fixture.response)
            if let expected = fixture.expected {
                let actual = try SelfUpdater.decodeLatestReleaseResponse(data)
                #expect(actual.version == expected.version, Comment(rawValue: fixture.name))
                #expect(actual.platform == expected.platform, Comment(rawValue: fixture.name))
                #expect(actual.url == expected.url, Comment(rawValue: fixture.name))
                #expect(actual.bundleHash == expected.bundleHash, Comment(rawValue: fixture.name))
                #expect(actual.binaryHash == expected.binaryHash, Comment(rawValue: fixture.name))
                #expect(actual.metallibHash == expected.metallibHash, Comment(rawValue: fixture.name))
            } else {
                guard let errorContains = fixture.errorContains else {
                    Issue.record("fixture \(fixture.name) has no expected result")
                    continue
                }
                do {
                    _ = try SelfUpdater.decodeLatestReleaseResponse(data)
                    Issue.record("fixture \(fixture.name) was accepted")
                } catch {
                    #expect(
                        error.localizedDescription.contains(errorContains),
                        Comment(rawValue: fixture.name)
                    )
                }
            }
        }
    }

    @Test("shared release fixture schema version is required and supported")
    func sharedReleaseFixtureSchemaVersionFailsClosed() {
        #expect(throws: (any Error).self) {
            try decodeReleaseFixtureCorpus(Data(#"{"cases":[]}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try decodeReleaseFixtureCorpus(
                Data(#"{"schema_version":2,"cases":[]}"#.utf8)
            )
        }
    }

    @Test("release fetch consumes the shared current response shape")
    func releaseFetchConsumesSharedCurrentResponse() async throws {
        let fixture = try #require(
            releaseFixtureCorpus().cases.first {
                $0.name == "current_mlx_swift_signed_bundle"
            }
        )
        let expected = try #require(fixture.expected)
        ReleaseFixtureURLProtocol.payload = try JSONSerialization.data(
            withJSONObject: fixture.response
        )
        ReleaseFixtureURLProtocol.lastURL = nil

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReleaseFixtureURLProtocol.self]
        let updater = SelfUpdater(
            coordinatorBaseURL: "https://coordinator.example.test/ws/provider",
            urlSession: URLSession(configuration: configuration)
        )
        let result = await updater.checkForUpdate()

        guard case .updateAvailable(_, let latest) = result else {
            Issue.record("expected updateAvailable, got \(result)")
            return
        }
        #expect(latest.bundleHash == expected.bundleHash)
        #expect(latest.binaryHash == expected.binaryHash)
        #expect(latest.metallibHash == expected.metallibHash)
        #expect(ReleaseFixtureURLProtocol.lastURL?.path == "/v1/releases/latest")
        #expect(ReleaseFixtureURLProtocol.lastURL?.query == "platform=macos-arm64")
    }

    @Test("release endpoint refuses a mismatched platform")
    func releaseEndpointRefusesWrongPlatform() async throws {
        let mock = MockCoordinator(release: MockReleaseFixture(
            version: "99.0.0",
            platform: "linux-amd64"
        ))
        let baseURL = try await mock.start()
        defer { Task { await mock.shutdown() } }

        let result = await SelfUpdater(
            coordinatorBaseURL: baseURL.absoluteString
        ).checkForUpdate()
        guard case .checkFailed(let reason) = result else {
            Issue.record("wrong-platform release was accepted")
            return
        }
        #expect(reason.contains("unsupported release platform"))
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
        let oldBin = install.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: oldBin, withIntermediateDirectories: true)
        try Data("old darkbloom".utf8).write(to: oldBin.appendingPathComponent("darkbloom"))
        try Data("old enclave".utf8).write(to: oldBin.appendingPathComponent("darkbloom-enclave"))
        try Data("old metallib".utf8).write(to: oldBin.appendingPathComponent("mlx.metallib"))
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
        let appHelpers = stage.appendingPathComponent("Darkbloom.app/Contents/Helpers")
        let binFlat = stage.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: appMacOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appHelpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binFlat, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
        let oldAppBin = install.appendingPathComponent("Darkbloom.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: oldAppBin, withIntermediateDirectories: true)
        try Data("old app darkbloom".utf8).write(to: oldAppBin.appendingPathComponent("darkbloom"))
        try Data("old app enclave".utf8).write(to: oldAppBin.appendingPathComponent("darkbloom-enclave"))
        try Data("old app metallib".utf8).write(to: oldAppBin.appendingPathComponent("mlx.metallib"))

        // Write Info.plist for the .app bundle.
        let infoDir = stage.appendingPathComponent("Darkbloom.app/Contents")
        try Data("<plist/>".utf8).write(to: infoDir.appendingPathComponent("Info.plist"))

        // Write the binaries inside the .app bundle.
        try Data("app darkbloom".utf8).write(to: appMacOS.appendingPathComponent("darkbloom"))
        try Data("app enclave".utf8).write(to: appMacOS.appendingPathComponent("darkbloom-enclave"))
        try Data("app metallib".utf8).write(to: appMacOS.appendingPathComponent("mlx.metallib"))
        let fanHelper = appHelpers.appendingPathComponent("darkbloom-fan-helper")
        try Data("app fan helper".utf8).write(to: fanHelper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fanHelper.path)
        let resourceBundle = stage.appendingPathComponent(
            "Darkbloom.app/Contents/Resources/mlx-swift-lm_MLXLMCommon.bundle",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: resourceBundle,
            withIntermediateDirectories: true)
        try Data("paged kernel source".utf8).write(
            to: resourceBundle.appendingPathComponent("pagedattention.metal"))

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
        let installedPagedResource = install.appendingPathComponent(
            "Darkbloom.app/Contents/Resources/mlx-swift-lm_MLXLMCommon.bundle/"
                + "pagedattention.metal")
        #expect(
            (try String(contentsOf: installedPagedResource, encoding: .utf8))
                == "paged kernel source")
        let installedFanHelper = install.appendingPathComponent(
            "Darkbloom.app/Contents/Helpers/darkbloom-fan-helper"
        )
        #expect(
            try String(contentsOf: installedFanHelper, encoding: .utf8)
                == "app fan helper"
        )
        let helperAttributes = try FileManager.default.attributesOfItem(
            atPath: installedFanHelper.path
        )
        #expect((helperAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)

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
        try Data("old enclave".utf8).write(to: liveMacOS.appendingPathComponent("darkbloom-enclave"))
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

    private func debugBuildProduct(_ name: String) throws -> URL {
        var packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(
            atPath: packageRoot.appendingPathComponent("Package.swift").path)
        {
            let parent = packageRoot.deletingLastPathComponent()
            guard parent.path != packageRoot.path else {
                throw CocoaError(.fileNoSuchFile)
            }
            packageRoot = parent
        }
        let product = packageRoot.appendingPathComponent(".build/debug/\(name)")
        guard FileManager.default.fileExists(atPath: product.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return product
    }

    private func makeSignedRuntimeFixture(
        root: URL,
        includeResource: Bool,
        includeFanHelper: Bool = true
    ) throws -> (URL, ReleaseInfo, URL) {
        let fm = FileManager.default
        let stage = root.appendingPathComponent("signed-src", isDirectory: true)
        let app = stage.appendingPathComponent("Darkbloom.app", isDirectory: true)
        let appMacOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let helpers = app.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        let bin = stage.appendingPathComponent("bin", isDirectory: true)
        let install = root.appendingPathComponent("install", isDirectory: true)
        try fm.createDirectory(at: appMacOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: helpers, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createDirectory(at: install, withIntermediateDirectories: true)

        let darkbloom = try debugBuildProduct("darkbloom")
        let fanHelper = try debugBuildProduct("darkbloom-fan-helper")
        let metallib = try debugBuildProduct("mlx.metallib")
        try fm.copyItem(
            at: darkbloom,
            to: appMacOS.appendingPathComponent("darkbloom"))
        try fm.copyItem(
            at: darkbloom,
            to: appMacOS.appendingPathComponent("darkbloom-enclave"))
        try fm.copyItem(
            at: metallib,
            to: appMacOS.appendingPathComponent("mlx.metallib"))
        let stagedFanHelper = helpers.appendingPathComponent("darkbloom-fan-helper")
        if includeFanHelper {
            try fm.copyItem(at: fanHelper, to: stagedFanHelper)
            try fm.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: stagedFanHelper.path)
        }
        let info: [String: Any] = [
            "CFBundleIdentifier": "io.darkbloom.selfupdater-test",
            "CFBundleExecutable": "darkbloom",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
        ]
        try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let capability = resources.appendingPathComponent(
            "darkbloom-runtime-capabilities",
            isDirectory: true)
        try fm.createDirectory(at: capability, withIntermediateDirectories: true)
        try Data("1\n".utf8).write(
            to: capability.appendingPathComponent("paged-kernel-v1"))
        try Data("1\n".utf8).write(
            to: capability.appendingPathComponent("fan-helper-v1"))
        if includeResource {
            let builtBundle = try debugBuildProduct(
                PackagedRuntimeSmoke.mlxLMCommonBundleName)
            try fm.copyItem(
                at: builtBundle,
                to: resources.appendingPathComponent(
                    PackagedRuntimeSmoke.mlxLMCommonBundleName,
                    isDirectory: true))
        }

        if includeFanHelper {
            try runTestProcess(
                "/usr/bin/codesign",
                ["--force", "--sign", "-", "--identifier", "io.darkbloom.fan-helper", stagedFanHelper.path])
        }
        try runTestProcess(
            "/usr/bin/codesign",
            ["--force", "--sign", "-", appMacOS.appendingPathComponent("mlx.metallib").path])
        try runTestProcess(
            "/usr/bin/codesign",
            ["--force", "--sign", "-", appMacOS.appendingPathComponent("darkbloom-enclave").path])
        try runTestProcess(
            "/usr/bin/codesign",
            ["--force", "--sign", "-", appMacOS.appendingPathComponent("darkbloom").path])
        try runTestProcess(
            "/usr/bin/codesign",
            ["--force", "--sign", "-", app.path])
        try runTestProcess(
            "/usr/bin/codesign",
            ["--verify", "--deep", "--strict", app.path])

        try fm.copyItem(
            at: appMacOS.appendingPathComponent("darkbloom"),
            to: bin.appendingPathComponent("darkbloom"))
        try fm.copyItem(
            at: appMacOS.appendingPathComponent("darkbloom-enclave"),
            to: bin.appendingPathComponent("darkbloom-enclave"))
        try fm.copyItem(
            at: appMacOS.appendingPathComponent("mlx.metallib"),
            to: bin.appendingPathComponent("mlx.metallib"))
        let tarball = root.appendingPathComponent(
            includeResource ? "signed-valid.tar.gz" : "signed-missing.tar.gz")
        try runTarCreate(sourceDir: stage, tarball: tarball)
        let release = ReleaseInfo(
            version: "test",
            platform: "macos-arm64",
            url: "file://unused",
            bundleHash: sha256Hex(try Data(contentsOf: tarball)),
            binaryHash: sha256Hex(
                try Data(contentsOf: bin.appendingPathComponent("darkbloom"))),
            metallibHash: sha256Hex(
                try Data(contentsOf: bin.appendingPathComponent("mlx.metallib"))))
        return (tarball, release, install)
    }

    @Test("v0.8.9 parent can bootstrap a v0.8.10 runtime-smoke child")
    func oldParentBootstrapsCandidateSmoke() throws {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        let executable = try debugBuildProduct("darkbloom")
        let output = try BoundedProcess.runCapturingStandardOutput(
            executable,
            arguments: ["runtime-smoke"],
            environment: [
                "DARKBLOOM_NO_UPDATE_CHECK": "1",
                GemmaOptimizationEnvironment.prefillLayer18Key: "0",
                GemmaOptimizationEnvironment.weightedUnsortKey: "0",
                GemmaOptimizationEnvironment.safeR1Key: "0",
            ],
            timeout: 30)
        #expect(PackagedRuntimeSmoke.containsGemmaOptimizationSuccessMarker(output))
        #expect(String(data: output, encoding: .utf8)?.contains(
            "paged-kernel-runtime-smoke: ok") == true)
    }

    @Test("signed extracted child proves retained Gemma marker before staging succeeds")
    func signedAppRunsRealVerification() throws {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "self-updater-signed-test-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let updater = SelfUpdater(coordinatorBaseURL: "https://api.example.test")

        let (validTar, validRelease, install) = try makeSignedRuntimeFixture(
            root: root.appendingPathComponent("valid", isDirectory: true),
            includeResource: true)
        let validResult = updater.stageSignedBundleForTesting(
            from: validTar,
            release: validRelease,
            installDir: install)
        guard case .success(let staged) = validResult else {
            guard case .failure(let error) = validResult else {
                Issue.record("real signed/runtime marker verification returned an unknown result")
                return
            }
            Issue.record("real signed/runtime marker verification failed: \(error)")
            return
        }
        staged.discard()

        let (missingTar, missingRelease, missingInstall) = try makeSignedRuntimeFixture(
            root: root.appendingPathComponent("missing", isDirectory: true),
            includeResource: false)
        guard case .failure = updater.stageSignedBundleForTesting(
            from: missingTar,
            release: missingRelease,
            installDir: missingInstall)
        else {
            Issue.record("paged-capable app without its resource unexpectedly staged")
            return
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: missingInstall.appendingPathComponent("Darkbloom.app").path))
    }

    @Test("fan-capable signed app without its helper is rejected")
    func signedAppRequiresFanHelper() throws {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "self-updater-fan-helper-test-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let updater = SelfUpdater(coordinatorBaseURL: "https://api.example.test")
        let (tarball, release, install) = try makeSignedRuntimeFixture(
            root: root,
            includeResource: true,
            includeFanHelper: false
        )

        guard case .failure(let error) = updater.stageSignedBundleForTesting(
            from: tarball,
            release: release,
            installDir: install
        ) else {
            Issue.record("fan-capable app without its helper unexpectedly staged")
            return
        }
        #expect("\(error)".contains("fan-capable artifact"))
    }

    @Test("fan capability verifier requires a regular executable helper")
    func fanCapabilityRequiresExecutableHelper() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fan-capability-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (app, executable, helper) = try makeFanCapabilityFixture(root: root)

        try FanHelperCapabilityVerifier.verify(
            app: app,
            executable: executable,
            signaturePolicy: nil
        )

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: helper.path
        )
        #expect(throws: (any Error).self) {
            try FanHelperCapabilityVerifier.verify(
                app: app,
                executable: executable,
                signaturePolicy: nil
            )
        }
    }

    @Test("fan capability verifier rejects a symlink helper")
    func fanCapabilityRejectsSymlinkHelper() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fan-capability-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (app, executable, helper) = try makeFanCapabilityFixture(root: root)
        let payload = helper.deletingLastPathComponent().appendingPathComponent("payload")
        try FileManager.default.moveItem(at: helper, to: payload)
        try FileManager.default.createSymbolicLink(
            atPath: helper.path,
            withDestinationPath: payload.path
        )

        #expect(throws: (any Error).self) {
            try FanHelperCapabilityVerifier.verify(
                app: app,
                executable: executable,
                signaturePolicy: nil
            )
        }
    }

    private func makeFanCapabilityFixture(
        root: URL
    ) throws -> (app: URL, executable: URL, helper: URL) {
        let app = root.appendingPathComponent("Darkbloom.app")
        let executable = app.appendingPathComponent("Contents/MacOS/darkbloom")
        let helper = app.appendingPathComponent(
            FanHelperCapabilityVerifier.helperRelativePath
        )
        let marker = app.appendingPathComponent(
            FanHelperCapabilityVerifier.markerRelativePath
        )
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: marker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(FanHelperCapabilityVerifier.binaryCapability.utf8).write(to: executable)
        try Data("helper".utf8).write(to: helper)
        try Data("1\n".utf8).write(to: marker)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helper.path
        )
        return (app, executable, helper)
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

        let result = updater.commitStagedBundleForTesting(staged)
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

    @Test("commit refuses a staged tree changed after verification")
    func commitRefusesPostStageMutation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "self-updater-stage-mutation-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let (tarball, release, install) = try makeAppBundleFixture(root: root)
        let updater = SelfUpdater(coordinatorBaseURL: "https://api.example.test")
        guard case .success(let staged) = updater.stageBundleForTesting(
            from: tarball,
            release: release,
            installDir: install
        ) else {
            Issue.record("stageBundleForTesting failed")
            return
        }
        try Data("post-verification tamper".utf8).write(
            to: staged.stagingRoot
                .appendingPathComponent("Darkbloom.app/Contents/Info.plist")
        )

        guard case .failure(let error) = updater.commitStagedBundleForTesting(staged) else {
            Issue.record("mutated staging tree was installed")
            return
        }
        #expect("\(error)".contains("changed after verification"))
        #expect(try String(
            contentsOf: install.appendingPathComponent(
                "Darkbloom.app/Contents/MacOS/darkbloom"),
            encoding: .utf8
        ) == "old darkbloom")
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

private func runCodesign(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CocoaError(.fileWriteUnknown)
    }
}

private func runTestProcess(
    _ executable: String,
    _ arguments: [String]
) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let message = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8) ?? ""
        throw CocoaError(
            .fileWriteUnknown,
            userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: - installRoot derivation (symlink regression)

@Suite("SelfUpdater.installRoot")
struct SelfUpdaterInstallRootTests {

    @Test("flat bin layout derives the darkbloom root")
    func flatLayout() {
        let root = SelfUpdater.installRoot(
            forExecutablePath: "/Users/op/.darkbloom/bin/darkbloom")
        #expect(root.path.hasSuffix("/.darkbloom"))
    }

    @Test("app bundle layout walks out of Contents/MacOS")
    func appBundleLayout() {
        let root = SelfUpdater.installRoot(
            forExecutablePath:
                "/Users/op/.darkbloom/Darkbloom.app/Contents/MacOS/darkbloom")
        #expect(root.path.hasSuffix("/.darkbloom"))
    }

    /// Regression for the fleet-wide `darkbloom update` failure: install.sh
    /// symlinks /usr/local/bin/darkbloom -> ~/.darkbloom/bin/darkbloom, and the
    /// executable path reports the SYMLINK when invoked through PATH. Deriving
    /// the root from the unresolved path staged updates into /usr/local
    /// ("You don't have permission to save .update-staging-… in 'local'").
    @Test("PATH symlink resolves to the real install root")
    func symlinkedInvocationResolvesRealRoot() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("installroot-\(UUID().uuidString)")
        let realBin = tmp.appendingPathComponent("home/.darkbloom/bin")
        let fakeUsrLocalBin = tmp.appendingPathComponent("usr/local/bin")
        try fm.createDirectory(at: realBin, withIntermediateDirectories: true)
        try fm.createDirectory(at: fakeUsrLocalBin, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let realExec = realBin.appendingPathComponent("darkbloom")
        #expect(fm.createFile(atPath: realExec.path, contents: Data("x".utf8)))
        let link = fakeUsrLocalBin.appendingPathComponent("darkbloom")
        try fm.createSymbolicLink(at: link, withDestinationURL: realExec)

        let root = SelfUpdater.installRoot(forExecutablePath: link.path)

        #expect(root.path.hasSuffix("/.darkbloom"))
        #expect(!root.path.contains("usr/local"))
    }
}
