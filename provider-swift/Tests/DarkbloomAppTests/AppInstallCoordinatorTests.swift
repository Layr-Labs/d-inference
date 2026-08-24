import Foundation
import Testing
@testable import DarkbloomApp

@Suite("App install coordinator")
struct AppInstallCoordinatorTests {
    private let shippingBundleIdentifier =
        AppInstallCoordinator.productionBundleIdentifier // pragma: allowlist secret

    @Test("managed installer path continues and creates the user shortcut")
    func managedInstallerPathIsValid() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeApp(
            at: fixture.destination,
            identifier: AppInstallCoordinator.productionBundleIdentifier
        )
        let executor = RecordingExecutor()

        let result = try fixture.coordinator(source: source, executor: executor).coordinate()

        #expect(result == .continueLaunch)
        #expect(executor.invocations.isEmpty)
        try fixture.expectValidShortcut()
    }

    @Test("resolved user shortcut reaches the managed app without a relocation loop")
    func resolvedShortcutIsValid() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.makeApp(
            at: fixture.destination,
            identifier: AppInstallCoordinator.productionBundleIdentifier
        )
        try fixture.makeShortcut(to: fixture.destination)
        let executor = RecordingExecutor()

        let result = try fixture.coordinator(
            source: fixture.shortcut,
            executor: executor
        ).coordinate()

        #expect(result == .continueLaunch)
        #expect(executor.invocations.isEmpty)
        try fixture.expectValidShortcut()
    }

    @Test("downloaded production app authenticates source and stage before managed relocation")
    func downloadsRelocatesAndRelaunches() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.home.appendingPathComponent("Downloads/Darkbloom.app")
        try fixture.makeApp(
            at: source,
            identifier: shippingBundleIdentifier,
            payload: "downloaded"
        )
        let executor = RecordingExecutor()

        let result = try fixture.coordinator(source: source, executor: executor).coordinate()

        #expect(result == .relocated(to: fixture.destination, preservedForeignApp: nil))
        #expect(try fixture.payload(at: fixture.destination) == "downloaded")
        #expect(FileManager.default.fileExists(atPath: source.path))
        try fixture.expectValidShortcut()

        #expect(executor.invocations.map(\.executable.path) == [
            "/usr/bin/codesign",
            "/usr/bin/ditto",
            "/usr/bin/codesign",
            "/usr/bin/open",
        ])
        #expect(executor.invocations[0].arguments == signatureArguments(for: source))
        let dittoArguments = executor.invocations[1].arguments
        #expect(Array(dittoArguments.prefix(3)) == [
            "--rsrc",
            "--extattr",
            source.path,
        ])
        #expect(dittoArguments.count == 4)
        let staged = URL(fileURLWithPath: dittoArguments[3])
        #expect(staged.lastPathComponent.hasPrefix(".Darkbloom.app.relocation-"))
        #expect(executor.invocations[2].arguments == signatureArguments(for: staged))
        #expect(executor.invocations[3].arguments == ["-n", fixture.destination.path])
    }

    @Test("system Applications app relocates to the managed destination")
    func systemApplicationsRelocates() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeApp(
            at: fixture.root.appendingPathComponent("Applications/Darkbloom.app"),
            identifier: shippingBundleIdentifier,
            payload: "system-applications"
        )
        let executor = RecordingExecutor()

        let result = try fixture.coordinator(source: source, executor: executor).coordinate()

        #expect(result == .relocated(to: fixture.destination, preservedForeignApp: nil))
        #expect(try fixture.payload(at: fixture.destination) == "system-applications")
        #expect(executor.didOpen(fixture.destination))
        try fixture.expectValidShortcut()
    }

    @Test("signed app in home Applications relocates and becomes the managed shortcut")
    func homeApplicationsAppRelocates() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeApp(
            at: fixture.shortcut,
            identifier: shippingBundleIdentifier,
            payload: "home-applications"
        )
        let executor = RecordingExecutor()

        let result = try fixture.coordinator(source: source, executor: executor).coordinate()

        #expect(result == .relocated(to: fixture.destination, preservedForeignApp: nil))
        #expect(try fixture.payload(at: fixture.destination) == "home-applications")
        try fixture.expectValidShortcut()
        let shortcutOwnershipChecks = executor.invocations.filter {
            $0.executable.path == "/usr/bin/codesign"
                && $0.arguments.last == fixture.shortcut.path
        }
        #expect(shortcutOwnershipChecks.count == 2)
        #expect(shortcutOwnershipChecks.allSatisfy {
            $0.arguments == signatureArguments(for: fixture.shortcut)
        })
    }

    @Test("foreign managed destination is preserved instead of overwritten")
    func foreignDestinationIsPreserved() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.makeApp(
            at: fixture.destination,
            identifier: "com.example.foreign",
            payload: "foreign"
        )
        let source = try fixture.makeApp(
            at: fixture.home.appendingPathComponent("Downloads/Darkbloom.app"),
            identifier: shippingBundleIdentifier,
            payload: "darkbloom"
        )
        let executor = RecordingExecutor()

        let result = try fixture.coordinator(source: source, executor: executor).coordinate()

        guard case .relocated(let destination, let preserved?) = result else {
            Issue.record("expected a relocation with a preserved foreign app")
            return
        }
        #expect(destination == fixture.destination)
        #expect(preserved.lastPathComponent.hasPrefix("Darkbloom.app.foreign-"))
        #expect(try fixture.payload(at: preserved) == "foreign")
        #expect(try fixture.payload(at: fixture.destination) == "darkbloom")
    }

    @Test("same-ID destination failing production signature policy is foreign")
    func adHocSameIdentifierDestinationIsPreserved() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.makeApp(
            at: fixture.destination,
            identifier: shippingBundleIdentifier,
            version: "1.0.0",
            payload: "ad-hoc"
        )
        let source = try fixture.makeApp(
            at: fixture.home.appendingPathComponent("Downloads/Darkbloom.app"),
            identifier: shippingBundleIdentifier,
            version: "2.0.0",
            payload: "production"
        )
        let executor = RecordingExecutor(
            rejectedCodeSignTargets: [fixture.destination.path]
        )

        let result = try fixture.coordinator(source: source, executor: executor).coordinate()

        guard case .relocated(_, let preserved?) = result else {
            Issue.record("expected the same-ID ad-hoc app to be preserved as foreign")
            return
        }
        #expect(preserved.lastPathComponent.hasPrefix("Darkbloom.app.foreign-"))
        #expect(try fixture.payload(at: preserved) == "ad-hoc")
        #expect(try fixture.payload(at: fixture.destination) == "production")
        let ownedCheck = executor.invocations.first {
            $0.executable.path == "/usr/bin/codesign"
                && $0.arguments.last == fixture.destination.path
        }
        #expect(ownedCheck?.arguments == signatureArguments(for: fixture.destination))
    }

    @Test("newer signed source atomically replaces an older owned destination")
    func newerSourceReplacesOwnedDestination() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.makeApp(
            at: fixture.destination,
            identifier: shippingBundleIdentifier,
            version: "1.0.0",
            payload: "old"
        )
        let source = try fixture.makeApp(
            at: fixture.home.appendingPathComponent("Downloads/Darkbloom.app"),
            identifier: shippingBundleIdentifier,
            version: "2.0.0",
            payload: "new"
        )
        let executor = RecordingExecutor()

        let result = try fixture.coordinator(source: source, executor: executor).coordinate()

        #expect(result == .relocated(to: fixture.destination, preservedForeignApp: nil))
        #expect(try fixture.payload(at: fixture.destination) == "new")
        let ownedCheck = executor.invocations.first {
            $0.executable.path == "/usr/bin/codesign"
                && $0.arguments.last == fixture.destination.path
        }
        #expect(ownedCheck?.arguments == signatureArguments(for: fixture.destination))
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: fixture.destination.deletingLastPathComponent().path
        )
        #expect(!entries.contains { $0.hasPrefix(".Darkbloom.app.previous-") })
        #expect(!entries.contains { $0.hasPrefix(".Darkbloom.app.relocation-") })
    }

    @Test("equal signed source may repair an owned destination")
    func equalSourceReplacesOwnedDestination() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.makeApp(
            at: fixture.destination,
            identifier: shippingBundleIdentifier,
            version: "1.10.0",
            payload: "damaged-equal-version"
        )
        let source = try fixture.makeApp(
            at: fixture.home.appendingPathComponent("Downloads/Darkbloom.app"),
            identifier: shippingBundleIdentifier,
            version: "1.10.0",
            payload: "repaired-equal-version"
        )

        let result = try fixture.coordinator(
            source: source,
            executor: RecordingExecutor()
        ).coordinate()

        #expect(result == .relocated(to: fixture.destination, preservedForeignApp: nil))
        #expect(try fixture.payload(at: fixture.destination) == "repaired-equal-version")
    }

    @Test("older signed source is rejected before staging or destination mutation")
    func olderSourceCannotReplaceOwnedDestination() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.makeApp(
            at: fixture.destination,
            identifier: shippingBundleIdentifier,
            version: "1.10.0",
            payload: "newer-installed"
        )
        let source = try fixture.makeApp(
            at: fixture.home.appendingPathComponent("Downloads/Darkbloom.app"),
            identifier: shippingBundleIdentifier,
            version: "1.9.9",
            payload: "stale-download"
        )
        let executor = RecordingExecutor()

        do {
            _ = try fixture.coordinator(source: source, executor: executor).coordinate()
            Issue.record("expected a semantic-version downgrade rejection")
        } catch AppInstallCoordinatorError.downgradeRejected(
            let sourceVersion,
            let installedVersion
        ) {
            #expect(sourceVersion == "1.9.9")
            #expect(installedVersion == "1.10.0")
        }

        #expect(try fixture.payload(at: fixture.destination) == "newer-installed")
        #expect(try fixture.payload(at: source) == "stale-download")
        #expect(!FileManager.default.fileExists(atPath: fixture.shortcut.path))
        #expect(!executor.invocations.contains { $0.executable.path == "/usr/bin/ditto" })
        #expect(!executor.invocations.contains { $0.executable.path == "/usr/bin/open" })
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: fixture.destination.deletingLastPathComponent().path
        )
        #expect(!entries.contains { $0.hasPrefix(".Darkbloom.app.relocation-") })
        #expect(!entries.contains { $0.hasPrefix(".Darkbloom.app.previous-") })
    }

    @Test("explicit recovery override permits an older signed source")
    func recoveryOverridePermitsOlderSource() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.makeApp(
            at: fixture.destination,
            identifier: shippingBundleIdentifier,
            version: "2.0.0",
            payload: "newer-installed"
        )
        let source = try fixture.makeApp(
            at: fixture.home.appendingPathComponent("Downloads/Darkbloom.app"),
            identifier: shippingBundleIdentifier,
            version: "1.9.0",
            payload: "operator-selected-predecessor"
        )

        let result = try fixture.coordinator(
            source: source,
            executor: RecordingExecutor(),
            environment: [AppInstallCoordinator.allowDowngradeEnvironmentKey: "1"]
        ).coordinate()

        #expect(result == .relocated(to: fixture.destination, preservedForeignApp: nil))
        #expect(try fixture.payload(at: fixture.destination) == "operator-selected-predecessor")
    }

    @Test("recovery override refuses to strand newer SelfUpdater state")
    func recoveryOverrideRequiresArchivedUpdaterState() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.makeApp(
            at: fixture.destination,
            identifier: shippingBundleIdentifier,
            version: "2.0.0",
            payload: "newer-installed"
        )
        let source = try fixture.makeApp(
            at: fixture.home.appendingPathComponent("Downloads/Darkbloom.app"),
            identifier: shippingBundleIdentifier,
            version: "1.9.0",
            payload: "operator-selected-predecessor"
        )
        let stateURL = fixture.home
            .appendingPathComponent(".darkbloom/recovery/state.json")
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("newer-state".utf8).write(to: stateURL)
        let executor = RecordingExecutor()

        #expect(throws: AppInstallCoordinatorError.self) {
            try fixture.coordinator(
                source: source,
                executor: executor,
                environment: [AppInstallCoordinator.allowDowngradeEnvironmentKey: "1"]
            ).coordinate()
        }

        #expect(try fixture.payload(at: fixture.destination) == "newer-installed")
        #expect(try String(contentsOf: stateURL, encoding: .utf8) == "newer-state")
        #expect(!executor.invocations.contains { $0.executable.path == "/usr/bin/ditto" })
    }

    @Test("foreign user shortcut file is preserved exactly")
    func foreignShortcutFileIsPreserved() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.shortcut.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("foreign-file".utf8).write(to: fixture.shortcut)
        let source = try fixture.makeDownloadedApp()

        _ = try fixture.coordinator(source: source, executor: RecordingExecutor()).coordinate()

        #expect(try String(contentsOf: fixture.shortcut, encoding: .utf8) == "foreign-file")
        #expect(!fixture.isShortcutSymbolicLink)
    }

    @Test("foreign user shortcut app is preserved exactly")
    func foreignShortcutAppIsPreserved() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.makeApp(
            at: fixture.shortcut,
            identifier: "com.example.foreign",
            payload: "foreign-app"
        )
        let source = try fixture.makeDownloadedApp()

        _ = try fixture.coordinator(source: source, executor: RecordingExecutor()).coordinate()

        #expect(try fixture.payload(at: fixture.shortcut) == "foreign-app")
        #expect(!fixture.isShortcutSymbolicLink)
    }

    @Test("same-ID ad-hoc user shortcut app is preserved exactly")
    func adHocSameIdentifierShortcutIsPreserved() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.makeApp(
            at: fixture.shortcut,
            identifier: AppInstallCoordinator.productionBundleIdentifier,
            payload: "ad-hoc-shortcut"
        )
        let source = try fixture.makeDownloadedApp()
        let executor = RecordingExecutor(
            rejectedCodeSignTargets: [fixture.shortcut.path]
        )

        _ = try fixture.coordinator(source: source, executor: executor).coordinate()

        #expect(try fixture.payload(at: fixture.shortcut) == "ad-hoc-shortcut")
        #expect(!fixture.isShortcutSymbolicLink)
        let ownedCheck = executor.invocations.first {
            $0.executable.path == "/usr/bin/codesign"
                && $0.arguments.last == fixture.shortcut.path
        }
        #expect(ownedCheck?.arguments == signatureArguments(for: fixture.shortcut))
    }

    @Test("foreign user shortcut symlink and its target are preserved exactly")
    func foreignShortcutSymlinkIsPreserved() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let foreignTarget = fixture.root.appendingPathComponent("Foreign.app")
        try FileManager.default.createDirectory(
            at: foreignTarget,
            withIntermediateDirectories: true
        )
        try Data("outside".utf8).write(to: foreignTarget.appendingPathComponent("sentinel"))
        try fixture.makeShortcut(to: foreignTarget)
        let originalTarget = try FileManager.default.destinationOfSymbolicLink(
            atPath: fixture.shortcut.path
        )
        let source = try fixture.makeDownloadedApp()

        _ = try fixture.coordinator(source: source, executor: RecordingExecutor()).coordinate()

        #expect(fixture.isShortcutSymbolicLink)
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: fixture.shortcut.path
        ) == originalTarget)
        #expect(try String(
            contentsOf: foreignTarget.appendingPathComponent("sentinel"),
            encoding: .utf8
        ) == "outside")
    }

    @Test("source signature rejection happens before ditto")
    func sourceSignatureFailurePreventsCopy() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeDownloadedApp()
        let executor = RecordingExecutor(rejectedCodeSignTargets: [source.path])

        #expect(throws: AppInstallCoordinatorError.self) {
            try fixture.coordinator(source: source, executor: executor).coordinate()
        }

        #expect(executor.invocations.count == 1)
        #expect(executor.invocations[0].executable.path == "/usr/bin/codesign")
        #expect(executor.invocations[0].arguments == signatureArguments(for: source))
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @Test("staged signature rejection cleans staging and never launches")
    func stagedSignatureFailureCleansStaging() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeDownloadedApp()
        let executor = RecordingExecutor(rejectStagedSignature: true)

        #expect(throws: AppInstallCoordinatorError.self) {
            try fixture.coordinator(source: source, executor: executor).coordinate()
        }

        #expect(executor.invocations.map(\.executable.path) == [
            "/usr/bin/codesign",
            "/usr/bin/ditto",
            "/usr/bin/codesign",
        ])
        let staged = URL(fileURLWithPath: executor.invocations[1].arguments[3])
        #expect(executor.invocations[2].arguments == signatureArguments(for: staged))
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: fixture.destination.deletingLastPathComponent().path
        )
        #expect(!entries.contains { $0.hasPrefix(".Darkbloom.app.relocation-") })
        #expect(!executor.invocations.contains { $0.executable.path == "/usr/bin/open" })
    }

    @Test("debug app bundle never relocates")
    func debugBundleDoesNotRelocate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeApp(
            at: fixture.home.appendingPathComponent("Downloads/Darkbloom.app"),
            identifier: "dev.darkbloom.app"
        )
        let executor = RecordingExecutor()

        let result = try fixture.coordinator(
            source: source,
            identifier: "dev.darkbloom.app",
            executor: executor
        ).coordinate()

        #expect(result == .continueLaunch)
        #expect(executor.invocations.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @Test("real ad-hoc same-ID app is rejected by production policy")
    func realAdHocAppIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeDownloadedApp()
        let executable = source.appendingPathComponent("Contents/MacOS/DarkbloomApp")
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: executable
        )
        try runTestProcess(
            "/usr/bin/codesign",
            ["--force", "--deep", "--sign", "-", source.path]
        )
        let executor = RealVerificationExecutor()
        let coordinator = AppInstallCoordinator(
            homeDirectory: fixture.home,
            sourceBundleURL: source,
            sourceBundleIdentifier: AppInstallCoordinator.productionBundleIdentifier,
            environment: [:],
            fileManager: .default,
            executor: executor
        )

        #expect(throws: AppInstallCoordinatorError.self) {
            try coordinator.coordinate()
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(executor.openedURL == nil)
    }

    #if DEBUG
    @Test("relocation skip seam is available only to debug builds")
    func debugSkipEnvironmentSeam() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeDownloadedApp()
        let executor = RecordingExecutor()
        let coordinator = fixture.coordinator(
            source: source,
            executor: executor,
            environment: [AppInstallCoordinator.skipRelocationEnvironmentKey: "1"]
        )

        #expect(try coordinator.coordinate() == .continueLaunch)
        #expect(executor.invocations.isEmpty)
    }
    #endif

    @Test("managed destination gives SelfUpdater only darkbloom bin and recovery roots")
    func destinationMatchesSelfUpdaterLayout() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeDownloadedApp()
        let coordinator = fixture.coordinator(source: source, executor: RecordingExecutor())
        let bundledCLI = coordinator.destinationURL
            .appendingPathComponent("Contents/MacOS/darkbloom")

        let derivedInstallRoot = bundledCLI
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let expectedRoot = fixture.home.appendingPathComponent(".darkbloom")
        let applicationsRoot = fixture.home.appendingPathComponent("Applications")

        #expect(coordinator.destinationURL == fixture.destination)
        #expect(derivedInstallRoot.standardizedFileURL.path
            == expectedRoot.standardizedFileURL.path)
        #expect(derivedInstallRoot.appendingPathComponent("bin").path
            == expectedRoot.appendingPathComponent("bin").path)
        #expect(derivedInstallRoot.appendingPathComponent("recovery").path
            == expectedRoot.appendingPathComponent("recovery").path)
        #expect(derivedInstallRoot.standardizedFileURL.path
            != applicationsRoot.standardizedFileURL.path)
        #expect(!derivedInstallRoot.path.contains("/Applications"))
    }
}

private func signatureArguments(for url: URL) -> [String] {
    [
        "--verify",
        "--strict",
        "--verbose=2",
        "--deep",
        "-R=\(AppInstallCoordinator.productionDesignatedRequirement)",
        url.path,
    ]
}

private final class RecordingExecutor: AppInstallCommandExecuting {
    struct Invocation: Equatable {
        let executable: URL
        let arguments: [String]
    }

    private(set) var invocations: [Invocation] = []
    private let rejectedCodeSignTargets: Set<String>
    private let rejectStagedSignature: Bool

    init(
        rejectedCodeSignTargets: Set<String> = [],
        rejectStagedSignature: Bool = false
    ) {
        self.rejectedCodeSignTargets = rejectedCodeSignTargets
        self.rejectStagedSignature = rejectStagedSignature
    }

    func run(_ executable: URL, arguments: [String]) throws {
        let invocation = Invocation(executable: executable, arguments: arguments)
        invocations.append(invocation)

        if executable.path == "/usr/bin/codesign",
           let target = arguments.last,
           rejectedCodeSignTargets.contains(target)
                || (rejectStagedSignature
                    && URL(fileURLWithPath: target).lastPathComponent
                        .hasPrefix(".Darkbloom.app.relocation-"))
        {
            throw AppInstallCoordinatorError.commandFailed(
                command: executable.path,
                status: 1
            )
        }
        if executable.path == "/usr/bin/ditto" {
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: arguments[arguments.count - 2]),
                to: URL(fileURLWithPath: arguments[arguments.count - 1])
            )
        }
    }

    func didOpen(_ url: URL) -> Bool {
        invocations.contains {
            $0.executable.path == "/usr/bin/open"
                && $0.arguments == ["-n", url.path]
        }
    }
}

private final class RealVerificationExecutor: AppInstallCommandExecuting {
    private let system = SystemAppInstallCommandExecutor()
    private(set) var openedURL: URL?

    func run(_ executable: URL, arguments: [String]) throws {
        if executable.path == "/usr/bin/open" {
            openedURL = arguments.last.map { URL(fileURLWithPath: $0) }
            return
        }
        try system.run(executable, arguments: arguments)
    }
}

private func runTestProcess(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw AppInstallCoordinatorError.commandFailed(
            command: executable,
            status: process.terminationStatus
        )
    }
}

private struct Fixture {
    let root: URL
    let home: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "app-install-coordinator-\(UUID().uuidString)",
            isDirectory: true
        )
        home = root.appendingPathComponent("Home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )
    }

    var destination: URL {
        home.appendingPathComponent(".darkbloom/Darkbloom.app", isDirectory: true)
    }

    var shortcut: URL {
        home.appendingPathComponent("Applications/Darkbloom.app", isDirectory: true)
    }

    var isShortcutSymbolicLink: Bool {
        guard let type = try? FileManager.default.attributesOfItem(
            atPath: shortcut.path
        )[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeSymbolicLink
    }

    func coordinator(
        source: URL,
        identifier: String? = AppInstallCoordinator.productionBundleIdentifier,
        executor: RecordingExecutor,
        environment: [String: String] = [:]
    ) -> AppInstallCoordinator {
        AppInstallCoordinator(
            homeDirectory: home,
            sourceBundleURL: source,
            sourceBundleIdentifier: identifier,
            environment: environment,
            fileManager: .default,
            executor: executor,
            makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! }
        )
    }

    @discardableResult
    func makeDownloadedApp(payload: String = "downloaded") throws -> URL {
        try makeApp(
            at: home.appendingPathComponent("Downloads/Darkbloom.app"),
            identifier: AppInstallCoordinator.productionBundleIdentifier,
            payload: payload
        )
    }

    @discardableResult
    func makeApp(
        at appURL: URL,
        identifier: String,
        version: String = "1.2.3",
        payload: String = "app"
    ) throws -> URL {
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(
            at: macOS,
            withIntermediateDirectories: true
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleExecutable": "DarkbloomApp",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version,
            "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        ).write(to: contents.appendingPathComponent("Info.plist"))
        let executable = macOS.appendingPathComponent("DarkbloomApp")
        try Data(payload.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return appURL
    }

    func makeShortcut(to target: URL) throws {
        try FileManager.default.createDirectory(
            at: shortcut.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: shortcut.path,
            withDestinationPath: target.path
        )
    }

    func expectValidShortcut() throws {
        #expect(isShortcutSymbolicLink)
        #expect(shortcut.standardizedFileURL.resolvingSymlinksInPath()
            == destination.standardizedFileURL.resolvingSymlinksInPath())
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: shortcut.path)
            == destination.path)
    }

    func payload(at appURL: URL) throws -> String {
        try String(
            contentsOf: appURL.appendingPathComponent("Contents/MacOS/DarkbloomApp"),
            encoding: .utf8
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
