import Foundation
import Testing
@testable import DarkbloomApp
import ProviderCoreFoundation

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

    @Test("flat bin is migrated to the canonical app-relative links")
    func flatBinMigratesToCanonicalLinks() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeFlatBin()
        let source = try fixture.makeDownloadedApp(payload: "app-layout")

        let result = try fixture.coordinator(
            source: source,
            executor: RecordingExecutor()
        ).coordinate()

        #expect(result == .relocated(to: fixture.destination, preservedForeignApp: nil))
        #expect(try fixture.payload(at: fixture.destination) == "app-layout")
        try fixture.expectCanonicalBin()
        try fixture.expectNoRelocationTransactionArtifacts()
    }

    @Test("bin migration preserves every unmanaged entry")
    func unmanagedBinEntriesArePreserved() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeFlatBin()
        let customTool = fixture.bin.appendingPathComponent("custom-tool")
        try Data("user-tool".utf8).write(to: customTool)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o751],
            ofItemAtPath: customTool.path
        )
        let nested = fixture.bin.appendingPathComponent(
            "plugins/config.json"
        )
        try FileManager.default.createDirectory(
            at: nested.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"user":true}"#.utf8).write(to: nested)
        let userLink = fixture.bin.appendingPathComponent("current-config")
        try FileManager.default.createSymbolicLink(
            atPath: userLink.path,
            withDestinationPath: "plugins/config.json"
        )
        let source = try fixture.makeDownloadedApp()

        _ = try fixture.coordinator(
            source: source,
            executor: RecordingExecutor()
        ).coordinate()

        try fixture.expectCanonicalBin()
        #expect(try String(contentsOf: customTool, encoding: .utf8) == "user-tool")
        #expect(
            try FileManager.default.attributesOfItem(atPath: customTool.path)[
                .posixPermissions
            ] as? NSNumber == NSNumber(value: 0o751)
        )
        #expect(try String(contentsOf: nested, encoding: .utf8) == #"{"user":true}"#)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: userLink.path
            ) == "plugins/config.json"
        )
        try fixture.expectNoRelocationTransactionArtifacts()
    }

    @Test("symlink and file bin paths are rejected without mutation")
    func unsafeBinRootsArePreserved() throws {
        for kind in ["symlink", "file"] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try FileManager.default.createDirectory(
                at: fixture.installRoot,
                withIntermediateDirectories: true
            )
            let outside = fixture.root.appendingPathComponent(
                "outside-\(kind)",
                isDirectory: true
            )
            if kind == "symlink" {
                try FileManager.default.createDirectory(
                    at: outside,
                    withIntermediateDirectories: true
                )
                try Data("outside-user-data".utf8).write(
                    to: outside.appendingPathComponent("sentinel")
                )
                try FileManager.default.createSymbolicLink(
                    atPath: fixture.bin.path,
                    withDestinationPath: outside.path
                )
            } else {
                try Data("user-owned-bin-file".utf8).write(to: fixture.bin)
            }
            let source = try fixture.makeDownloadedApp()

            #expect(throws: AppInstallCoordinatorError.self) {
                try fixture.coordinator(
                    source: source,
                    executor: RecordingExecutor()
                ).coordinate()
            }

            #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
            if kind == "symlink" {
                #expect(
                    try FileManager.default.destinationOfSymbolicLink(
                        atPath: fixture.bin.path
                    ) == outside.path
                )
                #expect(
                    try String(
                        contentsOf: outside.appendingPathComponent("sentinel"),
                        encoding: .utf8
                    ) == "outside-user-data"
                )
            } else {
                #expect(
                    try String(contentsOf: fixture.bin, encoding: .utf8)
                        == "user-owned-bin-file"
                )
            }
            try fixture.expectNoRelocationTransactionArtifacts()
        }
    }

    @Test("required app payload files are verified before publication")
    func incompleteAppPayloadIsRejected() throws {
        for name in ["darkbloom", "darkbloom-enclave", "mlx.metallib"] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let source = try fixture.makeDownloadedApp()
            try FileManager.default.removeItem(
                at: source.appendingPathComponent("Contents/MacOS/\(name)")
            )

            #expect(throws: AppInstallCoordinatorError.self) {
                try fixture.coordinator(
                    source: source,
                    executor: RecordingExecutor()
                ).coordinate()
            }

            #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
            #expect(!FileManager.default.fileExists(atPath: fixture.bin.path))
            try fixture.expectNoRelocationTransactionArtifacts()
        }
    }

    @Test("open failure after commit restricts the source app to managed recovery")
    func relaunchFailureDoesNotInvalidateCommit() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeFlatBin()
        let source = try fixture.makeDownloadedApp(payload: "committed")
        let executor = RecordingExecutor(failOpen: true)

        let result = try fixture.coordinator(
            source: source,
            executor: executor
        ).coordinate()

        #expect(
            result == .relaunchRequired(
                at: fixture.destination,
                preservedForeignApp: nil
            )
        )
        #expect(try fixture.payload(at: fixture.destination) == "committed")
        #expect(try fixture.payload(at: source) == "committed")
        #expect(executor.didOpen(fixture.destination))
        try fixture.expectCanonicalBin()
        try fixture.expectManagedRuntimePaths(source: source)
        try fixture.expectNoRelocationTransactionArtifacts()
    }

    @Test("shortcut failure cannot invalidate a committed installation")
    func shortcutFailureIsBestEffort() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeDownloadedApp(payload: "committed")
        let applications = fixture.home.appendingPathComponent("Applications")
        try Data("user-owned-file".utf8).write(to: applications)
        let executor = RecordingExecutor()

        let result = try fixture.coordinator(source: source, executor: executor).coordinate()

        #expect(result == .relocated(to: fixture.destination, preservedForeignApp: nil))
        #expect(try fixture.payload(at: fixture.destination) == "committed")
        #expect(try String(contentsOf: applications, encoding: .utf8) == "user-owned-file")
        #expect(executor.didOpen(fixture.destination))
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

    @Test("relocation refuses a pending SelfUpdater transaction")
    func pendingSelfUpdateMustRecoverFirst() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeDownloadedApp(payload: "candidate")
        let transaction = fixture.destination.deletingLastPathComponent()
            .appendingPathComponent("recovery/transaction.json")
        try FileManager.default.createDirectory(
            at: transaction.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: transaction)

        #expect(throws: AppInstallCoordinatorError.self) {
            try fixture.coordinator(
                source: source,
                executor: RecordingExecutor()
            ).coordinate()
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(try String(contentsOf: transaction, encoding: .utf8) == "{}")
    }

    @Test("relocation refuses a committed SelfUpdater candidate")
    func pendingSelfUpdateCandidateMustResolveFirst() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeDownloadedApp(payload: "one-shot")
        let state = InstallMutationLock.selfUpdateStateURL(
            in: fixture.installRoot
        )
        try FileManager.default.createDirectory(
            at: state.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let stateData = Data(
            #"{"schema":1,"candidate":{"release":{"version":"2.0.0"}}}"#.utf8
        )
        try stateData.write(to: state)

        #expect(throws: AppInstallCoordinatorError.self) {
            try fixture.coordinator(
                source: source,
                executor: RecordingExecutor()
            ).coordinate()
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(try Data(contentsOf: state) == stateData)
    }

    @Test("relocation refuses a pending shell installer transaction")
    func pendingShellInstallMustRecoverFirst() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeDownloadedApp(payload: "candidate")
        let transaction = fixture.destination.deletingLastPathComponent()
            .appendingPathComponent(".install-backup-123-456-789")
        try FileManager.default.createDirectory(
            at: transaction,
            withIntermediateDirectories: true
        )

        #expect(throws: AppInstallCoordinatorError.self) {
            try fixture.coordinator(
                source: source,
                executor: RecordingExecutor()
            ).coordinate()
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(FileManager.default.fileExists(atPath: transaction.path))
    }

    @Test("fresh relocation recovers every durable fault boundary")
    func freshRelocationFaultBoundaries() throws {
        let points: [AppRelocationTransaction.FaultPoint] = [
            .journalPersisted,
            .appLiveStateMutated,
            .appLiveStateRecorded,
            .binLiveStateMutated,
            .binLiveStateRecorded,
            .appPreviousStateRecorded,
            .binPreviousStateMoved,
            .binPreviousStateRecorded,
            .appPreviousRetirementRecorded,
            .binPreviousRetired,
            .binPreviousRetirementRecorded,
            .appRemovalAuthorized,
            .appPreviousRemoved,
            .appRemovalRecorded,
            .binRemovalAuthorized,
            .binPreviousRemoved,
            .binRemovalRecorded,
            .journalRemoved,
        ]
        for point in points {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try fixture.makeFlatBin()
            let source = try fixture.makeDownloadedApp(
                payload: "fresh-\(point.rawValue)"
            )

            #expect(throws: AppInstallCoordinatorError.self) {
                try fixture.coordinator(
                    source: source,
                    executor: RecordingExecutor(),
                    relocationFaultInjector: failOnce(at: point)
                ).coordinate()
            }

            let result = try fixture.coordinator(
                source: source,
                executor: RecordingExecutor()
            ).coordinate()
            #expect(
                result == .relocated(
                    to: fixture.destination,
                    preservedForeignApp: nil
                )
            )
            #expect(
                try fixture.payload(at: fixture.destination)
                    == "fresh-\(point.rawValue)"
            )
            try fixture.expectCanonicalBin()
            try fixture.expectNoRelocationTransactionArtifacts()
        }
    }

    @Test("owned relocation recovers every durable fault boundary")
    func ownedRelocationFaultBoundaries() throws {
        let points: [AppRelocationTransaction.FaultPoint] = [
            .journalPersisted,
            .appLiveStateMutated,
            .appLiveStateRecorded,
            .binLiveStateMutated,
            .binLiveStateRecorded,
            .appPreviousStateMoved,
            .appPreviousStateRecorded,
            .binPreviousStateMoved,
            .binPreviousStateRecorded,
            .ownedAppPreviousRetired,
            .appPreviousRetirementRecorded,
            .binPreviousRetired,
            .binPreviousRetirementRecorded,
            .appRemovalAuthorized,
            .appPreviousRemoved,
            .appRemovalRecorded,
            .binRemovalAuthorized,
            .binPreviousRemoved,
            .binRemovalRecorded,
            .journalRemoved,
        ]
        for point in points {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try fixture.makeFlatBin()
            _ = try fixture.makeApp(
                at: fixture.destination,
                identifier: shippingBundleIdentifier,
                version: "1.0.0",
                payload: "owned-predecessor"
            )
            let source = try fixture.makeApp(
                at: fixture.home.appendingPathComponent(
                    "Downloads/Darkbloom.app"
                ),
                identifier: shippingBundleIdentifier,
                version: "2.0.0",
                payload: "owned-\(point.rawValue)"
            )

            #expect(throws: AppInstallCoordinatorError.self) {
                try fixture.coordinator(
                    source: source,
                    executor: RecordingExecutor(),
                    relocationFaultInjector: failOnce(at: point)
                ).coordinate()
            }

            _ = try fixture.coordinator(
                source: source,
                executor: RecordingExecutor()
            ).coordinate()
            #expect(
                try fixture.payload(at: fixture.destination)
                    == "owned-\(point.rawValue)"
            )
            try fixture.expectCanonicalBin()
            try fixture.expectNoRelocationTransactionArtifacts()
        }
    }

    @Test("foreign relocation preserves exactly one app at every fault boundary")
    func foreignRelocationFaultBoundaries() throws {
        let points: [AppRelocationTransaction.FaultPoint] = [
            .journalPersisted,
            .appLiveStateMutated,
            .appLiveStateRecorded,
            .binLiveStateMutated,
            .binLiveStateRecorded,
            .appPreviousStateMoved,
            .appPreviousStateRecorded,
            .binPreviousStateMoved,
            .binPreviousStateRecorded,
            .appPreviousRetirementRecorded,
            .binPreviousRetired,
            .binPreviousRetirementRecorded,
            .appRemovalAuthorized,
            .appPreviousRemoved,
            .appRemovalRecorded,
            .binRemovalAuthorized,
            .binPreviousRemoved,
            .binRemovalRecorded,
            .journalRemoved,
        ]
        for point in points {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try fixture.makeFlatBin()
            _ = try fixture.makeApp(
                at: fixture.destination,
                identifier: "com.example.foreign",
                payload: "foreign-\(point.rawValue)"
            )
            let source = try fixture.makeDownloadedApp(
                payload: "candidate-\(point.rawValue)"
            )

            #expect(throws: AppInstallCoordinatorError.self) {
                try fixture.coordinator(
                    source: source,
                    executor: RecordingExecutor(),
                    relocationFaultInjector: failOnce(at: point)
                ).coordinate()
            }

            _ = try fixture.coordinator(
                source: source,
                executor: RecordingExecutor()
            ).coordinate()
            #expect(
                try fixture.payload(at: fixture.destination)
                    == "candidate-\(point.rawValue)"
            )
            let preserved = try fixture.foreignAppURLs()
            #expect(preserved.count == 1)
            if let preservedApp = preserved.first {
                #expect(
                    try fixture.payload(at: preservedApp)
                        == "foreign-\(point.rawValue)"
                )
            }
            try fixture.expectCanonicalBin()
            try fixture.expectNoRelocationTransactionArtifacts()
        }
    }

    @Test("fresh, owned, and foreign recovery tolerate repeated process deaths")
    func repeatedRecoveryIsIdempotent() throws {
        for destinationKind in ["fresh", "owned", "foreign"] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try fixture.makeFlatBin()
            if destinationKind == "owned" {
                _ = try fixture.makeApp(
                    at: fixture.destination,
                    identifier: shippingBundleIdentifier,
                    version: "1.0.0",
                    payload: "owned-original"
                )
            } else if destinationKind == "foreign" {
                _ = try fixture.makeApp(
                    at: fixture.destination,
                    identifier: "com.example.foreign",
                    payload: "foreign-original"
                )
            }
            let source = try fixture.makeApp(
                at: fixture.home.appendingPathComponent(
                    "Downloads/Darkbloom.app"
                ),
                identifier: shippingBundleIdentifier,
                version: "2.0.0",
                payload: "candidate-\(destinationKind)"
            )
            var interruptions: [AppRelocationTransaction.FaultPoint] = [
                .appLiveStateMutated,
                .appLiveStateRecorded,
                .binLiveStateMutated,
                .binLiveStateRecorded,
            ]
            if destinationKind != "fresh" {
                interruptions.append(.appPreviousStateMoved)
            }
            interruptions += [
                .appPreviousStateRecorded,
                .binPreviousStateMoved,
                .binPreviousStateRecorded,
            ]
            if destinationKind == "owned" {
                interruptions.append(.ownedAppPreviousRetired)
            }
            interruptions += [
                .appPreviousRetirementRecorded,
                .binPreviousRetired,
                .binPreviousRetirementRecorded,
                .appRemovalAuthorized,
                .appPreviousRemoved,
                .appRemovalRecorded,
                .binRemovalAuthorized,
                .binPreviousRemoved,
                .binRemovalRecorded,
            ]

            for point in interruptions {
                #expect(throws: AppInstallCoordinatorError.self) {
                    try fixture.coordinator(
                        source: source,
                        executor: RecordingExecutor(),
                        relocationFaultInjector: failOnce(at: point)
                    ).coordinate()
                }
            }

            _ = try fixture.coordinator(
                source: source,
                executor: RecordingExecutor()
            ).coordinate()
            #expect(
                try fixture.payload(at: fixture.destination)
                    == "candidate-\(destinationKind)"
            )
            let preserved = try fixture.foreignAppURLs()
            #expect(preserved.count == (destinationKind == "foreign" ? 1 : 0))
            if let preservedApp = preserved.first {
                #expect(
                    try fixture.payload(at: preservedApp) == "foreign-original"
                )
            }
            try fixture.expectCanonicalBin()
            try fixture.expectNoRelocationTransactionArtifacts()
        }
    }

    @Test("managed app startup completes an interrupted exchange and hands off")
    func managedAppRecoversInterruptedExchange() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.makeApp(
            at: fixture.destination,
            identifier: shippingBundleIdentifier,
            version: "1.0.0",
            payload: "owned-predecessor"
        )
        let source = try fixture.makeApp(
            at: fixture.home.appendingPathComponent(
                "Downloads/Darkbloom.app"
            ),
            identifier: shippingBundleIdentifier,
            version: "2.0.0",
            payload: "candidate"
        )

        #expect(throws: AppInstallCoordinatorError.self) {
            try fixture.coordinator(
                source: source,
                executor: RecordingExecutor(),
                relocationFaultInjector: failOnce(at: .appLiveStateMutated)
            ).coordinate()
        }

        let executor = RecordingExecutor()
        let result = try fixture.coordinator(
            source: fixture.destination,
            executor: executor
        ).coordinate()
        #expect(
            result == .relocated(
                to: fixture.destination,
                preservedForeignApp: nil
            )
        )
        #expect(try fixture.payload(at: fixture.destination) == "candidate")
        #expect(executor.didOpen(fixture.destination))
        try fixture.expectNoRelocationTransactionArtifacts()
    }

    @Test("open failure after managed-path recovery exposes only managed recovery")
    func recoveredCommitRelaunchFailureRequiresManagedRecovery() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeFlatBin()
        _ = try fixture.makeApp(
            at: fixture.destination,
            identifier: shippingBundleIdentifier,
            version: "1.0.0",
            payload: "owned-predecessor"
        )
        let source = try fixture.makeApp(
            at: fixture.home.appendingPathComponent(
                "Downloads/Darkbloom.app"
            ),
            identifier: shippingBundleIdentifier,
            version: "2.0.0",
            payload: "candidate"
        )
        #expect(throws: AppInstallCoordinatorError.self) {
            try fixture.coordinator(
                source: source,
                executor: RecordingExecutor(),
                relocationFaultInjector: failOnce(at: .appLiveStateMutated)
            ).coordinate()
        }
        let executor = RecordingExecutor(failOpen: true)

        let result = try fixture.coordinator(
            source: fixture.destination,
            executor: executor
        ).coordinate()

        #expect(
            result == .relaunchRequired(
                at: fixture.destination,
                preservedForeignApp: nil
            )
        )
        #expect(try fixture.payload(at: fixture.destination) == "candidate")
        #expect(executor.didOpen(fixture.destination))
        try fixture.expectCanonicalBin()
        try fixture.expectManagedRuntimePaths(source: source)
        try fixture.expectNoRelocationTransactionArtifacts()
    }

    @Test("recovery refuses a destination that appeared after journal publication")
    func ambiguousFreshRecoveryIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeDownloadedApp(payload: "candidate")

        #expect(throws: AppInstallCoordinatorError.self) {
            try fixture.coordinator(
                source: source,
                executor: RecordingExecutor(),
                relocationFaultInjector: failOnce(at: .journalPersisted)
            ).coordinate()
        }
        _ = try fixture.makeApp(
            at: fixture.destination,
            identifier: "com.example.appeared",
            payload: "appeared-after-crash"
        )

        #expect(throws: AppInstallCoordinatorError.self) {
            try fixture.coordinator(
                source: source,
                executor: RecordingExecutor()
            ).coordinate()
        }
        #expect(
            try fixture.payload(at: fixture.destination)
                == "appeared-after-crash"
        )
        #expect(FileManager.default.fileExists(
            atPath: fixture.relocationJournal.path
        ))
    }

    @Test("app and bin candidate or predecessor tampering fails closed")
    func recoveryVerifiesAllRecordedContentHashes() throws {
        for target in [
            "app-candidate",
            "app-predecessor",
            "bin-candidate",
            "bin-predecessor",
        ] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try fixture.makeFlatBin()
            _ = try fixture.makeApp(
                at: fixture.destination,
                identifier: shippingBundleIdentifier,
                version: "1.0.0",
                payload: "owned-predecessor"
            )
            let source = try fixture.makeApp(
                at: fixture.home.appendingPathComponent(
                    "Downloads/Darkbloom.app"
                ),
                identifier: shippingBundleIdentifier,
                version: "2.0.0",
                payload: "candidate"
            )

            #expect(throws: AppInstallCoordinatorError.self) {
                try fixture.coordinator(
                    source: source,
                    executor: RecordingExecutor(),
                    relocationFaultInjector: failOnce(at: .journalPersisted)
                ).coordinate()
            }
            let changedPath: URL
            switch target {
            case "app-candidate":
                changedPath = fixture.relocationStaging.appendingPathComponent(
                    "Contents/MacOS/DarkbloomApp"
                )
            case "app-predecessor":
                changedPath = fixture.destination.appendingPathComponent(
                    "Contents/MacOS/DarkbloomApp"
                )
            case "bin-candidate":
                changedPath = fixture.binRelocationStaging
                    .appendingPathComponent("unmanaged-tamper")
            default:
                changedPath = fixture.bin.appendingPathComponent("darkbloom")
            }
            try Data("changed-after-journal".utf8).write(to: changedPath)

            #expect(throws: AppInstallCoordinatorError.self) {
                try fixture.coordinator(
                    source: source,
                    executor: RecordingExecutor()
                ).coordinate()
            }
            #expect(FileManager.default.fileExists(
                atPath: fixture.relocationJournal.path
            ))
            #expect(
                try String(contentsOf: changedPath, encoding: .utf8)
                    == "changed-after-journal"
            )
        }
    }

    @Test("authorized cleanup refuses replacement app and bin garbage paths")
    func cleanupAuthorizationIsBoundToRecordedInodes() throws {
        let cases: [(name: String, point: AppRelocationTransaction.FaultPoint)] = [
            ("app", .appRemovalAuthorized),
            ("bin", .binRemovalAuthorized),
        ]
        for item in cases {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try fixture.makeFlatBin()
            _ = try fixture.makeApp(
                at: fixture.destination,
                identifier: shippingBundleIdentifier,
                version: "1.0.0",
                payload: "owned-predecessor"
            )
            let source = try fixture.makeApp(
                at: fixture.home.appendingPathComponent(
                    "Downloads/Darkbloom.app"
                ),
                identifier: shippingBundleIdentifier,
                version: "2.0.0",
                payload: "candidate"
            )

            #expect(throws: AppInstallCoordinatorError.self) {
                try fixture.coordinator(
                    source: source,
                    executor: RecordingExecutor(),
                    relocationFaultInjector: failOnce(at: item.point)
                ).coordinate()
            }

            let garbage = item.name == "app"
                ? fixture.appRelocationGarbage
                : fixture.binRelocationGarbage
            try FileManager.default.removeItem(at: garbage)
            try Data("user-replacement".utf8).write(to: garbage)

            #expect(throws: AppInstallCoordinatorError.self) {
                try fixture.coordinator(
                    source: source,
                    executor: RecordingExecutor()
                ).coordinate()
            }
            #expect(
                try String(contentsOf: garbage, encoding: .utf8)
                    == "user-replacement"
            )
            #expect(FileManager.default.fileExists(
                atPath: fixture.relocationJournal.path
            ))
        }
    }

    @Test("corrupt fixed journal is preserved and recovery fails closed")
    func corruptJournalIsNeverGuessedOrDeleted() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeFlatBin()
        let source = try fixture.makeDownloadedApp(payload: "candidate")

        #expect(throws: AppInstallCoordinatorError.self) {
            try fixture.coordinator(
                source: source,
                executor: RecordingExecutor(),
                relocationFaultInjector: failOnce(at: .journalPersisted)
            ).coordinate()
        }
        let corrupt = Data(#"{"schema":2,"phase":"prepared"}"#.utf8)
        try corrupt.write(to: fixture.relocationJournal)

        #expect(throws: AppInstallCoordinatorError.self) {
            try fixture.coordinator(
                source: source,
                executor: RecordingExecutor()
            ).coordinate()
        }

        #expect(try Data(contentsOf: fixture.relocationJournal) == corrupt)
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(FileManager.default.fileExists(
            atPath: fixture.relocationStaging.path
        ))
        #expect(FileManager.default.fileExists(
            atPath: fixture.binRelocationStaging.path
        ))
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
        let macOS = source.appendingPathComponent("Contents/MacOS")
        for name in ["DarkbloomApp", "darkbloom", "darkbloom-enclave"] {
            let executable = macOS.appendingPathComponent(name)
            try FileManager.default.removeItem(at: executable)
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: "/usr/bin/true"),
                to: executable
            )
        }
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

private struct InjectedRelocationFault: Error {}

private func failOnce(
    at target: AppRelocationTransaction.FaultPoint
) -> (AppRelocationTransaction.FaultPoint) throws -> Void {
    var hasFailed = false
    return { point in
        guard point == target, !hasFailed else { return }
        hasFailed = true
        throw InjectedRelocationFault()
    }
}

private final class RecordingExecutor: AppInstallCommandExecuting {
    struct Invocation: Equatable {
        let executable: URL
        let arguments: [String]
    }

    private(set) var invocations: [Invocation] = []
    private let rejectedCodeSignTargets: Set<String>
    private let rejectStagedSignature: Bool
    private let failOpen: Bool

    init(
        rejectedCodeSignTargets: Set<String> = [],
        rejectStagedSignature: Bool = false,
        failOpen: Bool = false
    ) {
        self.rejectedCodeSignTargets = rejectedCodeSignTargets
        self.rejectStagedSignature = rejectStagedSignature
        self.failOpen = failOpen
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
        if executable.path == "/usr/bin/open", failOpen {
            throw AppInstallCoordinatorError.commandFailed(
                command: executable.path,
                status: 1
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

    var installRoot: URL {
        destination.deletingLastPathComponent()
    }

    var bin: URL {
        installRoot.appendingPathComponent("bin", isDirectory: true)
    }

    var relocationJournal: URL {
        installRoot.appendingPathComponent(
            ".app-relocation-transaction.json"
        )
    }

    var relocationStaging: URL {
        installRoot.appendingPathComponent(
            ".Darkbloom.app.relocation-00000000-0000-0000-0000-000000000001",
            isDirectory: true
        )
    }

    var binRelocationStaging: URL {
        installRoot.appendingPathComponent(
            ".bin.relocation-00000000-0000-0000-0000-000000000001",
            isDirectory: true
        )
    }

    var appRelocationGarbage: URL {
        installRoot.appendingPathComponent(
            ".Darkbloom.app.garbage-00000000-0000-0000-0000-000000000001",
            isDirectory: true
        )
    }

    var binRelocationGarbage: URL {
        installRoot.appendingPathComponent(
            ".bin.garbage-00000000-0000-0000-0000-000000000001",
            isDirectory: true
        )
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
        environment: [String: String] = [:],
        relocationFaultInjector:
            @escaping (AppRelocationTransaction.FaultPoint) throws -> Void = { _ in }
    ) -> AppInstallCoordinator {
        AppInstallCoordinator(
            homeDirectory: home,
            sourceBundleURL: source,
            sourceBundleIdentifier: identifier,
            environment: environment,
            fileManager: .default,
            executor: executor,
            makeUUID: {
                UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            },
            relocationFaultInjector: relocationFaultInjector
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
        let payloads: [(name: String, contents: String, executable: Bool)] = [
            ("DarkbloomApp", payload, true),
            ("darkbloom", "\(payload)-cli", true),
            ("darkbloom-enclave", "\(payload)-enclave", true),
            ("mlx.metallib", "\(payload)-metallib", false),
        ]
        for item in payloads {
            let destination = macOS.appendingPathComponent(item.name)
            try Data(item.contents.utf8).write(to: destination)
            if item.executable {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: destination.path
                )
            }
        }
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

    func makeFlatBin() throws {
        try FileManager.default.createDirectory(
            at: bin,
            withIntermediateDirectories: true
        )
        for name in ["darkbloom", "darkbloom-enclave", "mlx.metallib"] {
            let path = bin.appendingPathComponent(name)
            try Data("legacy-\(name)".utf8).write(to: path)
        }
        try FileManager.default.createSymbolicLink(
            atPath: bin.appendingPathComponent("eigeninference-enclave").path,
            withDestinationPath: "darkbloom-enclave"
        )
    }

    func expectCanonicalBin() throws {
        for link in AppRelocationBinLayout.canonicalLinks {
            let path = bin.appendingPathComponent(link.name)
            let attributes = try FileManager.default.attributesOfItem(
                atPath: path.path
            )
            #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
            #expect(
                try FileManager.default.destinationOfSymbolicLink(
                    atPath: path.path
                ) == link.target
            )
        }
    }

    func expectManagedRuntimePaths(source: URL) throws {
        let managedCLI = destination.appendingPathComponent(
            "Contents/MacOS/darkbloom"
        )
        let locator = SystemDarkbloomCLILocator(
            environment: [:],
            homeDirectory: home
        )
        #expect(locator.locate() == managedCLI)
        #expect(locator.locate() != source.appendingPathComponent(
            "Contents/MacOS/darkbloom"
        ))
        #expect(
            bin.appendingPathComponent("darkbloom")
                .resolvingSymlinksInPath()
                .standardizedFileURL
                == managedCLI.resolvingSymlinksInPath().standardizedFileURL
        )
    }

    func expectValidShortcut() throws {
        #expect(isShortcutSymbolicLink)
        #expect(shortcut.standardizedFileURL.resolvingSymlinksInPath()
            == destination.standardizedFileURL.resolvingSymlinksInPath())
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: shortcut.path)
            == destination.path)
    }

    func foreignAppURLs() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: installRoot,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("Darkbloom.app.foreign-")
        }
    }

    func expectNoRelocationTransactionArtifacts() throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: installRoot,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)
        #expect(!entries.contains(".app-relocation-transaction.json"))
        #expect(!entries.contains {
            $0.hasPrefix(".Darkbloom.app.relocation-")
                || $0.hasPrefix(".Darkbloom.app.previous-")
                || $0.hasPrefix(".Darkbloom.app.garbage-")
                || $0.hasPrefix(".bin.relocation-")
                || $0.hasPrefix(".bin.previous-")
                || $0.hasPrefix(".bin.garbage-")
                || $0.hasPrefix("..app-relocation-transaction.json.tmp-")
        })
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
