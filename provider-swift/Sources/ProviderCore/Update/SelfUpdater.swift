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
    case restartRequired(current: String, installed: String)
    case quarantined(version: String, reason: String)
    case checkFailed(reason: String)
}

/// Result of an update attempt.
public enum UpdateResult: Sendable {
    case updated(from: String, to: String)
    case restartRequired(from: String, to: String)
    case alreadyUpToDate(version: String)
    case quarantined(version: String, reason: String)
    case busy(reason: String)
    case cancelled(reason: String)
    case downloadFailed(reason: String)
    case hashMismatch(expected: String, got: String)
    case replaceFailed(reason: String)
}

/// Self-updater that checks the coordinator for new releases and applies updates.
public struct SelfUpdater: Sendable {

    private let coordinatorBaseURL: String
    private let installRootOverride: URL?
    private let verifyCodeSignatures: Bool
    private let currentVersion: String
    private let urlSession: URLSession
    private let now: @Sendable () -> Double

    public init(coordinatorBaseURL: String) {
        self.init(
            coordinatorBaseURL: coordinatorBaseURL,
            installRoot: nil,
            verifyCodeSignatures: true,
            currentVersion: ProviderCore.version,
            urlSession: .shared,
            now: { Date().timeIntervalSince1970 }
        )
    }

    internal init(
        coordinatorBaseURL: String,
        installRoot: URL?,
        verifyCodeSignatures: Bool,
        currentVersion: String,
        urlSession: URLSession = .shared,
        now: @escaping @Sendable () -> Double = {
            Date().timeIntervalSince1970
        }
    ) {
        // Convert WebSocket URL to HTTP if needed
        var base = WebSocketURLScheme.toHTTP(coordinatorBaseURL)
        // Strip trailing path components (e.g. /ws/provider)
        if let url = URL(string: base), let scheme = url.scheme, let host = url.host {
            let port = url.port.map { ":\($0)" } ?? ""
            base = "\(scheme)://\(host)\(port)"
        }
        self.coordinatorBaseURL = base
        self.installRootOverride = installRoot
        self.verifyCodeSignatures = verifyCodeSignatures
        self.currentVersion = currentVersion
        self.urlSession = urlSession
        self.now = now
    }

    // MARK: - Version Check

    /// Check the coordinator for the latest release.
    public func checkForUpdate(
        manualOverride: Bool = false,
        session: UpdateSession? = nil
    ) async -> UpdateCheckResult {
        let recoveryState: UpdateRecoveryState
        do {
            if let session {
                recoveryState = try session.readState()
            } else if let store = recoveryStore() {
                recoveryState = try store.loadState()
            } else {
                recoveryState = UpdateRecoveryState()
            }
        } catch {
            return .checkFailed(reason: "could not read update recovery state: \(error)")
        }
        if let candidate = recoveryState.candidate,
           candidate.release.version != currentVersion
        {
            return .restartRequired(
                current: currentVersion,
                installed: candidate.release.version
            )
        }

        let endpoint = "\(coordinatorBaseURL)/v1/releases/latest?platform=macos-arm64"

        guard let url = URL(string: endpoint) else {
            return .checkFailed(reason: "invalid coordinator URL: \(endpoint)")
        }

        do {
            let (data, response) = try await urlSession.data(from: url)

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
            guard platform == "macos-arm64" else {
                return .checkFailed(
                    reason: "coordinator returned unsupported release platform \(platform)")
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
            guard SemanticVersion(version) != nil,
                  SemanticVersion(currentVersion) != nil
            else {
                return .checkFailed(
                    reason: "release or current version is not valid SemVer")
            }

            if recoveryState.quarantineBlocks(version: version, manualOverride: manualOverride) {
                return .quarantined(
                    version: version,
                    reason: recoveryState.quarantine?.reason ?? "release failed local startup validation"
                )
            }

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
            let (tempFileURL, response) = try await urlSession.download(from: downloadURL)

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
        let release: ReleaseInfo
        /// Full extracted-tree digest captured after stage verification and
        /// checked again immediately before commit.
        let stagedTreeHash: String

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
    public func stageBundle(
        from downloadedFile: URL,
        release: ReleaseInfo,
        session: UpdateSession
    ) -> Result<StagedBundle, UpdateError> {
        let installDir = session.store.installRoot
        guard installDir == resolvedInstallRoot() else {
            return .failure(.replaceFailed("update session belongs to a different install root"))
        }
        return stageBundle(
            from: downloadedFile,
            release: release,
            installDir: installDir,
            verifyCodeSignatures: session.store.verifyCodeSignatures
        )
    }

    internal func stageBundleForTesting(
        from downloadedFile: URL,
        release: ReleaseInfo,
        installDir: URL
    ) -> Result<StagedBundle, UpdateError> {
        guard let session = try? beginUpdateSession(
            operation: "test-stage",
            timeout: 0,
            installRoot: installDir,
            verifyCodeSignatures: false
        ) else {
            return .failure(.replaceFailed("could not acquire test update lock"))
        }
        defer { session.release() }
        do {
            try session.recover()
        } catch {
            return .failure(.replaceFailed("\(error)"))
        }
        return stageBundle(
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
            var flatDarkbloom = try requiredBundleFile(
                names: ["bin/darkbloom", "darkbloom"],
                root: stagingRoot
            )
            var flatEnclave = try requiredBundleFile(
                names: ["bin/darkbloom-enclave", "darkbloom-enclave", "bin/eigeninference-enclave", "eigeninference-enclave"],
                root: stagingRoot
            )
            var flatMetallib = try requiredBundleFile(
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
            if !hasAppBundle {
                let canonicalBin = stagingRoot.appendingPathComponent("bin")
                try fm.createDirectory(
                    at: canonicalBin,
                    withIntermediateDirectories: true
                )
                func canonicalize(_ source: URL, name: String) throws -> URL {
                    let destination = canonicalBin.appendingPathComponent(name)
                    if source.standardizedFileURL != destination.standardizedFileURL {
                        try fm.moveItem(at: source, to: destination)
                    }
                    return destination
                }
                flatDarkbloom = try canonicalize(
                    flatDarkbloom,
                    name: "darkbloom"
                )
                flatEnclave = try canonicalize(
                    flatEnclave,
                    name: "darkbloom-enclave"
                )
                flatMetallib = try canonicalize(
                    flatMetallib,
                    name: "mlx.metallib"
                )
                let legacy = canonicalBin.appendingPathComponent(
                    "eigeninference-enclave"
                )
                if !UpdateAtomicFilesystem.itemExists(legacy) {
                    try fm.createSymbolicLink(
                        atPath: legacy.path,
                        withDestinationPath: "darkbloom-enclave"
                    )
                }
            }
            if verifyCodeSignatures {
                if hasAppBundle {
                    let appDarkbloom = extractedApp
                        .appendingPathComponent("Contents/MacOS/darkbloom")
                    let appMetallib = extractedApp
                        .appendingPathComponent("Contents/MacOS/mlx.metallib")
                    if let binaryHash = release.binaryHash {
                        try verifyHash(
                            file: appDarkbloom,
                            expected: binaryHash,
                            label: "Darkbloom.app darkbloom"
                        )
                    }
                    if let metallibHash = release.metallibHash {
                        try verifyHash(
                            file: appMetallib,
                            expected: metallibHash,
                            label: "Darkbloom.app mlx.metallib"
                        )
                    }
                    try verifyCodeSignature(file: appDarkbloom, label: "darkbloom")
                    try verifyCodeSignature(
                        file: extractedApp,
                        label: "Darkbloom.app",
                        deep: true
                    )
                } else {
                    try verifyCodeSignature(file: flatDarkbloom, label: "darkbloom")
                }
            }

            let stagedTreeHash = try UpdateAtomicFilesystem.treeHash(
                root: hasAppBundle
                    ? extractedApp
                    : stagingRoot.appendingPathComponent("bin")
            )
            return .success(StagedBundle(
                stagingRoot: stagingRoot,
                extractedApp: hasAppBundle ? extractedApp : nil,
                flatDarkbloom: flatDarkbloom,
                flatEnclave: flatEnclave,
                flatMetallib: flatMetallib,
                installDir: installDir,
                release: release,
                stagedTreeHash: stagedTreeHash
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
    public func commitStagedBundle(
        _ staged: StagedBundle,
        session: UpdateSession
    ) -> Result<Void, UpdateError> {
        guard staged.installDir.standardizedFileURL == session.store.installRoot else {
            return .failure(.replaceFailed("staged bundle belongs to a different install root"))
        }
        do {
            let stagedRoot = staged.extractedApp
                ?? staged.stagingRoot.appendingPathComponent("bin")
            let currentTreeHash = try UpdateAtomicFilesystem.treeHash(root: stagedRoot)
            guard currentTreeHash == staged.stagedTreeHash else {
                return .failure(.replaceFailed(
                    "staged bundle changed after verification; refusing commit"))
            }
            if session.store.verifyCodeSignatures {
                if let app = staged.extractedApp {
                    try verifyCodeSignature(
                        file: app,
                        label: "Darkbloom.app",
                        deep: true
                    )
                } else {
                    try verifyCodeSignature(
                        file: staged.flatDarkbloom,
                        label: "darkbloom"
                    )
                }
            }
            try session.store.commit(
                staged: staged,
                currentVersion: currentVersion,
                now: now()
            )
            return .success(())
        } catch {
            return .failure(.replaceFailed("\(error)"))
        }
    }

    internal func commitStagedBundleForTesting(
        _ staged: StagedBundle
    ) -> Result<Void, UpdateError> {
        do {
            let session = try beginUpdateSession(
                operation: "test-commit",
                timeout: 0,
                installRoot: staged.installDir,
                verifyCodeSignatures: false
            )
            defer { session.release() }
            try session.recover()
            return commitStagedBundle(staged, session: session)
        } catch {
            return .failure(.replaceFailed("\(error)"))
        }
    }

    /// The darkbloom root (~/.darkbloom/) of the running install. Must resolve
    /// symlinks first: invoked as plain `darkbloom`, `executablePath` is the
    /// /usr/local/bin/darkbloom PATH symlink, which would derive root=/usr/local
    /// and fail staging with EPERM ("can't save .update-staging-… in 'local'").
    private func resolvedInstallRoot() -> URL? {
        if let installRootOverride {
            return installRootOverride.standardizedFileURL
        }
        guard let executablePath = Bundle.main.executablePath else { return nil }
        return Self.installRoot(forExecutablePath: executablePath)
    }

    private func recoveryStore() -> UpdateRecoveryStore? {
        guard let root = resolvedInstallRoot() else { return nil }
        return UpdateRecoveryStore(
            installRoot: root,
            verifyCodeSignatures: verifyCodeSignatures
        )
    }

    public func beginUpdateSession(
        operation: String,
        timeout: TimeInterval = 0
    ) throws -> UpdateSession {
        guard let root = resolvedInstallRoot() else {
            throw UpdateError.replaceFailed("could not determine current executable path")
        }
        return try beginUpdateSession(
            operation: operation,
            timeout: timeout,
            installRoot: root,
            verifyCodeSignatures: verifyCodeSignatures
        )
    }

    private func beginUpdateSession(
        operation: String,
        timeout: TimeInterval,
        installRoot: URL,
        verifyCodeSignatures: Bool
    ) throws -> UpdateSession {
        let store = UpdateRecoveryStore(
            installRoot: installRoot,
            verifyCodeSignatures: verifyCodeSignatures
        )
        do {
            let processLock = try UpdateProcessLock.acquire(
                at: store.lockPath,
                operation: operation,
                timeout: timeout
            )
            return UpdateSession(processLock: processLock, store: store)
        } catch let error as UpdateProcessLock.LockError {
            let owner: UpdateProcessLock.Owner?
            if case .busy(let recorded) = error {
                owner = recorded
            } else {
                owner = nil
            }
            throw UpdateError.lockBusy(
                reason: error.description,
                owner: owner
            )
        }
    }

    /// Clear the candidate's pending launch marker when a restart command
    /// itself failed. No failed start is charged because no process was
    /// actually launched.
    public func cancelPendingCandidateAttempt(
        operation: String = "restart-failure-cleanup"
    ) throws {
        let session = try beginUpdateSession(operation: operation, timeout: 1)
        defer { session.release() }
        try session.recover()
        var state = try session.readState()
        let before = state
        state.cancelPendingAttempt()
        if state != before {
            try session.writeState(state)
        }
    }

    public func prepareCandidateLaunch(
        session: UpdateSession,
        baseline: ProviderLaunchSnapshot?,
        now: Double = Date().timeIntervalSince1970
    ) throws {
        var state = try session.readState()
        let before = state
        _ = state.prepareLaunchIntent(now: now, baseline: baseline)
        if state != before {
            try session.writeState(state)
        }
    }

    public func prepareCandidateLaunch(
        operation: String,
        baseline: ProviderLaunchSnapshot? = LaunchAgent.launchSnapshot()
    ) throws {
        let session = try beginUpdateSession(operation: operation, timeout: 1)
        defer { session.release() }
        try session.recover()
        try prepareCandidateLaunch(
            session: session,
            baseline: baseline,
            now: now()
        )
    }

    public func markCandidateLaunchIssued(
        session: UpdateSession,
        now: Double = Date().timeIntervalSince1970
    ) throws {
        var state = try session.readState()
        let before = state
        _ = state.markLaunchIssued(now: now)
        if state != before {
            try session.writeState(state)
        }
    }

    public func confirmRunningCandidateLaunch(
        processStartedAt: Double,
        operation: String = "candidate-process-confirmation"
    ) throws {
        let session = try beginUpdateSession(operation: operation, timeout: 1)
        defer { session.release() }
        try session.recover()
        var state = try session.readState()
        let before = state
        _ = state.confirmRunningCandidate(
            version: currentVersion,
            processStartedAt: processStartedAt,
            now: now()
        )
        if state != before {
            try session.writeState(state)
        }
    }

    /// Pure path derivation behind `liveInstallDir` (separated for tests).
    static func installRoot(forExecutablePath executablePath: String) -> URL {
        let execURL = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
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

    /// Minimum age before a staging directory is considered orphaned.
    /// A LIVE staging dir only exists between stage and commit, a window
    /// bounded by the drain timeout (minutes) — an hour-old dir can only be
    /// left over from a crashed cycle.
    private static let staleUpdateDirAge: TimeInterval = 60 * 60

    /// Best-effort cleanup of old staging directories. The process lock
    /// serializes every stage and commit; the age gate remains defensive
    /// against directories from binaries that predate the shared lock.
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
            guard name.hasPrefix(Self.stagingDirPrefix)
                    || name.hasPrefix(".rollback-staging-")
                    || name.hasPrefix(".recovery-restore-")
            else {
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
        do {
            let session = try beginUpdateSession(operation: "manual-install", timeout: 0)
            defer { session.release() }
            try session.recover()
            return installBundle(from: downloadedFile, release: release, session: session)
        } catch let error as UpdateError {
            return .failure(error)
        } catch {
            return .failure(.replaceFailed("\(error)"))
        }
    }

    internal func installBundleForTesting(
        from downloadedFile: URL,
        release: ReleaseInfo,
        installDir: URL
    ) -> Result<Void, UpdateError> {
        do {
            let session = try beginUpdateSession(
                operation: "test-install",
                timeout: 0,
                installRoot: installDir,
                verifyCodeSignatures: false
            )
            defer { session.release() }
            try session.recover()
            return installBundle(from: downloadedFile, release: release, session: session)
        } catch let error as UpdateError {
            return .failure(error)
        } catch {
            return .failure(.replaceFailed("\(error)"))
        }
    }

    private func installBundle(
        from downloadedFile: URL,
        release: ReleaseInfo,
        session: UpdateSession
    ) -> Result<Void, UpdateError> {
        switch stageBundle(
            from: downloadedFile,
            release: release,
            installDir: session.store.installRoot,
            verifyCodeSignatures: session.store.verifyCodeSignatures
        ) {
        case .failure(let error):
            return .failure(error)
        case .success(let staged):
            return commitStagedBundle(staged, session: session)
        }
    }

    // MARK: - Full Update Flow

    /// Check for updates and apply if available.
    public func update(manualOverride: Bool = false) async -> UpdateResult {
        let session: UpdateSession
        do {
            session = try beginUpdateSession(operation: "update", timeout: 0)
            try session.recover()
        } catch UpdateError.lockBusy(let reason, _) {
            return .busy(reason: reason)
        } catch {
            return .replaceFailed(reason: "update recovery failed: \(error)")
        }
        defer { session.release() }
        return await update(session: session, manualOverride: manualOverride)
    }

    public func update(
        session: UpdateSession,
        manualOverride: Bool = false,
        beforeInstall: @Sendable () -> Bool = { true }
    ) async -> UpdateResult {
        let checkResult = await checkForUpdate(
            manualOverride: manualOverride,
            session: session
        )

        switch checkResult {
        case .upToDate(let version):
            return .alreadyUpToDate(version: version)

        case .restartRequired(let current, let installed):
            return .restartRequired(from: current, to: installed)

        case .quarantined(let version, let reason):
            return .quarantined(version: version, reason: reason)

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
                case .lockBusy(let reason, _):
                    return .busy(reason: reason)
                }

            case .success(let tempFile):
                guard beforeInstall() else {
                    try? FileManager.default.removeItem(at: tempFile)
                    return .cancelled(
                        reason: "provider was intentionally stopped before install")
                }
                let replaceResult = installBundle(
                    from: tempFile,
                    release: release,
                    session: session
                )
                // Clean up the downloaded tarball regardless of install outcome.
                try? FileManager.default.removeItem(at: tempFile)
                switch replaceResult {
                case .success:
                    return .updated(from: current, to: release.version)
                case .failure(let error):
                    switch error {
                    case .replaceFailed(let reason),
                         .lockBusy(let reason, _):
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
        guard let latest = SemanticVersion(latest),
              let current = SemanticVersion(current)
        else {
            return false
        }
        return latest > current
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

    private func verifyHash(file: URL, expected: String, label: String) throws {
        let data = try Data(contentsOf: file)
        let digest = SHA256.hash(data: data)
        let got = digest.map { String(format: "%02x", $0) }.joined()
        guard got == expected.lowercased() else {
            throw UpdateError.hashMismatch(expected: expected, got: "\(label): \(got)")
        }
    }

    private func verifyCodeSignature(
        file: URL,
        label: String,
        deep: Bool = false
    ) throws {
        #if canImport(Darwin)
        do {
            try DarkbloomCodeSignature.verify(file, deep: deep)
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
    case lockBusy(reason: String, owner: UpdateProcessLock.Owner?)
}
