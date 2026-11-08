import Foundation
import Logging
import ProviderAppAttest

private let releaseCheckLog = Logger(label: "darkbloom.update")

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
}

/// Why a release check failed: what the person who asked can do about it depends on it.
public struct UpdateCheckFailure: Sendable, Equatable, CustomStringConvertible {
    public enum Cause: Sendable, Equatable {
        /// No answer reached this Mac: none in time, a connection lost or refused, a name that didn't resolve, no
        /// network, a TLS handshake that broke off. Only this one is about this Mac's network connection.
        case noAnswer
        /// The coordinator answered, but not with a release this Mac can use: an HTTP error, an answer that isn't a
        /// release, a release for another platform or with a version that can't be read.
        case badAnswer
        /// This Mac didn't get as far as asking: its update record can't be read, its coordinator URL isn't one.
        case thisMac
    }

    public let cause: Cause
    /// What failed, in plain words.
    public let reason: String

    public init(_ cause: Cause, _ reason: String) {
        self.cause = cause
        self.reason = reason
    }

    public var description: String { reason }
}

/// Result of an update check.
public enum UpdateCheckResult: Sendable {
    case upToDate(currentVersion: String)
    case updateAvailable(current: String, latest: ReleaseInfo)
    case restartRequired(current: String, installed: String)
    case quarantined(version: String, reason: String)
    case checkFailed(UpdateCheckFailure)
}

/// Result of an update attempt.
public enum UpdateResult: Sendable {
    case updated(from: String, to: String)
    case restartRequired(from: String, to: String)
    case alreadyUpToDate(version: String)
    case quarantined(version: String, reason: String)
    case busy(reason: String)
    case cancelled(reason: String)
    /// The check for the latest release failed (`UpdateCheckResult.checkFailed`); nothing was downloaded.
    case checkFailed(UpdateCheckFailure)
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
    let releaseCheck: ReleaseCheck
    let now: @Sendable () -> Double
    /// Test seam threaded into every `UpdateRecoveryStore` this updater
    /// constructs; production always uses the no-op default.
    private let recoveryFaultInjector:
        @Sendable (UpdateRecoveryStore.FaultPoint) throws -> Void
    /// Test seam that observes the LaunchServices re-registration after a swap.
    /// Nil in production, where only the signature-verified path registers, so
    /// tests never write the machine's LaunchServices database.
    private let installedAppRegistrar: (@Sendable (URL) -> Void)?

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

    /// A production updater, as the public initializer makes it, whose release check is `releaseCheck` (a pair's
    /// automatic cycle asks one more round, `ReleaseCheck.pairCycle`).
    init(coordinatorBaseURL: String, urlSession: URLSession, releaseCheck: ReleaseCheck) {
        self.init(
            coordinatorBaseURL: coordinatorBaseURL,
            installRoot: nil,
            verifyCodeSignatures: true,
            currentVersion: ProviderCore.version,
            urlSession: urlSession,
            releaseCheck: releaseCheck
        )
    }

    /// Per-request handshake/idle bound for watchdog-owned network calls.
    public static let watchdogRequestTimeoutSeconds: TimeInterval = 30
    /// Whole-transfer bound: generously covers a ~170 MB bundle on a slow
    /// link, but guarantees a stalled download can never wedge a watchdog
    /// tick (and the update lock it holds) forever.
    public static let watchdogResourceTimeoutSeconds: TimeInterval = 600

    /// Bounded session for the persistent watchdog. The default `.shared`
    /// session has a 7-day resource timeout — a stalled release download
    /// would block the recovery loop indefinitely while holding the
    /// cross-process update lock.
    public static func watchdogURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = watchdogRequestTimeoutSeconds
        configuration.timeoutIntervalForResource = watchdogResourceTimeoutSeconds
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
        now: @escaping @Sendable () -> Double = {
            Date().timeIntervalSince1970
        },
        recoveryFaultInjector:
            @escaping @Sendable (UpdateRecoveryStore.FaultPoint) throws -> Void = { _ in },
        installedAppRegistrar: (@Sendable (URL) -> Void)? = nil,
        releaseCheck: ReleaseCheck = .standard
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
        self.releaseCheck = releaseCheck
        self.now = now
        self.recoveryFaultInjector = recoveryFaultInjector
        self.installedAppRegistrar = installedAppRegistrar
    }

    // MARK: - Version Check

    /// Check the coordinator for the latest release.
    public func checkForUpdate(
        manualOverride: Bool = false,
        session: UpdateSession? = nil
    ) async -> UpdateCheckResult {
        let recoveryState: UpdateRecoveryState
        let store = session?.store ?? recoveryStore()
        do {
            if let session {
                recoveryState = try session.readState()
            } else if let store {
                recoveryState = try store.loadState()
            } else {
                recoveryState = UpdateRecoveryState()
            }
        } catch {
            let record = store.map { $0.recoveryRoot.appendingPathComponent("state.json").path } ?? "unknown"
            return .checkFailed(.init(.thisMac, "this Mac's update record can't be read (\(record)): \(error)"))
        }

        // Compare against the version installed ON DISK, not this process's
        // version. The persistent watchdog outlives the binary it replaces:
        // after it installs and promotes v2, its own `ProviderCore.version`
        // is still v1, and a process-version compare would re-download the
        // already-installed release and re-arm it as an unproven candidate
        // (a later unrelated crash could then quarantine a good release).
        // SemVer-max also keeps manual reinstalls, which bypass recovery
        // state, from re-candidatizing.
        let installedVersion = Self.effectiveInstalledVersion(
            processVersion: currentVersion,
            recorded: recoveryState.current?.version
        )
        // Installed, not yet running. A candidate older than this process is not
        // pending: the app was replaced outside the updater, so nothing restarts
        // into it, and it never makes the running release an update target.
        let pendingCandidate = recoveryState.candidate.flatMap {
            ($0.release.version == currentVersion
                || isNewer(latest: currentVersion, current: $0.release.version)) ? nil : $0
        }
        func restartPendingCandidate(
            _ candidate: PendingReleaseCandidate
        ) -> UpdateCheckResult {
            .restartRequired(
                current: currentVersion,
                installed: candidate.release.version
            )
        }

        let release: ReleaseInfo
        switch await fetchLatestRelease() {
        case .release(let fetched):
            release = fetched
        case .failed(let failure):
            // A pending candidate must still restart when the coordinator is
            // unreachable — only DISCOVERY of a superseding release needs the
            // network, never the restart/rollback path itself.
            if let pendingCandidate {
                return restartPendingCandidate(pendingCandidate)
            }
            return .checkFailed(failure)
        }

        guard SemanticVersion(release.version) != nil,
              SemanticVersion(installedVersion) != nil
        else {
            if let pendingCandidate {
                return restartPendingCandidate(pendingCandidate)
            }
            guard SemanticVersion(release.version) != nil else {
                return .checkFailed(.init(.badAnswer,
                    "\(coordinatorName)'s latest release has a version this Mac can't read (\(release.version))"))
            }
            return .checkFailed(.init(.thisMac, "this Mac's installed version can't be read (\(installedVersion))"))
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
               ),
               isNewer(latest: release.version, current: installedVersion)
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
        case failed(UpdateCheckFailure)
    }

    /// How the release check asks the coordinator for its latest release, and how long it can take:
    /// - each try waits at most `requestTimeout` (15 s) for an answer, whatever the session's own bound (60 s for
    ///   `URLSession.shared`, 30 s for `watchdogURLSession()`);
    /// - only a try that failed on the way (`retries(after:)`) is made again, after a random pause from `backoff`
    ///   (0.5–1 s, then 1–2 s), so Macs that lost the coordinator at the same moment don't all ask again together;
    /// - at most `attempts` (3) tries in a round: a coordinator that never answers gets 3 requests, and the check ends
    ///   within about 48 s (3 × 15 s, and at most 3 s of pauses);
    /// - an answer is final, an HTTP error or a release for another platform included;
    /// - each failed try is logged, with how it connected (`log`).
    ///
    /// Every caller makes one round, but a pair's automatic cycle (`pairCycle`), at its update slot or catching up with
    /// the other Mac: a failed check there costs both Macs the slot, so it makes a second round 1–2 min later (at most
    /// 6 requests and about 3.6 min, inside the 15 min the other Mac waits). No caller asks again after a failed check,
    /// so nothing multiplies these tries: a background update ends its cycle there and asks at its next one (a single
    /// Mac 30 min later, a pair or a cluster member at its next update slot, the watchdog at the next restart it makes).
    struct ReleaseCheck: Sendable {
        var attempts = 3
        var requestTimeout: TimeInterval = 15
        var backoff = ExponentialBackoff(base: 1, max: 4)
        /// Rounds of `attempts` tries: a round that ends without an answer is followed by one more, after a pause from
        /// `roundPause`, `rounds` in all.
        var rounds = 1
        var roundPause: ClosedRange<TimeInterval> = 60...120
        var pause: @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        /// Draws each pause from its range.
        var random: @Sendable (ClosedRange<TimeInterval>) -> TimeInterval = { Double.random(in: $0) }
        /// Where a failed try is said: the process's log (the provider's, the cluster service's or the watchdog's), or
        /// standard error for a command, below its live line.
        var log: @Sendable (String) -> Void = { line in
            DarkbloomCommandLook.say(line) { releaseCheckLog.info("\($0)") }
        }
        /// A test's stand-in for what `next(after:tries:round:cancelled:)` decided after a failed try; nil outside tests.
        var nextForTesting: (@Sendable (Next) -> Next)? = nil

        static let standard = ReleaseCheck()
        static let pairCycle = ReleaseCheck(rounds: 2)

        /// Every try a check can make: `attempts` in each of its `rounds`.
        var maximumTries: Int { max(1, attempts) * max(1, rounds) }

        /// What follows a failed try.
        enum Next: Equatable, Sendable {
            case askAgain
            case nextRound
            case stop
        }

        /// After the `tries`-th failed try of round `round`: another try in this round, the next round, or none. Only a
        /// failure on the way is asked again, and nothing once the check was cancelled.
        func next(after error: Error, tries: Int, round: Int, cancelled: Bool) -> Next {
            guard !cancelled, Self.retries(after: error) else { return .stop }
            if tries < attempts { return .askAgain }
            return round < rounds ? .nextRound : .stop
        }

        /// A failure on the way, before any answer, that may not happen again: no answer in time, a connection lost or
        /// refused, a name that didn't resolve, no network, a TLS handshake that broke off. Never a cancellation.
        static func retries(after error: Error) -> Bool {
            guard let code = (error as? URLError)?.code else { return false }
            return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                    .notConnectedToInternet, .secureConnectionFailed].contains(code)
        }

        /// Why the check failed after `tries`, in the words `darkbloom update` prints.
        func failure(_ error: Error, tries: Int, coordinator: String) -> UpdateCheckFailure {
            let count = tries > 1 ? " (\(tries) tries)" : ""
            guard (error as? URLError)?.code != .timedOut else {
                return .init(.noAnswer, "\(coordinator) didn't answer within \(Int(requestTimeout.rounded(.up))) s\(count)")
            }
            return .init(.noAnswer, "couldn't reach \(coordinator)\(count): \(error.localizedDescription)")
        }
    }

    /// The coordinator as the check's words name it: its host, and port if any. Never its whole URL.
    private var coordinatorName: String {
        guard let url = URL(string: coordinatorBaseURL), let host = url.host else { return "the coordinator" }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    private func fetchLatestRelease() async -> LatestReleaseFetch {
        let endpoint = "\(coordinatorBaseURL)/v1/releases/latest?platform=macos-arm64"

        guard let url = URL(string: endpoint) else {
            return .failed(.init(.thisMac, "the coordinator URL isn't a valid URL"))
        }
        let coordinator = coordinatorName
        // The request's own timeout bounds each try, whatever the session's is.
        var request = URLRequest(url: url)
        request.timeoutInterval = releaseCheck.requestTimeout
        var backoff = releaseCheck.backoff
        var (tries, made, round) = (0, 0, 1)
        while true {
            tries += 1
            made += 1
            let started = ContinuousClock.now
            let connection = ReleaseCheckConnection()
            do {
                let (data, response) = try await urlSession.data(for: request, delegate: connection)
                return Self.latestRelease(data: data, response: response, coordinator: coordinator)
            } catch {
                let decided = releaseCheck.next(after: error, tries: tries, round: round, cancelled: Task.isCancelled)
                let next = releaseCheck.nextForTesting?(decided) ?? decided
                let pause: TimeInterval? = switch next {
                case .askAgain: Double.random(in: backoff.nextDelayRange())
                case .nextRound: Double.random(in: releaseCheck.roundPause)
                case .stop: nil
                }
                releaseCheck.log(failedTryLine(tries: tries, round: round, coordinator: coordinator,
                                               elapsed: ContinuousClock.now - started, error: error,
                                               connection: connection.summary, next: next, pause: pause))
                guard let pause else { return .failed(releaseCheck.failure(error, tries: made, coordinator: coordinator)) }
                if next == .nextRound {
                    round += 1
                    tries = 0
                    backoff = releaseCheck.backoff
                }
                await releaseCheck.pause(pause)
                // A cancellation during the pause (the process stops) is not followed by another request.
                if Task.isCancelled { return .failed(releaseCheck.failure(error, tries: made, coordinator: coordinator)) }
            }
        }
    }

    /// A failed try for the log: which try, where it got to (its connection's HTTP version, new or reused, direct or
    /// through a proxy, the address), the error's domain and code, and what follows. The host only, never the URL.
    private func failedTryLine(tries: Int, round: Int, coordinator: String, elapsed: Duration, error: Error,
                               connection: String, next: ReleaseCheck.Next, pause: TimeInterval?) -> String {
        let rounds = releaseCheck.rounds
        let which = "try \(tries) of \(releaseCheck.attempts)" + (rounds > 1 ? ", round \(round) of \(rounds)," : "")
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let failure = error as NSError
        let then = switch (next, pause) {
        case (.askAgain, let pause?): "asking again in \(String(format: "%.1f", pause)) s"
        case (.nextRound, let pause?): "asking again in \(Int(pause.rounded())) s, round \(round + 1) of \(rounds)"
        default: "giving up"
        }
        return "release check: \(which) to \(coordinator) failed after \(String(format: "%.1f", seconds)) s: "
            + "\(failure.domain) \(failure.code) (\(connection)); \(then)"
    }

    private static func latestRelease(data: Data, response: URLResponse, coordinator: String) -> LatestReleaseFetch {
        guard let httpResponse = response as? HTTPURLResponse else {
            return .failed(.init(.badAnswer, "\(coordinator) answered, but not over HTTP"))
        }

        guard httpResponse.statusCode == 200 else {
            return .failed(.init(.badAnswer, "\(coordinator) answered HTTP \(httpResponse.statusCode) instead of the latest release"))
        }

        let notARelease = "\(coordinator)'s answer isn't a release"
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return .failed(.init(.badAnswer, "\(notARelease): it isn't JSON"))
        }
        guard let json = object as? [String: Any] else {
            return .failed(.init(.badAnswer, "\(notARelease): it isn't a JSON object"))
        }

        guard let version = json["version"] as? String,
              let platform = json["platform"] as? String,
              let downloadURL = json["url"] as? String
        else {
            return .failed(.init(.badAnswer, "\(notARelease): it has no version, platform or download URL"))
        }
        guard platform == "macos-arm64" else {
            return .failed(.init(.badAnswer,
                "\(coordinator)'s latest release is for another platform (\(platform)), not this Mac's (macos-arm64)"))
        }
        guard let bundleHash = json["bundle_hash"] as? String else {
            return .failed(.init(.badAnswer, "\(coordinator)'s latest release has no bundle hash"))
        }

        return .release(ReleaseInfo(
            version: version,
            platform: platform,
            url: downloadURL,
            bundleHash: bundleHash,
            binaryHash: json["binary_hash"] as? String,
            metallibHash: json["metallib_hash"] as? String
        ))
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
            let computedHash = try UpdateAtomicFilesystem.sha256(file: tempFileURL)

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
        /// Extracted, verified `Darkbloom.app` inside `stagingRoot`.
        let extractedApp: URL
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
    /// flat `bin/` verifier copies. The .app bundle is the only installable
    /// artifact; a flat-only tarball (releases before the .app layout) is
    /// refused.
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
            verification: session.store.verifyCodeSignatures
                ? .production
                : .unverifiedTestFixture
        )
    }

    /// TEST-ONLY. Stages without signature verification so tests can use
    /// synthetic unsigned binaries. Never call from production — the production
    /// path is `stageBundle(from:release:session:)`, which derives verification
    /// from the session's store (always `true` for a production session).
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
        let stagingRoot = installDir.appendingPathComponent(
            "\(Self.stagingDirPrefix)\(UUID().uuidString)", isDirectory: true)

        do {
            try fm.createDirectory(at: installDir, withIntermediateDirectories: true)
            // Best-effort removal of staging/backup dirs orphaned by a crash
            // between stage and commit in an earlier process.
            removeStaleUpdateDirs(in: installDir)

            try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            try BoundedProcess.run(
                URL(fileURLWithPath: "/bin/sh"),
                // Release modes must not inherit a daemon's private-state umask.
                // Set it only in the child; keep tar's default ownership,
                // special-bit and archive-path safeguards (no -p or -P).
                arguments: [
                    "-c", "umask 022; exec /usr/bin/tar \"$@\"", "darkbloom-update-tar",
                    "xzf", downloadedFile.path, "-C", stagingRoot.path,
                ],
                timeout: Self.artifactVerificationTimeout)

            let identity = BuildEnvironment.current
            // Use the flat bin/ copies for hash verification (release hashes
            // are computed from the flat verifier copies). Their names are the
            // coordinator's release-artifact contract and do not change for a
            // dev build, whose app executable is darkbloom-dev.
            let flatDarkbloom = try requiredBundleFile(
                names: ["bin/darkbloom"],
                root: stagingRoot
            )
            let flatMetallib = try requiredBundleFile(
                names: ["bin/mlx.metallib"],
                root: stagingRoot
            )

            if let binaryHash = release.binaryHash {
                try verifyHash(file: flatDarkbloom, expected: binaryHash, label: "darkbloom")
            }
            if let metallibHash = release.metallibHash {
                try verifyHash(file: flatMetallib, expected: metallibHash, label: "mlx.metallib")
            }

            // The .app bundle is the canonical signed artifact; the flat
            // bin/ copies carry a bundle-contextual code signature that
            // fails codesign --verify when run standalone, causing macOS
            // to SIGKILL the process — they are verifier inputs only.
            let extractedApp = stagingRoot.appendingPathComponent(identity.appBundleName)
            guard fm.fileExists(atPath: extractedApp.path) else {
                throw UpdateError.replaceFailed(
                    "release bundle has no \(identity.appBundleName); flat-only bundles are no longer installable")
            }
            if let signaturePolicy = verification.codeSignaturePolicy {
                let appDarkbloom = extractedApp
                    .appendingPathComponent("Contents/MacOS/\(identity.cliName)")
                let appMetallib = extractedApp
                    .appendingPathComponent("Contents/MacOS/mlx.metallib")
                if let binaryHash = release.binaryHash {
                    try verifyHash(
                        file: appDarkbloom,
                        expected: binaryHash,
                        label: "\(identity.appBundleName) \(identity.cliName)"
                    )
                }
                if let metallibHash = release.metallibHash {
                    try verifyHash(
                        file: appMetallib,
                        expected: metallibHash,
                        label: "\(identity.appBundleName) mlx.metallib"
                    )
                }
                try verifyCodeSignature(
                    file: appDarkbloom,
                    label: identity.cliName,
                    policy: signaturePolicy
                )
                try verifyCodeSignature(
                    file: extractedApp,
                    label: identity.appBundleName,
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
            }

            let stagedTreeHash = try UpdateAtomicFilesystem.treeHash(root: extractedApp)
            return .success(StagedBundle(
                stagingRoot: stagingRoot,
                extractedApp: extractedApp,
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
            let currentTreeHash = try UpdateAtomicFilesystem.treeHash(
                root: staged.extractedApp)
            guard currentTreeHash == staged.stagedTreeHash else {
                return .failure(.replaceFailed(
                    "staged bundle changed after verification; refusing commit"))
            }
            if session.store.verifyCodeSignatures {
                let app = staged.extractedApp
                try verifyCodeSignature(
                    file: app,
                    label: BuildEnvironment.current.appBundleName,
                    deep: true
                )
                try FanHelperCapabilityVerifier.verify(
                    app: app,
                    executable: app.appendingPathComponent(
                        "Contents/MacOS/\(BuildEnvironment.current.cliName)"
                    ),
                    signaturePolicy: .darkbloomProduction
                )
            }
            try session.store.commit(
                staged: staged,
                currentVersion: currentVersion,
                now: now()
            )
            registerInstalledApp(
                session.store.installRoot.appendingPathComponent(BuildEnvironment.current.appBundleName),
                verified: session.store.verifyCodeSignatures)
            return .success(())
        } catch {
            return .failure(.replaceFailed("\(error)"))
        }
    }

    /// The swap leaves macOS LaunchServices describing the previous bundle,
    /// and App Attest reports `is_supported_false` until it is refreshed.
    /// Registering the new bundle before the relaunch keeps the record current.
    /// Best effort: a failed registration never fails the update.
    private func registerInstalledApp(_ app: URL, verified: Bool) {
        if let installedAppRegistrar {
            installedAppRegistrar(app)
        } else if verified {
            LaunchServicesRegistration.refresh(app)
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

    /// The release quarantined on this Mac, read without the lease as
    /// `checkForUpdate` reads it (the state file is replaced atomically); nil
    /// when none is, or the state cannot be read.
    public func quarantinedVersion() -> String? {
        recordedRecoveryState()?.quarantine?.version
    }

    /// The recovery state, read without the lease as `quarantinedVersion` reads it; nil when it cannot be read.
    public func recordedRecoveryState() -> UpdateRecoveryState? {
        try? recoveryStore()?.loadState()
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
        do {
            let processLock = try UpdateProcessLock.acquire(
                at: store.lockPath,
                operation: operation,
                timeout: timeout
            )
            return UpdateSession(processLock: processLock, store: store)
        } catch let error as UpdateProcessLock.LockError {
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
        // A bare binary outside an .app (e.g. a dev build in some bin/):
        // bin -> root
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

    /// TEST-ONLY. Installs without signature verification. Never call from
    /// production — production installs go through `update(session:...)` or
    /// `installBundle(from:release:session:)` with a signed session.
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
            verification: session.store.verifyCodeSignatures
                ? .production
                : .unverifiedTestFixture
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

        case .checkFailed(let failure):
            return .checkFailed(failure)

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
                defer { try? FileManager.default.removeItem(at: tempFile) }
                guard beforeInstall() else {
                    return .cancelled(
                        reason: "provider was intentionally stopped before install")
                }
                let replaceResult = installBundle(
                    from: tempFile,
                    release: release,
                    session: session
                )
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
    /// Prerelease identifiers participate in SemVer precedence; build metadata
    /// does not affect ordering.
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
        let got = try UpdateAtomicFilesystem.sha256(file: file)
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
        try PagedRuntimeCapabilityVerifier.verifyMarker(
            app: app,
            executable: executable,
            fileManager: fileManager)

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
        let callbackMarker = app.appendingPathComponent("Contents/Resources/darkbloom-runtime-capabilities/app-attest-callback-v1")
        if fileManager.fileExists(atPath: callbackMarker.path),
           !String(decoding: smokeOutput, as: UTF8.self).split(whereSeparator: \.isNewline).contains(Substring(AppAttestRuntimeSmoke.successMarker)) {
            throw UpdateError.replaceFailed("packaged App Attest callback runtime smoke omitted its success marker")
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

/// One try of the release check's connection, as `URLSessionTaskMetrics` reports it: for the log line of a try that
/// failed, which says whether it got an HTTP/2 or HTTP/3 connection, a new one or a reused one, through a proxy or not.
private final class ReleaseCheckConnection: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var transaction: URLSessionTaskTransactionMetrics?

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.withLock { transaction = metrics.transactionMetrics.last }
    }

    var summary: String {
        guard let transaction = lock.withLock({ transaction }) else { return "no connection details" }
        let address = transaction.remoteAddress.map { address in transaction.remotePort.map { "\(address):\($0)" } ?? address }
        return [transaction.networkProtocolName ?? "no HTTP version",
                transaction.isReusedConnection ? "reused connection" : "new connection",
                transaction.isProxyConnection ? "through a proxy" : "direct",
                address ?? "no address"].joined(separator: ", ")
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
