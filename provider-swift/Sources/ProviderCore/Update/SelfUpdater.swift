import Foundation
import CryptoKit

/// Release information returned by the coordinator.
public struct ReleaseInfo: Sendable {
    public let version: String
    public let platform: String
    public let url: String
    public let bundleHash: String
    public let binaryHash: String?
    public let metallibHash: String?

    public init(
        version: String,
        platform: String,
        url: String,
        bundleHash: String,
        binaryHash: String? = nil,
        metallibHash: String? = nil
    ) {
        self.version = version
        self.platform = platform
        self.url = url
        self.bundleHash = bundleHash
        self.binaryHash = binaryHash
        self.metallibHash = metallibHash
    }

    public var sha256: String {
        bundleHash
    }
}

/// Result of an update check.
public enum UpdateCheckResult: Sendable {
    case upToDate(currentVersion: String)
    case updateAvailable(current: String, latest: ReleaseInfo)
    case checkFailed(reason: String)
}

/// Result of an update attempt.
public enum UpdateResult: Sendable {
    case updated(from: String, to: String)
    case alreadyUpToDate(version: String)
    case downloadFailed(reason: String)
    case hashMismatch(expected: String, got: String)
    case replaceFailed(reason: String)
}

/// Self-updater that checks the coordinator for new releases and applies updates.
public struct SelfUpdater: Sendable {

    private let coordinatorBaseURL: String

    public init(coordinatorBaseURL: String) {
        // Convert WebSocket URL to HTTP if needed
        var base = coordinatorBaseURL
        if base.hasPrefix("ws://") {
            base = "http://" + base.dropFirst("ws://".count)
        } else if base.hasPrefix("wss://") {
            base = "https://" + base.dropFirst("wss://".count)
        }
        // Strip trailing path components (e.g. /ws/provider)
        if let url = URL(string: base), let scheme = url.scheme, let host = url.host {
            let port = url.port.map { ":\($0)" } ?? ""
            base = "\(scheme)://\(host)\(port)"
        }
        self.coordinatorBaseURL = base
    }

    // MARK: - Version Check

    /// Check the coordinator for the latest release.
    public func checkForUpdate() async -> UpdateCheckResult {
        let currentVersion = ProviderCore.version
        let endpoint = "\(coordinatorBaseURL)/v1/releases/latest?platform=macos-arm64"

        guard let url = URL(string: endpoint) else {
            return .checkFailed(reason: "invalid coordinator URL: \(endpoint)")
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .checkFailed(reason: "unexpected response type")
            }

            guard httpResponse.statusCode == 200 else {
                return .checkFailed(
                    reason: "coordinator returned HTTP \(httpResponse.statusCode)"
                )
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .checkFailed(reason: "invalid JSON response")
            }

            guard let version = json["version"] as? String,
                  let platform = json["platform"] as? String,
                  let downloadURL = json["url"] as? String
            else {
                return .checkFailed(reason: "missing required fields in release response")
            }
            guard let bundleHash = (json["bundle_hash"] as? String)
                    ?? (json["sha256"] as? String)
                    ?? (json["binary_hash"] as? String)
            else {
                return .checkFailed(reason: "missing release hash field")
            }

            let release = ReleaseInfo(
                version: version,
                platform: platform,
                url: downloadURL,
                bundleHash: bundleHash,
                binaryHash: json["binary_hash"] as? String,
                metallibHash: json["metallib_hash"] as? String
            )

            if isNewer(latest: version, current: currentVersion) {
                return .updateAvailable(current: currentVersion, latest: release)
            } else {
                return .upToDate(currentVersion: currentVersion)
            }
        } catch {
            return .checkFailed(reason: error.localizedDescription)
        }
    }

    // MARK: - Download and Verify

    /// Download the release bundle and verify its SHA-256 hash.
    public func downloadAndVerify(release: ReleaseInfo) async -> Result<URL, UpdateError> {
        guard let downloadURL = URL(string: release.url) else {
            return .failure(.invalidURL(release.url))
        }

        do {
            let (tempFileURL, response) = try await URLSession.shared.download(from: downloadURL)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200
            else {
                return .failure(.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"))
            }

            // Verify SHA-256
            let fileData = try Data(contentsOf: tempFileURL)
            let digest = SHA256.hash(data: fileData)
            let computedHash = digest.map { String(format: "%02x", $0) }.joined()

            guard computedHash == release.bundleHash.lowercased() else {
                try? FileManager.default.removeItem(at: tempFileURL)
                return .failure(.hashMismatch(expected: release.bundleHash, got: computedHash))
            }

            return .success(tempFileURL)
        } catch {
            return .failure(.downloadFailed(error.localizedDescription))
        }
    }

    // MARK: - Stage / Commit

    /// Directory-name prefixes for staged bundles and commit backups inside
    /// the darkbloom root. Dot-prefixed so they stay out of the visible
    /// layout; cleaned up on the next staging pass if a crash orphans them.
    private static let stagingDirPrefix = ".update-staging-"
    private static let backupDirPrefix = ".update-backup-"

    /// A release bundle that has been extracted and fully verified (hashes and
    /// code signature) but NOT yet installed into the live layout.
    ///
    /// Staging runs while the provider is still serving: nothing under the
    /// live `Darkbloom.app`/`bin/` layout is touched, so a failed or abandoned
    /// update can never affect in-flight or future requests. The commit step —
    /// the only part that mutates the live install — runs after admission is
    /// closed and in-flight work has drained.
    public struct StagedBundle: Sendable {
        /// Directory owning the extracted, verified bundle contents. Lives
        /// inside `installDir` so the commit swap is a same-volume rename.
        public let stagingRoot: URL
        /// Extracted `Darkbloom.app` inside `stagingRoot` (nil for legacy
        /// flat-only tarballs).
        let extractedApp: URL?
        /// Flat-layout binaries inside `stagingRoot` (legacy install sources).
        let flatDarkbloom: URL
        let flatEnclave: URL
        let flatMetallib: URL
        /// The darkbloom root directory the commit will write into.
        let installDir: URL

        /// Remove the staged contents from disk (failure/abort cleanup).
        public func discard() {
            try? FileManager.default.removeItem(at: stagingRoot)
        }
    }

    /// Extract and verify a downloaded release bundle WITHOUT touching the
    /// live install. Safe to call while serving requests.
    ///
    /// Release tarballs contain a signed `Darkbloom.app/` bundle alongside
    /// flat `bin/` copies. The .app bundle is the canonical signed artifact;
    /// older flat-only tarballs (no .app bundle) are staged for the legacy
    /// direct-file install.
    public func stageBundle(from downloadedFile: URL, release: ReleaseInfo) -> Result<StagedBundle, UpdateError> {
        guard let installDir = liveInstallDir() else {
            return .failure(.replaceFailed("could not determine current executable path"))
        }
        return stageBundle(
            from: downloadedFile,
            release: release,
            installDir: installDir,
            verifyCodeSignatures: true
        )
    }

    internal func stageBundleForTesting(
        from downloadedFile: URL,
        release: ReleaseInfo,
        installDir: URL
    ) -> Result<StagedBundle, UpdateError> {
        stageBundle(
            from: downloadedFile,
            release: release,
            installDir: installDir,
            verifyCodeSignatures: false
        )
    }

    private func stageBundle(
        from downloadedFile: URL,
        release: ReleaseInfo,
        installDir: URL,
        verifyCodeSignatures: Bool
    ) -> Result<StagedBundle, UpdateError> {
        let fm = FileManager.default
        let stagingRoot = installDir.appendingPathComponent(
            "\(Self.stagingDirPrefix)\(UUID().uuidString)", isDirectory: true)

        do {
            try fm.createDirectory(at: installDir, withIntermediateDirectories: true)
            // Best-effort removal of staging/backup dirs orphaned by a crash
            // between stage and commit in an earlier process.
            removeStaleUpdateDirs(in: installDir)

            try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            try runProcess("/usr/bin/tar", arguments: ["xzf", downloadedFile.path, "-C", stagingRoot.path])

            // Use the flat bin/ copies for hash verification (release hashes
            // are computed from the flat layout).
            let flatDarkbloom = try requiredBundleFile(
                names: ["bin/darkbloom", "darkbloom"],
                root: stagingRoot
            )
            let flatEnclave = try requiredBundleFile(
                names: ["bin/darkbloom-enclave", "darkbloom-enclave", "bin/eigeninference-enclave", "eigeninference-enclave"],
                root: stagingRoot
            )
            let flatMetallib = try requiredBundleFile(
                names: ["bin/mlx.metallib", "mlx.metallib"],
                root: stagingRoot
            )

            if let binaryHash = release.binaryHash {
                try verifyHash(file: flatDarkbloom, expected: binaryHash, label: "darkbloom")
            }
            if let metallibHash = release.metallibHash {
                try verifyHash(file: flatMetallib, expected: metallibHash, label: "mlx.metallib")
            }

            // Check for .app bundle layout (new signed bundle format).
            // The .app bundle is the canonical signed artifact; the flat
            // bin/ copies carry a bundle-contextual code signature that
            // fails codesign --verify when run standalone, causing macOS
            // to SIGKILL the process.
            let extractedApp = stagingRoot.appendingPathComponent("Darkbloom.app")
            let hasAppBundle = fm.fileExists(atPath: extractedApp.path)
            if verifyCodeSignatures {
                if hasAppBundle {
                    let appDarkbloom = extractedApp
                        .appendingPathComponent("Contents/MacOS/darkbloom")
                    try verifyCodeSignature(file: appDarkbloom, label: "darkbloom")
                } else {
                    try verifyCodeSignature(file: flatDarkbloom, label: "darkbloom")
                }
            }

            return .success(StagedBundle(
                stagingRoot: stagingRoot,
                extractedApp: hasAppBundle ? extractedApp : nil,
                flatDarkbloom: flatDarkbloom,
                flatEnclave: flatEnclave,
                flatMetallib: flatMetallib,
                installDir: installDir
            ))
        } catch let error as UpdateError {
            try? fm.removeItem(at: stagingRoot)
            return .failure(error)
        } catch {
            try? fm.removeItem(at: stagingRoot)
            return .failure(.replaceFailed(error.localizedDescription))
        }
    }

    /// Swap a staged, verified bundle into the live layout. This is the ONLY
    /// update step that mutates the running install — callers must have
    /// closed admission (drain) first. The swap is rename-based (staging and
    /// backup live on the same volume as the install), so the window in which
    /// live paths are missing is milliseconds, not a full bundle copy.
    ///
    /// The staging directory is consumed (moved or removed) regardless of
    /// outcome; on failure the previous layout is restored from the backup.
    public func commitStagedBundle(_ staged: StagedBundle) -> Result<Void, UpdateError> {
        let fm = FileManager.default
        let backupRoot = staged.installDir.appendingPathComponent(
            "\(Self.backupDirPrefix)\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fm.removeItem(at: staged.stagingRoot)
            try? fm.removeItem(at: backupRoot)
        }

        do {
            try fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
            if let extractedApp = staged.extractedApp {
                return try commitAppBundle(
                    extractedApp: extractedApp,
                    installDir: staged.installDir,
                    backupRoot: backupRoot
                )
            }
            return try commitFlatBundle(staged, backupRoot: backupRoot)
        } catch let error as UpdateError {
            return .failure(error)
        } catch {
            return .failure(.replaceFailed(error.localizedDescription))
        }
    }

    /// Commit a signed .app bundle and create bin/ symlinks.
    ///
    /// This mirrors the install.sh layout:
    ///   installDir/Darkbloom.app/Contents/MacOS/{darkbloom,darkbloom-enclave,mlx.metallib}
    ///   installDir/bin/darkbloom          -> ../Darkbloom.app/Contents/MacOS/darkbloom
    ///   installDir/bin/darkbloom-enclave  -> ../Darkbloom.app/Contents/MacOS/darkbloom-enclave
    ///   installDir/bin/mlx.metallib       -> ../Darkbloom.app/Contents/MacOS/mlx.metallib
    private func commitAppBundle(
        extractedApp: URL,
        installDir: URL,
        backupRoot: URL
    ) throws -> Result<Void, UpdateError> {
        let fm = FileManager.default

        let destinationApp = installDir.appendingPathComponent("Darkbloom.app")
        let backupApp = backupRoot.appendingPathComponent("Darkbloom.app")

        // Move (rename) the existing .app bundle aside.
        if fm.fileExists(atPath: destinationApp.path) {
            try fm.moveItem(at: destinationApp, to: backupApp)
        }

        do {
            // Move the staged .app bundle into place (same-volume rename).
            try fm.moveItem(at: extractedApp, to: destinationApp)

            let appBin = "Darkbloom.app/Contents/MacOS"
            let binDir = installDir.appendingPathComponent("bin")
            try fm.createDirectory(at: binDir, withIntermediateDirectories: true)

            // Create symlinks from bin/ into the .app bundle, matching install.sh.
            // Use relative paths ("../Darkbloom.app/Contents/MacOS/X") so the
            // layout is relocatable.
            let symlinks = [
                ("darkbloom", "../\(appBin)/darkbloom"),
                ("darkbloom-enclave", "../\(appBin)/darkbloom-enclave"),
                ("mlx.metallib", "../\(appBin)/mlx.metallib"),
                ("eigeninference-enclave", "darkbloom-enclave"),
            ]
            for (name, target) in symlinks {
                let link = binDir.appendingPathComponent(name)
                // Remove existing file/symlink.
                if itemExistsIncludingSymlink(link) {
                    try fm.removeItem(at: link)
                }
                try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target)
            }

            return .success(())
        } catch {
            // Rollback: restore the backed-up .app bundle.
            try? fm.removeItem(at: destinationApp)
            if fm.fileExists(atPath: backupApp.path) {
                try? fm.moveItem(at: backupApp, to: destinationApp)
            }
            throw error
        }
    }

    /// Commit a legacy flat-only bundle: move the staged binaries directly
    /// into bin/ (no .app bundle in the tarball).
    private func commitFlatBundle(
        _ staged: StagedBundle,
        backupRoot: URL
    ) throws -> Result<Void, UpdateError> {
        let fm = FileManager.default
        let binDir = staged.installDir.appendingPathComponent("bin")
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        let targets = [
            ("darkbloom", staged.flatDarkbloom, 0o755),
            ("darkbloom-enclave", staged.flatEnclave, 0o755),
            ("mlx.metallib", staged.flatMetallib, 0o644),
        ] as [(String, URL, Int)]

        var installed: [URL] = []
        var backups: [URL: URL] = [:]
        do {
            for (name, source, mode) in targets {
                let destination = binDir.appendingPathComponent(name)
                let backup = backupRoot.appendingPathComponent(name)
                if fm.fileExists(atPath: destination.path) {
                    try fm.moveItem(at: destination, to: backup)
                    backups[destination] = backup
                }
                try fm.moveItem(at: source, to: destination)
                try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: destination.path)
                installed.append(destination)
            }

            let legacyLink = binDir.appendingPathComponent("eigeninference-enclave")
            let legacyBackup = backupRoot.appendingPathComponent("eigeninference-enclave")
            if itemExistsIncludingSymlink(legacyLink) {
                try fm.moveItem(at: legacyLink, to: legacyBackup)
                backups[legacyLink] = legacyBackup
            }
            try fm.createSymbolicLink(atPath: legacyLink.path, withDestinationPath: "darkbloom-enclave")
            installed.append(legacyLink)
        } catch {
            let destinations = Set(installed + Array(backups.keys))
            for destination in destinations {
                try? fm.removeItem(at: destination)
                if let backup = backups[destination], itemExistsIncludingSymlink(backup) {
                    try? fm.moveItem(at: backup, to: destination)
                }
            }
            throw error
        }

        return .success(())
    }

    /// The darkbloom root directory (~/.darkbloom/) of the running install.
    /// The executable could be at either:
    ///   ~/.darkbloom/bin/darkbloom                           -> root = ../../
    ///   ~/.darkbloom/Darkbloom.app/Contents/MacOS/darkbloom  -> root = ../../../../
    private func liveInstallDir() -> URL? {
        guard let executablePath = Bundle.main.executablePath else { return nil }
        let execURL = URL(fileURLWithPath: executablePath)
        let parentDir = execURL.deletingLastPathComponent()
        if parentDir.lastPathComponent == "MacOS" {
            // Inside .app bundle: MacOS -> Contents -> Darkbloom.app -> root
            return parentDir
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        }
        // Flat bin/ layout or unknown: bin -> root
        return parentDir.deletingLastPathComponent()
    }

    /// Minimum age before a staging/backup directory is considered orphaned.
    /// A LIVE staging dir only exists between stage and commit, a window
    /// bounded by the drain timeout (minutes) — an hour-old dir can only be
    /// left over from a crashed cycle.
    private static let staleUpdateDirAge: TimeInterval = 60 * 60

    /// Best-effort cleanup of staging/backup directories left behind by a
    /// crashed update cycle. Within one process, `claimStart` serializes
    /// cycles, but ANOTHER process may hold a live staged bundle (e.g. a
    /// foreground `darkbloom update` running while the serving daemon is
    /// mid-cycle) — the age gate ensures we never delete a staging directory
    /// an active cycle is still about to commit.
    private func removeStaleUpdateDirs(in installDir: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: installDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-Self.staleUpdateDirAge)
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(Self.stagingDirPrefix) || name.hasPrefix(Self.backupDirPrefix) else {
                continue
            }
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified > cutoff {
                continue // young enough to belong to a live cycle
            }
            try? fm.removeItem(at: entry)
        }
    }

    // MARK: - Install Bundle (one-shot)

    /// Install a verified release bundle into the darkbloom root directory:
    /// stage + commit in one call. Used by the foreground `darkbloom update`
    /// flow, where nothing is being served. The background auto-updater calls
    /// `stageBundle` / `commitStagedBundle` separately so the live swap only
    /// happens after admission is closed and in-flight work has drained.
    public func installBundle(from downloadedFile: URL, release: ReleaseInfo) -> Result<Void, UpdateError> {
        guard let installDir = liveInstallDir() else {
            return .failure(.replaceFailed("could not determine current executable path"))
        }
        return installBundle(
            from: downloadedFile,
            release: release,
            installDir: installDir,
            verifyCodeSignatures: true
        )
    }

    internal func installBundleForTesting(
        from downloadedFile: URL,
        release: ReleaseInfo,
        installDir: URL
    ) -> Result<Void, UpdateError> {
        installBundle(
            from: downloadedFile,
            release: release,
            installDir: installDir,
            verifyCodeSignatures: false
        )
    }

    private func installBundle(
        from downloadedFile: URL,
        release: ReleaseInfo,
        installDir: URL,
        verifyCodeSignatures: Bool
    ) -> Result<Void, UpdateError> {
        switch stageBundle(
            from: downloadedFile,
            release: release,
            installDir: installDir,
            verifyCodeSignatures: verifyCodeSignatures
        ) {
        case .failure(let error):
            return .failure(error)
        case .success(let staged):
            return commitStagedBundle(staged)
        }
    }

    // MARK: - Full Update Flow

    /// Check for updates and apply if available.
    public func update() async -> UpdateResult {
        let checkResult = await checkForUpdate()

        switch checkResult {
        case .upToDate(let version):
            return .alreadyUpToDate(version: version)

        case .checkFailed(let reason):
            return .downloadFailed(reason: "update check failed: \(reason)")

        case .updateAvailable(let current, let release):
            let downloadResult = await downloadAndVerify(release: release)

            switch downloadResult {
            case .failure(let error):
                switch error {
                case .hashMismatch(let expected, let got):
                    return .hashMismatch(expected: expected, got: got)
                case .downloadFailed(let reason):
                    return .downloadFailed(reason: reason)
                case .invalidURL(let url):
                    return .downloadFailed(reason: "invalid download URL: \(url)")
                case .replaceFailed(let reason):
                    return .replaceFailed(reason: reason)
                }

            case .success(let tempFile):
                let replaceResult = installBundle(from: tempFile, release: release)
                // Clean up the downloaded tarball regardless of install outcome.
                try? FileManager.default.removeItem(at: tempFile)
                switch replaceResult {
                case .success:
                    return .updated(from: current, to: release.version)
                case .failure(let error):
                    switch error {
                    case .replaceFailed(let reason):
                        return .replaceFailed(reason: reason)
                    default:
                        return .replaceFailed(reason: "\(error)")
                    }
                }
            }
        }
    }

    // MARK: - Version Comparison

    /// Compare semver-style version strings. Returns true if `latest` is newer than `current`.
    ///
    /// Handles versions like "0.4.0-swift", "0.4.1", etc. The suffix after '-' is
    /// stripped for comparison (pre-release suffixes are ignored for ordering).
    internal static func isNewer(latest: String, current: String) -> Bool {
        let latestParts = parseVersion(latest)
        let currentParts = parseVersion(current)

        for i in 0..<max(latestParts.count, currentParts.count) {
            let l = i < latestParts.count ? latestParts[i] : 0
            let c = i < currentParts.count ? currentParts[i] : 0
            if l > c { return true }
            if l < c { return false }
        }
        return false
    }

    private static func parseVersion(_ version: String) -> [Int] {
        // Strip pre-release suffix (e.g. "-swift", "-beta1")
        let base = version.split(separator: "-").first ?? Substring(version)
        return base.split(separator: ".").compactMap { Int($0) }
    }

    private func isNewer(latest: String, current: String) -> Bool {
        Self.isNewer(latest: latest, current: current)
    }

    private func requiredBundleFile(names: [String], root: URL) throws -> URL {
        let fm = FileManager.default
        for name in names {
            let candidate = root.appendingPathComponent(name)
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw UpdateError.replaceFailed("release bundle missing \(names[0])")
    }

    private func itemExistsIncludingSymlink(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.path)
            || (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func verifyHash(file: URL, expected: String, label: String) throws {
        let data = try Data(contentsOf: file)
        let digest = SHA256.hash(data: data)
        let got = digest.map { String(format: "%02x", $0) }.joined()
        guard got == expected.lowercased() else {
            throw UpdateError.hashMismatch(expected: expected, got: "\(label): \(got)")
        }
    }

    private func verifyCodeSignature(file: URL, label: String) throws {
        #if canImport(Darwin)
        do {
            try runProcess("/usr/bin/codesign", arguments: [
                "--verify",
                "--strict",
                "--verbose=2",
                file.path,
            ])
        } catch {
            throw UpdateError.replaceFailed("\(label) code signature verification failed: \(error.localizedDescription)")
        }
        #endif
    }

    private func runProcess(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError.replaceFailed(message?.isEmpty == false ? message! : "\(executable) exited \(process.terminationStatus)")
        }
    }
}

// MARK: - Errors

public enum UpdateError: Error, Sendable {
    case invalidURL(String)
    case downloadFailed(String)
    case hashMismatch(expected: String, got: String)
    case replaceFailed(String)
}
