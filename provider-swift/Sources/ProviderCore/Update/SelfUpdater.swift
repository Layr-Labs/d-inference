import Foundation
import CryptoKit
import ProviderCoreFoundation

private struct UpdateStagingOwnershipRecord: Codable, Sendable, Equatable {
    static let currentSchema = 1

    let schema: Int
    let id: String
    let processIdentity: ProcessIdentity?
    let createdAt: Double

    enum CodingKeys: String, CodingKey {
        case schema
        case id
        case processIdentity = "process_identity"
        case createdAt = "created_at"
    }
}

/// Release information returned by the coordinator.
public struct ReleaseInfo: Sendable, Equatable {
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
    /// This PROCESS's compiled-in version (defaults to `ProviderCore.version`).
    /// Internal (not private) so `WatchdogRecoveryService` can resolve the
    /// installed daemon version through the same
    /// `effectiveInstalledVersion(processVersion:recorded:)` arithmetic
    /// `checkForUpdate` uses, from the same injected seam.
    internal let currentVersion: String
    private let urlSession: URLSession
    private let maximumReleaseArchiveBytes: UInt64
    private let now: @Sendable () -> Double
    /// Test seam threaded into every `UpdateRecoveryStore` this updater
    /// constructs; production always uses the no-op default.
    private let recoveryFaultInjector:
        @Sendable (UpdateRecoveryStore.FaultPoint) throws -> Void

    /// Whether this updater verifies the pinned Darkbloom code signature on
    /// staged/committed/installed artifacts. Always `true` for the public
    /// production initializer; `false` is reachable ONLY through the internal
    /// test seam (the `verifyCodeSignatures:` overload used by the `*ForTesting`
    /// helpers and fixtures, which stage synthetic unsigned binaries). Exposed
    /// so a test can assert the production path never selects the unsigned path.
    internal var verifiesCodeSignatures: Bool { verifyCodeSignatures }

    /// Production initializer: signature verification is ALWAYS on. There is no
    /// public way to construct a `SelfUpdater` that skips signature checks.
    public init(coordinatorBaseURL: String, urlSession: URLSession = .shared) {
        self.init(
            coordinatorBaseURL: coordinatorBaseURL,
            installRoot: nil,
            verifyCodeSignatures: true,
            currentVersion: ProviderCore.version,
            urlSession: urlSession,
            now: { Date().timeIntervalSince1970 }
        )
    }

    /// Per-request handshake/idle bound for watchdog-owned network calls.
    public static let watchdogRequestTimeoutSeconds: TimeInterval = 30
    /// Whole-transfer bound: generously covers a ~170 MB bundle on a slow
    /// link, but guarantees a stalled download can never wedge a watchdog
    /// tick forever.
    public static let watchdogResourceTimeoutSeconds: TimeInterval = 600

    /// Bounded session for the persistent watchdog. The default `.shared`
    /// session has a 7-day resource timeout — a stalled release download
    /// would block the recovery loop indefinitely even though preparation no
    /// longer owns the cross-process update locks.
    public static func watchdogURLSession() -> URLSession {
        boundedURLSession(
            requestTimeout: watchdogRequestTimeoutSeconds,
            resourceTimeout: watchdogResourceTimeoutSeconds
        )
    }

    /// Startup must prefer availability over waiting indefinitely for an
    /// optional update. A release that cannot finish inside this bound is
    /// retried by the serving provider's background updater.
    public static let startupRequestTimeoutSeconds: TimeInterval = 15
    public static let startupResourceTimeoutSeconds: TimeInterval = 120

    public static func startupURLSession() -> URLSession {
        boundedURLSession(
            requestTimeout: startupRequestTimeoutSeconds,
            resourceTimeout: startupResourceTimeoutSeconds
        )
    }

    private static func boundedURLSession(
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    /// Test-only seam. Passing `verifyCodeSignatures: false` disables the
    /// signature pin so tests can stage synthetic unsigned binaries; NO
    /// production call site does this (the public init hard-codes `true`, and
    /// the only `verifyCodeSignatures: false` callers are the `*ForTesting`
    /// helpers below). Do not add a production caller that passes `false`.
    internal init(
        coordinatorBaseURL: String,
        installRoot: URL?,
        verifyCodeSignatures: Bool,
        currentVersion: String,
        urlSession: URLSession = .shared,
        maximumReleaseArchiveBytes: UInt64 =
            ReleaseArchivePolicy.maxCompressedBytes,
        now: @escaping @Sendable () -> Double = {
            Date().timeIntervalSince1970
        },
        recoveryFaultInjector:
            @escaping @Sendable (UpdateRecoveryStore.FaultPoint) throws -> Void = { _ in }
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
        self.maximumReleaseArchiveBytes = maximumReleaseArchiveBytes
        self.now = now
        self.recoveryFaultInjector = recoveryFaultInjector
    }

    // MARK: - Version Check

    /// Check the coordinator for the latest release.
    public func checkForUpdate(
        manualOverride: Bool = false
    ) async -> UpdateCheckResult {
        let recoveryState: UpdateRecoveryState
        do {
            if let store = recoveryStore() {
                recoveryState = try store.loadState()
            } else {
                recoveryState = UpdateRecoveryState()
            }
        } catch {
            return .checkFailed(reason: "could not read update recovery state: \(error)")
        }

        return await checkForUpdate(
            manualOverride: manualOverride,
            recoveryState: recoveryState
        )
    }

    /// Evaluate the network release against one caller-owned recovery
    /// snapshot. Callers that intend to mutate first capture this snapshot
    /// under a short update session, release it, and only then await here.
    /// That ordering is the boundary that keeps network I/O outside the
    /// installation locks.
    internal func checkForUpdate(
        manualOverride: Bool,
        recoveryState: UpdateRecoveryState
    ) async -> UpdateCheckResult {
        let release: ReleaseInfo
        switch await fetchLatestRelease() {
        case .release(let fetched):
            release = fetched
        case .failed(let reason):
            let pendingCandidate = recoveryState.candidate.flatMap {
                $0.release.version != currentVersion ? $0 : nil
            }
            // A pending candidate must still restart when the coordinator is
            // unreachable — only DISCOVERY of a superseding release needs the
            // network, never the restart/rollback path itself.
            if let pendingCandidate {
                return .restartRequired(
                    current: currentVersion,
                    installed: pendingCandidate.release.version
                )
            }
            return .checkFailed(reason: reason)
        }
        return evaluateRelease(
            release,
            recoveryState: recoveryState,
            manualOverride: manualOverride
        )
    }

    /// Re-evaluate already-fetched release metadata without network I/O.
    /// Final commit callers invoke this only while holding `UpdateSession`,
    /// after interrupted-transaction recovery and a fresh state read.
    internal func evaluateRelease(
        _ release: ReleaseInfo,
        recoveryState: UpdateRecoveryState,
        manualOverride: Bool,
        installRoot: URL? = nil
    ) -> UpdateCheckResult {
        // Compare against the version installed ON DISK, not this process's
        // version. The persistent watchdog outlives the binary it replaces:
        // after it installs and promotes v2, its own `ProviderCore.version`
        // is still v1, and a process-version compare would re-download the
        // already-installed release and re-arm it as an unproven candidate
        // (a later unrelated crash could then quarantine a good release).
        // SemVer-max also keeps manual reinstalls, which bypass recovery
        // state, from re-candidatizing.
        let installedVersion = resolvedInstalledVersion(
            recoveryState: recoveryState,
            installRoot: installRoot
        )
        let pendingCandidate = recoveryState.candidate.flatMap {
            $0.release.version != currentVersion ? $0 : nil
        }
        func restartPendingCandidate(
            _ candidate: PendingReleaseCandidate
        ) -> UpdateCheckResult {
            .restartRequired(
                current: currentVersion,
                installed: candidate.release.version
            )
        }

        guard SemanticVersion(release.version) != nil,
              SemanticVersion(installedVersion) != nil
        else {
            if let pendingCandidate {
                return restartPendingCandidate(pendingCandidate)
            }
            return .checkFailed(
                reason: "release or current version is not valid SemVer")
        }

        if let pendingCandidate {
            // A strictly newer, non-quarantined release supersedes a pending
            // (possibly stuck) candidate: `installCandidate` quarantines a
            // superseded candidate that already failed starts. Without this,
            // a host wedged on a broken candidate whose rollback is blocked
            // could never be rescued by publishing a fixed release.
            if !recoveryState.quarantineBlocks(
                version: release.version,
                manualOverride: manualOverride
            ),
               isNewer(
                latest: release.version,
                current: pendingCandidate.release.version
               )
            {
                return .updateAvailable(current: installedVersion, latest: release)
            }
            return restartPendingCandidate(pendingCandidate)
        }

        if recoveryState.quarantineBlocks(
            version: release.version,
            manualOverride: manualOverride
        ) {
            return .quarantined(
                version: release.version,
                reason: recoveryState.quarantine?.reason ?? "release failed local startup validation"
            )
        }

        if isNewer(latest: release.version, current: installedVersion) {
            return .updateAvailable(current: installedVersion, latest: release)
        } else {
            return .upToDate(currentVersion: installedVersion)
        }
    }

    /// Resolve every durable version witness that can change while phase one
    /// is unlocked. App relocation and the shell installer share the mutation
    /// lock but intentionally do not write SelfUpdater's recovery generation,
    /// so a newer authenticated app version must participate in final
    /// revalidation. A pending SelfUpdater candidate remains authoritative:
    /// one-shot installers refuse to run while it exists.
    internal func resolvedInstalledVersion(
        recoveryState: UpdateRecoveryState,
        installRoot: URL? = nil
    ) -> String {
        var installedVersion = Self.effectiveInstalledVersion(
            processVersion: currentVersion,
            recorded: recoveryState.current?.version
        )
        guard recoveryState.candidate == nil,
              let onDisk = installedAppVersion(in: installRoot),
              isNewer(latest: onDisk, current: installedVersion)
        else {
            return installedVersion
        }
        installedVersion = onDisk
        return installedVersion
    }

    /// Canonical version from the installed app endpoint. Invalid, incomplete,
    /// unsigned (in shipping mode), or disagreeing plist versions are not
    /// trusted; recovery state/process version remains the fallback for legacy
    /// flat installs and synthetic fixtures.
    private func installedAppVersion(in explicitRoot: URL?) -> String? {
        guard let root = explicitRoot ?? resolvedInstallRoot() else {
            return nil
        }
        let app = root.appendingPathComponent("Darkbloom.app")
        if verifyCodeSignatures {
            guard (try? verifyCodeSignature(
                file: app,
                label: "installed Darkbloom.app",
                deep: true
            )) != nil else {
                return nil
            }
        }
        let info = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
              let object = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ),
              let values = object as? [String: Any],
              values["CFBundleIdentifier"] as? String
                == DarkbloomCodeSignature.bundleIdentifier,
              let short = values["CFBundleShortVersionString"] as? String,
              let bundle = values["CFBundleVersion"] as? String,
              let shortVersion = SemanticVersion(short),
              let bundleVersion = SemanticVersion(bundle),
              shortVersion == bundleVersion
        else {
            return nil
        }
        return short
    }

    /// The version installed on disk: the SemVer-newer of this process's
    /// compiled version and the recovery state's durable installed record.
    /// Falls back to the process version when the record is absent or not
    /// valid SemVer.
    internal static func effectiveInstalledVersion(
        processVersion: String,
        recorded: String?
    ) -> String {
        guard let recorded, SemanticVersion(recorded) != nil else {
            return processVersion
        }
        guard SemanticVersion(processVersion) != nil else { return recorded }
        return isNewer(latest: recorded, current: processVersion)
            ? recorded
            : processVersion
    }

    private enum LatestReleaseFetch {
        case release(ReleaseInfo)
        case failed(String)
    }

    private func fetchLatestRelease() async -> LatestReleaseFetch {
        let endpoint = "\(coordinatorBaseURL)/v1/releases/latest?platform=macos-arm64"

        guard let url = URL(string: endpoint) else {
            return .failed("invalid coordinator URL: \(endpoint)")
        }

        do {
            let (data, response) = try await urlSession.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .failed("unexpected response type")
            }

            guard httpResponse.statusCode == 200 else {
                return .failed("coordinator returned HTTP \(httpResponse.statusCode)")
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failed("invalid JSON response")
            }

            guard let version = json["version"] as? String,
                  let platform = json["platform"] as? String,
                  let downloadURL = json["url"] as? String
            else {
                return .failed("missing required fields in release response")
            }
            guard platform == "macos-arm64" else {
                return .failed("coordinator returned unsupported release platform \(platform)")
            }
            guard let bundleHash = (json["bundle_hash"] as? String)
                    ?? (json["sha256"] as? String)
                    ?? (json["binary_hash"] as? String)
            else {
                return .failed("missing release hash field")
            }

            return .release(ReleaseInfo(
                version: version,
                platform: platform,
                url: downloadURL,
                bundleHash: bundleHash,
                binaryHash: json["binary_hash"] as? String,
                metallibHash: json["metallib_hash"] as? String
            ))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Download and Verify

    /// Download the release bundle and verify its SHA-256 hash.
    public func downloadAndVerify(release: ReleaseInfo) async -> Result<URL, UpdateError> {
        guard let downloadURL = URL(string: release.url) else {
            return .failure(.invalidURL(release.url))
        }

        do {
            let (tempFileURL, _) = try await ReleaseArchiveDownloader.download(
                from: downloadURL,
                using: urlSession,
                maximumBytes: maximumReleaseArchiveBytes
            )
            var retainDownloadedArchive = false
            defer {
                if !retainDownloadedArchive {
                    try? FileManager.default.removeItem(at: tempFileURL)
                }
            }

            let attributes = try FileManager.default.attributesOfItem(
                atPath: tempFileURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let compressedSize = attributes[.size] as? NSNumber
            else {
                return .failure(.downloadFailed(
                    "downloaded release archive is not a regular file"))
            }
            guard compressedSize.uint64Value
                    <= maximumReleaseArchiveBytes
            else {
                return .failure(.downloadFailed(
                    "release archive exceeds the "
                        + "\(maximumReleaseArchiveBytes)-byte "
                        + "compressed-size limit"))
            }

            // Stream the digest so even a rejected maximum-size download does
            // not require a second archive-sized in-memory allocation.
            let computedHash = try sha256Hex(file: tempFileURL)
            guard computedHash == release.bundleHash.lowercased() else {
                return .failure(.hashMismatch(expected: release.bundleHash, got: computedHash))
            }

            retainDownloadedArchive = true
            return .success(tempFileURL)
        } catch {
            return .failure(.downloadFailed(error.localizedDescription))
        }
    }

    // MARK: - Stage / Commit

    /// Directory-name prefixes for staged bundles and commit backups inside
    /// the darkbloom root. Dot-prefixed so they stay out of the visible
    /// layout; provably orphaned entries are cleaned under a later final lease.
    static let stagingDirPrefix = ".update-staging-"
    private static let stagingOwnerFileName = ".darkbloom-staging-owner.json"
    private static let artifactVerificationTimeout: TimeInterval = 120

    private struct ArtifactVerificationPolicy {
        let codeSignaturePolicy: DarkbloomCodeSignature.Policy?
        let verifyRuntimeCapabilities: Bool

        static let production = ArtifactVerificationPolicy(
            codeSignaturePolicy: .darkbloomProduction,
            verifyRuntimeCapabilities: true)
        static let unverifiedTestFixture = ArtifactVerificationPolicy(
            codeSignaturePolicy: nil,
            verifyRuntimeCapabilities: false)
        static let signedTestFixture = ArtifactVerificationPolicy(
            codeSignaturePolicy: .structuralForIsolatedTest,
            verifyRuntimeCapabilities: true)
    }

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
        /// Exact modes of the payload that will become live.
        let artifactModes: UpdateArtifactModes
        /// Unforgeable-by-accident identity for this process-owned staging
        /// directory. Cleanup verifies the durable marker before deleting.
        fileprivate let ownership: UpdateStagingOwnershipRecord

        var installedBinary: URL {
            extractedApp?.appendingPathComponent("Contents/MacOS/darkbloom")
                ?? flatDarkbloom
        }

        var installedEnclave: URL {
            extractedApp?.appendingPathComponent(
                "Contents/MacOS/darkbloom-enclave"
            ) ?? flatEnclave
        }

        var installedMetallib: URL {
            extractedApp?.appendingPathComponent("Contents/MacOS/mlx.metallib")
                ?? flatMetallib
        }

        func currentArtifactModes() throws -> UpdateArtifactModes {
            try UpdateArtifactModes(
                binary: installedBinary,
                enclave: installedEnclave,
                metallib: installedMetallib
            )
        }

        func validateOwnership() throws {
            guard UpdateAtomicFilesystem.isDescendant(
                stagingRoot,
                of: installDir
            ),
                  stagingRoot.lastPathComponent
                    == "\(SelfUpdater.stagingDirPrefix)\(ownership.id)"
            else {
                throw UpdateError.replaceFailed(
                    "staged bundle ownership path is invalid"
                )
            }
            let marker = stagingRoot.appendingPathComponent(
                SelfUpdater.stagingOwnerFileName
            )
            let recorded: UpdateStagingOwnershipRecord
            do {
                recorded = try JSONDecoder().decode(
                    UpdateStagingOwnershipRecord.self,
                    from: Data(contentsOf: marker)
                )
            } catch {
                throw UpdateError.replaceFailed(
                    "staged bundle ownership marker is unreadable: \(error)"
                )
            }
            guard recorded.schema
                    == UpdateStagingOwnershipRecord.currentSchema,
                  recorded == ownership
            else {
                throw UpdateError.replaceFailed(
                    "staged bundle ownership changed after staging"
                )
            }
        }

        /// Remove the staged contents from disk (failure/abort cleanup).
        public func discard() {
            guard (try? validateOwnership()) != nil else { return }
            try? UpdateAtomicFilesystem.removeDurably(stagingRoot)
        }
    }

    /// Extract and verify a downloaded release bundle WITHOUT touching the
    /// live install. Safe to call while serving requests.
    ///
    /// Release tarballs contain a signed `Darkbloom.app/` bundle alongside
    /// flat `bin/` copies. The .app bundle is the canonical signed artifact;
    /// older flat-only tarballs (no .app bundle) are staged for the legacy
    /// direct-file install.
    internal func stageBundle(
        from downloadedFile: URL,
        release: ReleaseInfo
    ) -> Result<StagedBundle, UpdateError> {
        guard let installDir = resolvedInstallRoot() else {
            return .failure(.replaceFailed(
                "could not determine current executable path"
            ))
        }
        return stageBundle(
            from: downloadedFile,
            release: release,
            installDir: installDir,
            verification: verifyCodeSignatures
                ? .production
                : .unverifiedTestFixture
        )
    }

    /// TEST-ONLY. Stages without signature verification so tests can use
    /// synthetic unsigned binaries. Never call from production — the production
    /// path derives verification from the updater itself and always verifies;
    internal func stageBundleForTesting(
        from downloadedFile: URL,
        release: ReleaseInfo,
        installDir: URL
    ) -> Result<StagedBundle, UpdateError> {
        return stageBundle(
            from: downloadedFile,
            release: release,
            installDir: installDir,
            verification: .unverifiedTestFixture
        )
    }

    internal func stageSignedBundleForTesting(
        from downloadedFile: URL,
        release: ReleaseInfo,
        installDir: URL
    ) -> Result<StagedBundle, UpdateError> {
        stageBundle(
            from: downloadedFile,
            release: release,
            installDir: installDir,
            verification: .signedTestFixture)
    }

    private func stageBundle(
        from downloadedFile: URL,
        release: ReleaseInfo,
        installDir: URL,
        verification: ArtifactVerificationPolicy
    ) -> Result<StagedBundle, UpdateError> {
        let fm = FileManager.default
        let stagingID = UUID().uuidString.lowercased()
        let stagingRoot = installDir.appendingPathComponent(
            "\(Self.stagingDirPrefix)\(stagingID)", isDirectory: true)
        let ownership = UpdateStagingOwnershipRecord(
            schema: UpdateStagingOwnershipRecord.currentSchema,
            id: stagingID,
            processIdentity: ProcessIdentity.current(),
            createdAt: now()
        )

        do {
            // The complete tar header graph is approved before /usr/bin/tar
            // writes a single archive-controlled path into the staging tree.
            try ReleaseArchivePreflight.validate(downloadedFile)
            try fm.createDirectory(at: installDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            try UpdateAtomicFilesystem.writeJSON(
                ownership,
                to: stagingRoot.appendingPathComponent(
                    Self.stagingOwnerFileName
                )
            )
            try ReleaseArchiveExtractor.extract(
                archive: downloadedFile,
                destination: stagingRoot,
                timeout: Self.artifactVerificationTimeout
            )
            // The archive may legally contain an unknown dotfile at its root.
            // Re-publish our marker after extraction so archive bytes can
            // never become staging ownership authority.
            try UpdateAtomicFilesystem.writeJSON(
                ownership,
                to: stagingRoot.appendingPathComponent(
                    Self.stagingOwnerFileName
                )
            )

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
            let flatArtifactModes = try UpdateArtifactModes(
                binary: flatDarkbloom,
                enclave: flatEnclave,
                metallib: flatMetallib
            )
            if let mismatch = flatArtifactModes.releaseModeMismatch {
                throw UpdateError.replaceFailed(mismatch)
            }

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
            if let signaturePolicy = verification.codeSignaturePolicy {
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
                    try verifyCodeSignature(
                        file: appDarkbloom,
                        label: "darkbloom",
                        policy: signaturePolicy
                    )
                    try verifyCodeSignature(
                        file: extractedApp,
                        label: "Darkbloom.app",
                        deep: true,
                        policy: signaturePolicy
                    )
                    if verification.verifyRuntimeCapabilities {
                        try verifyRuntimeCapabilities(
                            app: extractedApp,
                            executable: appDarkbloom,
                            fileManager: fm,
                            signaturePolicy: signaturePolicy)
                    }
                } else {
                    if verification.verifyRuntimeCapabilities {
                        try FanHelperCapabilityVerifier.rejectFanCapableFlatExecutable(
                            flatDarkbloom
                        )
                    }
                    try verifyCodeSignature(
                        file: flatDarkbloom,
                        label: "darkbloom",
                        policy: signaturePolicy)
                }
            }

            let artifactModes: UpdateArtifactModes
            if hasAppBundle {
                artifactModes = try UpdateArtifactModes(
                    binary: extractedApp.appendingPathComponent(
                        "Contents/MacOS/darkbloom"
                    ),
                    enclave: extractedApp.appendingPathComponent(
                        "Contents/MacOS/darkbloom-enclave"
                    ),
                    metallib: extractedApp.appendingPathComponent(
                        "Contents/MacOS/mlx.metallib"
                    )
                )
            } else {
                artifactModes = flatArtifactModes
            }
            if let mismatch = artifactModes.releaseModeMismatch {
                throw UpdateError.replaceFailed(mismatch)
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
                stagedTreeHash: stagedTreeHash,
                artifactModes: artifactModes,
                ownership: ownership
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
    /// A successful commit consumes staging. A failure after journal creation
    /// preserves it for transaction replay; a pre-journal refusal leaves it
    /// owned by the preparer for discard/orphan cleanup.
    internal func commitStagedBundle(
        _ staged: StagedBundle,
        session: UpdateSession,
        manualOverride: Bool = false
    ) -> Result<Void, UpdateError> {
        guard staged.installDir.standardizedFileURL == session.store.installRoot else {
            return .failure(.replaceFailed("staged bundle belongs to a different install root"))
        }
        do {
            try session.recover(now: now())
            let currentState = try session.readState()
            guard case .updateAvailable(_, let eligibleRelease) =
                    evaluateRelease(
                        staged.release,
                        recoveryState: currentState,
                        manualOverride: manualOverride,
                        installRoot: session.store.installRoot
                    ),
                  eligibleRelease == staged.release
            else {
                return .failure(.replaceFailed(
                    "staged release is no longer eligible after final state revalidation"
                ))
            }
            try staged.validateOwnership()
            // Staging is now concurrent and lock-free. Sweep only after the
            // final session owns both mutation locks, and never delete a
            // directory whose recorded process identity is still alive.
            removeStaleUpdateDirs(
                in: staged.installDir,
                preserving: staged.stagingRoot
            )
            let stagedRoot = staged.extractedApp
                ?? staged.stagingRoot.appendingPathComponent("bin")
            let currentTreeHash = try UpdateAtomicFilesystem.treeHash(root: stagedRoot)
            guard currentTreeHash == staged.stagedTreeHash else {
                return .failure(.replaceFailed(
                    "staged bundle changed after verification; refusing commit"))
            }
            guard try staged.currentArtifactModes() == staged.artifactModes else {
                return .failure(.replaceFailed(
                    "staged payload permissions changed after verification; refusing commit"
                ))
            }
            if session.store.verifyCodeSignatures {
                if let app = staged.extractedApp {
                    try verifyCodeSignature(
                        file: app,
                        label: "Darkbloom.app",
                        deep: true
                    )
                    try FanHelperCapabilityVerifier.verify(
                        app: app,
                        executable: app.appendingPathComponent(
                            "Contents/MacOS/darkbloom"
                        ),
                        signaturePolicy: .darkbloomProduction
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

    /// TEST-ONLY. Commits without signature verification. Never call from
    /// production — the production path is `commitStagedBundle(_:session:)`.
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
            verifyCodeSignatures: verifyCodeSignatures,
            faultInjector: recoveryFaultInjector
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
            verifyCodeSignatures: verifyCodeSignatures,
            faultInjector: recoveryFaultInjector
        )
        let installMutationLock: InstallMutationLock
        do {
            installMutationLock = try InstallMutationLock.acquirePrimary(
                in: installRoot,
                timeout: timeout
            )
        } catch let error as InstallMutationLock.LockError {
            switch error {
            case .timedOut:
                throw UpdateError.lockBusy(
                    reason: error.localizedDescription,
                    owner: nil
                )
            case .unavailable:
                throw UpdateError.replaceFailed(error.localizedDescription)
            }
        }

        do {
            let processLock = try UpdateProcessLock.acquire(
                at: store.lockPath,
                operation: operation,
                timeout: timeout
            )
            if let pendingInstall = try InstallMutationLock.pendingOneShotTransaction(
                in: installRoot
            ) {
                processLock.release()
                installMutationLock.release()
                throw UpdateError.replaceFailed(
                    "one-shot installer transaction requires recovery at "
                        + pendingInstall.path
                )
            }
            return UpdateSession(
                installMutationLock: installMutationLock,
                processLock: processLock,
                store: store
            )
        } catch let error as UpdateProcessLock.LockError {
            installMutationLock.release()
            // Only real contention is `lockBusy` — flock is kernel-owned and
            // auto-releases on owner death, so `.busy` always means a LIVE
            // process holds the lease. An unopenable recovery dir or lock
            // file (full disk, permissions) is an infrastructure failure, not
            // contention: callers must not wait for a nonexistent owner.
            if case .busy(let recorded) = error {
                throw UpdateError.lockBusy(
                    reason: error.description,
                    owner: recorded
                )
            }
            throw UpdateError.replaceFailed(error.description)
        } catch {
            installMutationLock.release()
            throw error
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

    /// Minimum age before an ownership-less legacy staging directory is
    /// considered orphaned. Current staging directories carry a process
    /// identity and are removed only when that exact process is no longer
    /// alive; age alone must never clobber a long-lived rollover-jitter stage.
    private static let staleUpdateDirAge: TimeInterval = 60 * 60

    /// Best-effort cleanup under the final mutation session. Recovery/rollback
    /// scratch is lock-owned. Update staging itself is deliberately lock-free,
    /// so a valid live owner marker always wins over the age heuristic.
    private func removeStaleUpdateDirs(
        in installDir: URL,
        preserving: URL
    ) {
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
            let isUpdateStage = name.hasPrefix(Self.stagingDirPrefix)
            guard isUpdateStage
                    || name.hasPrefix(".rollback-staging-")
                    || name.hasPrefix(".recovery-restore-")
            else {
                continue
            }
            if entry.standardizedFileURL == preserving.standardizedFileURL {
                continue
            }
            if isUpdateStage {
                let marker = entry.appendingPathComponent(
                    Self.stagingOwnerFileName
                )
                if UpdateAtomicFilesystem.itemExists(marker) {
                    guard let data = try? Data(contentsOf: marker),
                          let owner = try? JSONDecoder().decode(
                            UpdateStagingOwnershipRecord.self,
                            from: data
                          ),
                          owner.schema
                            == UpdateStagingOwnershipRecord.currentSchema
                    else {
                        // Ambiguous ownership fails closed. The directory is
                        // inert and can be removed by an operator or after a
                        // later process can prove ownership.
                        continue
                    }
                    guard let identity = owner.processIdentity else {
                        // This platform could not record a kernel identity, so
                        // ownership cannot be disproved safely.
                        continue
                    }
                    if identity.isCurrent()
                        || daemonProcessAlive(pid: identity.pid)
                    {
                        // Exact owner alive, identity temporarily unreadable,
                        // or PID reused: all are conservative preservation
                        // cases. A reused PID is collected after it exits.
                        continue
                    }
                    try? fm.removeItem(at: entry)
                    continue
                }
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
        let staged: StagedBundle
        switch stageBundle(from: downloadedFile, release: release) {
        case .failure(let error):
            return .failure(error)
        case .success(let value):
            staged = value
        }
        do {
            let session = try beginUpdateSession(operation: "manual-install", timeout: 0)
            defer { session.release() }
            try session.recover()
            return commitStagedBundle(staged, session: session)
        } catch let error as UpdateError {
            staged.discard()
            return .failure(error)
        } catch {
            staged.discard()
            return .failure(.replaceFailed("\(error)"))
        }
    }

    /// TEST-ONLY. Installs without signature verification. Shipping install
    /// paths derive verification policy from their updater instance.
    internal func installBundleForTesting(
        from downloadedFile: URL,
        release: ReleaseInfo,
        installDir: URL
    ) -> Result<Void, UpdateError> {
        let staged: StagedBundle
        switch stageBundle(
            from: downloadedFile,
            release: release,
            installDir: installDir,
            verification: .unverifiedTestFixture
        ) {
        case .failure(let error):
            return .failure(error)
        case .success(let value):
            staged = value
        }
        do {
            let session = try beginUpdateSession(
                operation: "test-install",
                timeout: 0,
                installRoot: installDir,
                verifyCodeSignatures: false
            )
            defer { session.release() }
            try session.recover()
            return commitStagedBundle(staged, session: session)
        } catch let error as UpdateError {
            staged.discard()
            return .failure(error)
        } catch {
            staged.discard()
            return .failure(.replaceFailed("\(error)"))
        }
    }
    // MARK: - Version Comparison

    /// Compare semver-style version strings. Returns true if `latest` is newer than `current`.
    ///
    /// Both values must be canonical SemVer 2. Prerelease identifiers use the
    /// specification's exact precedence and build metadata is ignored.
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

    private func sha256Hex(file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty {
                break
            }
            hasher.update(data: data)
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func verifyHash(file: URL, expected: String, label: String) throws {
        let got = try sha256Hex(file: file)
        guard got == expected.lowercased() else {
            throw UpdateError.hashMismatch(expected: expected, got: "\(label): \(got)")
        }
    }

    private func verifyRuntimeCapabilities(
        app: URL,
        executable: URL,
        fileManager: FileManager,
        signaturePolicy: DarkbloomCodeSignature.Policy
    ) throws {
        try FanHelperCapabilityVerifier.verify(
            app: app,
            executable: executable,
            signaturePolicy: signaturePolicy
        )
        let marker = app.appendingPathComponent(
            PackagedRuntimeSmoke.pagedCapabilityRelativePath)
        let markerPresent = fileManager.fileExists(atPath: marker.path)
        let binary = try Data(contentsOf: executable, options: [.mappedIfSafe])
        let pagedCodePresent = binary.range(
            of: Data("engine_v2_kv_backend".utf8)) != nil

        guard markerPresent == pagedCodePresent else {
            throw UpdateError.replaceFailed(
                pagedCodePresent
                    ? "paged-capable artifact is missing its signed capability marker"
                    : "artifact advertises paged capability without paged runtime code")
        }
        guard markerPresent else {
            return // pre-paged v0.7.5/v0.7.7 compatibility
        }
        guard
            let markerValue = try? String(contentsOf: marker, encoding: .utf8),
            markerValue.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        else {
            throw UpdateError.replaceFailed(
                "paged runtime capability marker is invalid")
        }

        let resourceRoot = app.appendingPathComponent(
            "Contents/Resources",
            isDirectory: true)
        let bundles = try fileManager.contentsOfDirectory(
            at: resourceRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
            .filter {
                $0.lastPathComponent == PackagedRuntimeSmoke.mlxLMCommonBundleName
            }
            .map { $0.appendingPathComponent("pagedattention.metal") }
            .filter { fileManager.isReadableFile(atPath: $0.path) }
        guard bundles.count == 1 else {
            throw UpdateError.replaceFailed(
                "paged-capable artifact requires exactly one sealed "
                    + "\(PackagedRuntimeSmoke.mlxLMCommonBundleName)/pagedattention.metal "
                    + "(found \(bundles.count))")
        }
        // The signed child must prove the production TOML projection,
        // overwrite precedence, early safe-R1 latch, and packaged AOT before
        // it reaches the existing paged-kernel GPU smoke.
        var smokeEnvironment = try PackagedRuntimeSmoke.retainedValidationEnvironment()
        smokeEnvironment["DARKBLOOM_NO_UPDATE_CHECK"] = "1"
        let smokeOutput = try BoundedProcess.runCapturingStandardOutput(
            executable,
            arguments: ["runtime-smoke"],
            environment: smokeEnvironment,
            timeout: Self.artifactVerificationTimeout)
        guard PackagedRuntimeSmoke.containsGemmaOptimizationSuccessMarker(smokeOutput)
        else {
            throw UpdateError.replaceFailed(
                "packaged runtime smoke omitted the retained Gemma optimization marker")
        }
    }

    private func verifyCodeSignature(
        file: URL,
        label: String,
        deep: Bool = false,
        policy: DarkbloomCodeSignature.Policy = .darkbloomProduction
    ) throws {
        #if canImport(Darwin)
        do {
            try DarkbloomCodeSignature.verify(
                file,
                deep: deep,
                policy: policy
            )
        } catch {
            throw UpdateError.replaceFailed("\(label) code signature verification failed: \(error.localizedDescription)")
        }
        #endif
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
