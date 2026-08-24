import Foundation

enum AppInstallOutcome: Equatable {
    case continueLaunch
    case relocated(to: URL, preservedForeignApp: URL?)
}

enum AppInstallCoordinatorError: Error, LocalizedError {
    case invalidBundle(path: String, reason: String)
    case destinationUnavailable(path: String, reason: String)
    case commandFailed(command: String, status: Int32)
    case copiedBundleMismatch(field: String, expected: String, actual: String)
    case copiedExecutableUnavailable(path: String)
    case downgradeRejected(sourceVersion: String, installedVersion: String)
    case downgradeRecoveryStatePresent(path: String)
    case installFailed(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidBundle(let path, let reason):
            "The downloaded Darkbloom app at \(path) is incomplete: \(reason)"
        case .destinationUnavailable(let path, let reason):
            "Darkbloom could not prepare \(path): \(reason)"
        case .commandFailed(let command, let status):
            "Darkbloom could not finish installation because \(command) exited with status \(status)."
        case .copiedBundleMismatch(let field, let expected, let actual):
            "The copied app failed verification for \(field) (expected \(expected), found \(actual))."
        case .copiedExecutableUnavailable(let path):
            "The copied app executable is missing or cannot be run at \(path)."
        case .downgradeRejected(let sourceVersion, let installedVersion):
            "Darkbloom \(sourceVersion) cannot replace the newer installed version "
                + "\(installedVersion)."
        case .downgradeRecoveryStatePresent(let path):
            "Darkbloom cannot perform the requested rollback while SelfUpdater state "
                + "still exists at \(path)."
        case .installFailed(let path, let reason):
            "Darkbloom could not atomically install the verified app at \(path): \(reason)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .downgradeRejected:
            "Open the installed Darkbloom app instead. For an intentional signed-release "
                + "rollback, follow the operator recovery procedure."
        case .downgradeRecoveryStatePresent:
            "Stop Darkbloom and archive its recovery directory before retrying the "
                + "documented signed-release rollback."
        default:
            "Check that ~/.darkbloom and your home Applications folder are writable, "
                + "then reopen the downloaded Darkbloom app. No administrator access is required."
        }
    }
}

protocol AppInstallCommandExecuting {
    func run(_ executable: URL, arguments: [String]) throws
}

struct SystemAppInstallCommandExecutor: AppInstallCommandExecuting {
    func run(_ executable: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw AppInstallCoordinatorError.commandFailed(
                command: executable.path,
                status: process.terminationStatus
            )
        }
    }
}

/// Moves a directly downloaded production app to a stable, writable location
/// before any onboarding or launchd work can begin.
struct AppInstallCoordinator {
    static let productionBundleIdentifier = "io.darkbloom.provider"
    static let productionDesignatedRequirement =
        "anchor apple generic and identifier \"\(productionBundleIdentifier)\" "
        + "and certificate leaf[subject.OU] = \"SLDQ2GJ6TL\""
    static let skipRelocationEnvironmentKey = "DARKBLOOM_SKIP_APP_RELOCATION"
    static let allowDowngradeEnvironmentKey = "DARKBLOOM_ALLOW_APP_DOWNGRADE"

    private static let dittoURL = URL(fileURLWithPath: "/usr/bin/ditto")
    private static let codesignURL = URL(fileURLWithPath: "/usr/bin/codesign")
    private static let openURL = URL(fileURLWithPath: "/usr/bin/open")

    private let homeDirectory: URL
    private let sourceBundleURL: URL
    private let sourceBundleIdentifier: String?
    private let environment: [String: String]
    private let fileManager: FileManager
    private let executor: any AppInstallCommandExecuting
    private let makeUUID: () -> UUID

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        executor: any AppInstallCommandExecuting = SystemAppInstallCommandExecutor(),
        makeUUID: @escaping () -> UUID = UUID.init
    ) {
        let source = Self.mainBundleSource()
        self.init(
            homeDirectory: homeDirectory,
            sourceBundleURL: source.url,
            sourceBundleIdentifier: source.identifier,
            environment: environment,
            fileManager: fileManager,
            executor: executor,
            makeUUID: makeUUID
        )
    }

    init(
        homeDirectory: URL,
        sourceBundleURL: URL,
        sourceBundleIdentifier: String?,
        environment: [String: String],
        fileManager: FileManager,
        executor: any AppInstallCommandExecuting,
        makeUUID: @escaping () -> UUID = UUID.init
    ) {
        self.homeDirectory = homeDirectory
        self.sourceBundleURL = sourceBundleURL
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.environment = environment
        self.fileManager = fileManager
        self.executor = executor
        self.makeUUID = makeUUID
    }

    var destinationURL: URL {
        // SelfUpdater derives bin/recovery paths from the app's parent.
        homeDirectory
            .appendingPathComponent(".darkbloom", isDirectory: true)
            .appendingPathComponent("Darkbloom.app", isDirectory: true)
    }

    var userShortcutURL: URL {
        homeDirectory
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("Darkbloom.app", isDirectory: true)
    }

    func coordinate() throws -> AppInstallOutcome {
        guard sourceBundleIdentifier == Self.productionBundleIdentifier else {
            return .continueLaunch
        }

        #if DEBUG
        if environment[Self.skipRelocationEnvironmentKey] == "1" {
            return .continueLaunch
        }
        #endif

        if sameResolvedPath(sourceBundleURL, destinationURL) {
            try ensureUserShortcut(nonce: makeUUID().uuidString.lowercased())
            return .continueLaunch
        }

        let sourceMetadata = try readMetadata(at: sourceBundleURL)
        guard sourceMetadata.identifier == Self.productionBundleIdentifier else {
            return .continueLaunch
        }

        // Authenticate and compare both live endpoints before creating the
        // managed directory or staging anything. A stale downloaded app must
        // never replace a newer self-updated install while recovery/state.json
        // still records that newer version.
        try verifyProductionSignature(at: sourceBundleURL) // pragma: allowlist secret
        let ownedDestinationMetadata = ownedBundleMetadata(at: destinationURL)
        try validateVersionTransition(
            source: sourceMetadata,
            sourceURL: sourceBundleURL,
            ownedDestination: ownedDestinationMetadata
        )

        let destinationRoot = destinationURL.deletingLastPathComponent()
        try prepareWritableDirectory(destinationRoot)

        let nonce = makeUUID().uuidString.lowercased()
        let stagingURL = destinationRoot.appendingPathComponent(
            ".Darkbloom.app.relocation-\(nonce)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: stagingURL) }

        // Re-authenticate the staged endpoint so neither side of the copy
        // relies on bundle metadata or a structural-only signature check.
        try executor.run(
            Self.dittoURL,
            arguments: ["--rsrc", "--extattr", sourceBundleURL.path, stagingURL.path]
        )
        try verifyProductionSignature(at: stagingURL)
        try verifyCopiedBundle(
            at: stagingURL,
            expected: sourceMetadata
        )

        let preservedForeignApp = try installVerifiedBundle(
            stagingURL,
            at: destinationURL,
            nonce: nonce
        )
        try ensureUserShortcut(nonce: nonce)

        try executor.run(
            Self.openURL,
            arguments: ["-n", destinationURL.path]
        )
        return .relocated(
            to: destinationURL,
            preservedForeignApp: preservedForeignApp
        )
    }

    private static func mainBundleSource() -> (url: URL, identifier: String?) {
        let bundle = Bundle.main
        return (bundle.bundleURL, bundle.bundleIdentifier)
    }

    private func verifyProductionSignature(at url: URL) throws {
        try executor.run(
            Self.codesignURL,
            arguments: [
                "--verify",
                "--strict",
                "--verbose=2",
                "--deep",
                "-R=\(Self.productionDesignatedRequirement)",
                url.path,
            ]
        )
    }

    private func verifyCopiedBundle(
        at copiedURL: URL,
        expected: BundleMetadata
    ) throws {
        let copied = try readMetadata(at: copiedURL)
        let fields = [
            ("bundle identifier", expected.identifier, copied.identifier),
            ("executable", expected.executable, copied.executable),
            ("short version", expected.shortVersion, copied.shortVersion),
            ("bundle version", expected.bundleVersion, copied.bundleVersion),
        ]
        for (field, expectedValue, actualValue) in fields where expectedValue != actualValue {
            throw AppInstallCoordinatorError.copiedBundleMismatch(
                field: field,
                expected: expectedValue,
                actual: actualValue
            )
        }

        let executableURL = copiedURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(copied.executable)
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw AppInstallCoordinatorError.copiedExecutableUnavailable(
                path: executableURL.path
            )
        }
    }

    private func installVerifiedBundle(
        _ stagingURL: URL,
        at destinationURL: URL,
        nonce: String
    ) throws -> URL? {
        guard itemExists(at: destinationURL) else {
            do {
                try fileManager.moveItem(at: stagingURL, to: destinationURL)
                return nil
            } catch {
                throw AppInstallCoordinatorError.installFailed(
                    path: destinationURL.path,
                    reason: error.localizedDescription
                )
            }
        }

        // Re-read ownership and ordering immediately before the live swap. The
        // copy can take time, and another updater may have changed the
        // destination since the pre-staging check.
        let stagedMetadata = try readMetadata(at: stagingURL)
        let ownedDestinationMetadata = ownedBundleMetadata(at: destinationURL)
        try validateVersionTransition(
            source: stagedMetadata,
            sourceURL: stagingURL,
            ownedDestination: ownedDestinationMetadata
        )
        let destinationIsOwned = ownedDestinationMetadata != nil
        let backupName = destinationIsOwned
            ? ".Darkbloom.app.previous-\(nonce)"
            : "Darkbloom.app.foreign-\(nonce)"
        let backupURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(backupName, isDirectory: true)

        do {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: stagingURL,
                backupItemName: backupName,
                options: [.usingNewMetadataOnly, .withoutDeletingBackupItem]
            )
        } catch {
            throw AppInstallCoordinatorError.installFailed(
                path: destinationURL.path,
                reason: error.localizedDescription
            )
        }

        if destinationIsOwned {
            try? fileManager.removeItem(at: backupURL)
            return nil
        }
        return backupURL
    }

    private func isOwnedBundle(at url: URL) -> Bool {
        ownedBundleMetadata(at: url) != nil
    }

    private func ownedBundleMetadata(at url: URL) -> BundleMetadata? {
        guard let type = try? fileManager.attributesOfItem(atPath: url.path)[.type]
                as? FileAttributeType,
              type == .typeDirectory,
              let metadata = try? readMetadata(at: url)
        else {
            return nil
        }
        guard metadata.identifier == Self.productionBundleIdentifier else {
            return nil
        }
        guard (try? verifyProductionSignature(at: url)) != nil else { // pragma: allowlist secret
            return nil
        }
        return metadata
    }

    private func validateVersionTransition(
        source: BundleMetadata,
        sourceURL: URL,
        ownedDestination: BundleMetadata?
    ) throws {
        let sourceVersion = try canonicalSemanticVersion(of: source, at: sourceURL)
        guard let ownedDestination else { return }
        let installedVersion = try canonicalSemanticVersion(
            of: ownedDestination,
            at: destinationURL
        )
        if sourceVersion < installedVersion,
           environment[Self.allowDowngradeEnvironmentKey] != "1" {
            throw AppInstallCoordinatorError.downgradeRejected(
                sourceVersion: source.shortVersion,
                installedVersion: ownedDestination.shortVersion
            )
        }
        if sourceVersion < installedVersion {
            let recoveryStateURL = destinationURL
                .deletingLastPathComponent()
                .appendingPathComponent("recovery/state.json")
            if itemExists(at: recoveryStateURL) {
                throw AppInstallCoordinatorError.downgradeRecoveryStatePresent(
                    path: recoveryStateURL.path
                )
            }
        }
    }

    private func canonicalSemanticVersion(
        of metadata: BundleMetadata,
        at url: URL
    ) throws -> BundleSemanticVersion {
        guard let shortVersion = BundleSemanticVersion(metadata.shortVersion) else {
            throw AppInstallCoordinatorError.invalidBundle(
                path: url.path,
                reason: "CFBundleShortVersionString is not canonical semantic versioning"
            )
        }
        guard let bundleVersion = BundleSemanticVersion(metadata.bundleVersion) else {
            throw AppInstallCoordinatorError.invalidBundle(
                path: url.path,
                reason: "CFBundleVersion is not canonical semantic versioning"
            )
        }
        guard shortVersion == bundleVersion else {
            throw AppInstallCoordinatorError.invalidBundle(
                path: url.path,
                reason: "CFBundleShortVersionString and CFBundleVersion disagree"
            )
        }
        return shortVersion
    }

    private func ensureUserShortcut(nonce: String) throws {
        let shortcutRoot = userShortcutURL.deletingLastPathComponent()
        try prepareWritableDirectory(shortcutRoot)

        if itemExists(at: userShortcutURL),
           sameResolvedPath(userShortcutURL, destinationURL)
        {
            return
        }

        let temporaryURL = shortcutRoot.appendingPathComponent(
            ".Darkbloom.app.shortcut-\(nonce)"
        )
        let backupURL = shortcutRoot.appendingPathComponent(
            ".Darkbloom.app.shortcut-backup-\(nonce)"
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }

        do {
            try fileManager.createSymbolicLink(
                atPath: temporaryURL.path,
                withDestinationPath: destinationURL.path
            )

            if itemExists(at: userShortcutURL) {
                guard isOwnedBundle(at: userShortcutURL) else {
                    return
                }
                try fileManager.moveItem(at: userShortcutURL, to: backupURL)
                do {
                    try fileManager.moveItem(at: temporaryURL, to: userShortcutURL)
                } catch {
                    try? fileManager.moveItem(at: backupURL, to: userShortcutURL)
                    throw error
                }
                try? fileManager.removeItem(at: backupURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: userShortcutURL)
            }
        } catch {
            throw AppInstallCoordinatorError.installFailed(
                path: userShortcutURL.path,
                reason: error.localizedDescription
            )
        }
    }

    private func prepareWritableDirectory(_ directory: URL) throws {
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw AppInstallCoordinatorError.destinationUnavailable(
                path: directory.path,
                reason: error.localizedDescription
            )
        }
        guard fileManager.isWritableFile(atPath: directory.path) else {
            throw AppInstallCoordinatorError.destinationUnavailable(
                path: directory.path,
                reason: "the folder is not writable by the current user"
            )
        }
    }

    private func itemExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
            || (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    private func sameResolvedPath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath()
            == rhs.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func readMetadata(at appURL: URL) throws -> BundleMetadata {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        do {
            let data = try Data(contentsOf: infoURL)
            guard let info = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any]
            else {
                throw MetadataError.invalidPropertyList
            }
            return try BundleMetadata(info: info)
        } catch {
            throw AppInstallCoordinatorError.invalidBundle(
                path: appURL.path,
                reason: error.localizedDescription
            )
        }
    }
}

private struct BundleMetadata {
    let identifier: String
    let executable: String
    let shortVersion: String
    let bundleVersion: String

    init(info: [String: Any]) throws {
        identifier = try Self.requiredString("CFBundleIdentifier", in: info)
        executable = try Self.requiredString("CFBundleExecutable", in: info)
        shortVersion = try Self.requiredString("CFBundleShortVersionString", in: info)
        bundleVersion = try Self.requiredString("CFBundleVersion", in: info)
    }

    private static func requiredString(
        _ key: String,
        in info: [String: Any]
    ) throws -> String {
        guard let value = info[key] as? String, !value.isEmpty else {
            throw MetadataError.missingValue(key)
        }
        return value
    }
}

private enum MetadataError: Error, LocalizedError {
    case invalidPropertyList
    case missingValue(String)

    var errorDescription: String? {
        switch self {
        case .invalidPropertyList:
            "Info.plist is not a dictionary"
        case .missingValue(let key):
            "Info.plist is missing \(key)"
        }
    }
}
