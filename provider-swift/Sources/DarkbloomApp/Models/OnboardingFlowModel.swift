import AppKit
import Foundation
import Observation
import ProviderCoreFoundation

@MainActor
@Observable
final class OnboardingFlowModel {
    private(set) var step: OnboardingStep { didSet { publishDraft() } }
    private(set) var readinessCompletedCount = 0 { didSet { publishDraft() } }
    private(set) var readinessPhase: ReadinessPhase = .checking { didSet { publishDraft() } }
    private(set) var accountPhase: AccountLinkPhase = .introduction { didSet { publishDraft() } }
    private(set) var enrollmentPhase: EnrollmentPhase = .overview { didSet { publishDraft() } }
    private(set) var preparationPhase: PreparationPhase = .reservingSpace { didSet { publishDraft() } }
    private(set) var preparationProgress = 0.04 { didSet { publishDraft() } }
    private(set) var verificationPhase: VerificationPhase = .profileDetected { didSet { publishDraft() } }
    private(set) var isRestoredFromDraft = false
    private(set) var resumeReconciliationState: ResumeReconciliationState = .notNeeded
    private(set) var accountLinkSession: OnboardingAccountLinkSession
    /// Ephemeral (not persisted in the draft): a live link attempt is in
    /// flight (code requested through terminal event) — the view renders
    /// the introduction phase's button as disabled/working while this is true.
    private(set) var accountLinkRequestInFlight = false
    /// Ephemeral: the terminal `.error` from the last live link attempt (a
    /// `DeviceAuthError` description), rendered next to the retry actions.
    private(set) var accountLinkFailureDetail: String?
    var showsProfilePrivacyDetails = false

    @ObservationIgnored private let freezesAutomaticProgress: Bool
    @ObservationIgnored private let reconciliationOutcome: ResumeReconciliationOutcome
    @ObservationIgnored private var operationRevision = 0
    @ObservationIgnored private var accountLinkAttempt = 0
    @ObservationIgnored private var immutableReadinessFailure: ReadinessPhase?
    @ObservationIgnored private var conflictingManagementPersists = false
    @ObservationIgnored private var isApplyingDraft = false
    @ObservationIgnored private var onDraftChange: ((OnboardingDraft) -> Void)?

    // Live seams (slice: real account linking + real verification gating).
    // All default to production implementations so `DarkbloomApp.swift`
    // wiring is unchanged; tests inject fakes/temp files.
    /// The `darkbloom login --json` subprocess adapter driving account steps.
    @ObservationIgnored private let accountLinkRunner: (any AccountLinkRunning)?
    /// Deeplinks the coordinator's verification URL. Default: the system
    /// browser via NSWorkspace. Injected in tests.
    @ObservationIgnored private let verificationURLHandler: @MainActor (URL) -> Void
    /// Reads the daemon's on-disk truth for the verification gate. Default:
    /// the real `~/.darkbloom/daemon-state.json` via DaemonStateFile.read.
    @ObservationIgnored private let daemonStateProvider: @Sendable () -> DaemonState?
    @ObservationIgnored private let verificationPollInterval: Duration
    /// How long verification waits for a FIRST server check-in before marking
    /// `.checkInDelayed` (it keeps polling after — the phase is advisory).
    @ObservationIgnored private let verificationCheckInGrace: Duration
    @ObservationIgnored private var accountLinkTask: Task<Void, Never>?

    nonisolated static let readinessItemCount = 6
    nonisolated static let verificationItemCount = 4
    init(
        startingAt step: OnboardingStep = .readiness,
        previewVariant: String? = nil,
        freezesAutomaticProgress: Bool = false,
        reconciliationOutcome: ResumeReconciliationOutcome = .matched,
        accountLinkIssuedAt: Date = .now,
        accountLinkRunner: (any AccountLinkRunning)? = ProcessAccountLinkCLI(),
        verificationURLHandler: (@MainActor (URL) -> Void)? = nil,
        daemonStateProvider: (@Sendable () -> DaemonState?)? = nil,
        verificationPollInterval: Duration = .seconds(2),
        verificationCheckInGrace: Duration = .seconds(90)
    ) {
        self.step = step
        self.freezesAutomaticProgress = freezesAutomaticProgress
        self.reconciliationOutcome = reconciliationOutcome
        self.accountLinkRunner = accountLinkRunner
        self.verificationURLHandler = verificationURLHandler ?? { NSWorkspace.shared.open($0) }
        self.daemonStateProvider = daemonStateProvider ?? { DaemonStateFile.read() }
        self.verificationPollInterval = verificationPollInterval
        self.verificationCheckInGrace = verificationCheckInGrace
        accountLinkSession = .fixture(issuedAt: accountLinkIssuedAt, attempt: 0)

        if freezesAutomaticProgress {
            applyPreview(OnboardingPreviewState(step: step, variant: previewVariant))
        }
    }

    /// Whether the account step drives a real `darkbloom login --json`
    /// attempt (vs. the fully simulated fixture path used by previews and
    /// design captures).
    var usesLiveAccountLink: Bool {
        !freezesAutomaticProgress && accountLinkRunner != nil
    }

    /// Whether the verification step polls the real daemon state file (vs.
    /// the frozen preview phases). Gated only on `freezesAutomaticProgress`:
    /// the default `daemonStateProvider` is the real reader.
    var usesLiveVerification: Bool {
        !freezesAutomaticProgress
    }

    var verificationCompletedCount: Int {
        verificationPhase.completedMilestoneCount
    }

    var draft: OnboardingDraft {
        OnboardingDraft(
            step: step,
            readinessCompletedCount: readinessCompletedCount,
            accountPhase: accountPhase,
            enrollmentPhase: enrollmentPhase,
            preparationPhase: preparationPhase,
            preparationProgress: preparationProgress,
            verificationCompletedCount: verificationCompletedCount,
            readinessPhase: readinessPhase,
            verificationPhase: verificationPhase
        )
    }

    func setDraftChangeHandler(_ handler: ((OnboardingDraft) -> Void)?) {
        onDraftChange = handler
    }
    func restore(from draft: OnboardingDraft) {
        let draft = draft.normalizedForResume
        isApplyingDraft = true
        step = draft.step
        readinessCompletedCount = draft.readinessCompletedCount
        readinessPhase = draft.readinessPhase
        accountPhase = draft.accountPhase
        enrollmentPhase = draft.enrollmentPhase
        preparationPhase = draft.preparationPhase
        preparationProgress = draft.preparationProgress
        verificationPhase = draft.verificationPhase
        immutableReadinessFailure = switch draft.readinessPhase {
        case .unsupportedMac, .insufficientMemory: draft.readinessPhase
        default: nil
        }
        conflictingManagementPersists = draft.enrollmentPhase == .conflictingManagement
        isRestoredFromDraft = true
        resumeReconciliationState = .required
        isApplyingDraft = false
    }

    func requireResumeReconciliation() {
        isRestoredFromDraft = true
        resumeReconciliationState = .required
    }

    func reconcileRestoredProgress() async {
        guard resumeReconciliationState == .required || resumeReconciliationState == .rechecking else {
            return
        }
        let revision = operationRevision
        resumeReconciliationState = .rechecking
        guard await pause(.milliseconds(760)) else {
            if revision == operationRevision { resumeReconciliationState = .required }
            return
        }
        guard revision == operationRevision else { return }
        applyReconciliationOutcome()
    }

    func resetForNewSetup() {
        cancelPendingOperations()
        isApplyingDraft = true
        step = .readiness
        readinessCompletedCount = 0
        readinessPhase = .checking
        accountPhase = .introduction
        enrollmentPhase = .overview
        preparationPhase = .reservingSpace
        preparationProgress = 0.04
        verificationPhase = .profileDetected
        immutableReadinessFailure = nil
        conflictingManagementPersists = false
        showsProfilePrivacyDetails = false
        isRestoredFromDraft = false
        resumeReconciliationState = .notNeeded
        accountLinkSession = .fixture(issuedAt: .now, attempt: 0)
        accountLinkFailureDetail = nil
        accountLinkRequestInFlight = false
        isApplyingDraft = false
        publishDraft()
    }

    var canContinue: Bool {
        guard !resumeReconciliationState.blocksProgress else { return false }
        return switch step {
        case .readiness: readinessPhase.allowsContinuation
        case .account: accountPhase == .linked
        case .enrollment: enrollmentPhase == .profileDetected
        case .preparation: preparationPhase == .ready
        case .verification: verificationPhase == .hardwareTrusted
        case .complete: false
        }
    }

    var fieldFocus: CGFloat {
        [0.08, 0.18, 0.36, 0.56, 0.72, 0.92][step.rawValue]
    }

    var fieldActivity: CGFloat {
        switch step {
        case .readiness: readinessPhase.allowsContinuation ? 0.24 : 0.12
        case .account: accountPhase == .linked ? 0.3 : 0.2
        case .enrollment: enrollmentPhase == .profileDetected ? 0.45 : 0.28
        case .preparation: 0.55 + preparationProgress * 0.26
        case .verification: 0.7 + CGFloat(verificationCompletedCount) * 0.06
        case .complete: 1
        }
    }

    func runAutomaticWorkForCurrentStep() async {
        guard !freezesAutomaticProgress, !resumeReconciliationState.blocksProgress else { return }
        switch step {
        case .readiness: await runReadinessChecks()
        case .verification: await runVerification()
        case .account, .enrollment, .preparation, .complete: break
        }
    }

    func continueToNextStep() {
        guard canContinue else { return }
        switch step {
        case .readiness: step = .account
        case .account: step = .enrollment
        case .enrollment: step = .verification
        case .preparation: step = .verification
        case .verification: step = .complete
        case .complete: break
        }
    }

    @discardableResult
    func goBack() -> Bool {
        guard let previous = step.previous else { return false }
        cancelPendingOperations()
        step = previous
        return true
    }

    func cancelPendingOperations() {
        operationRevision &+= 1
        // Kill a live link attempt too: cancelling the consuming task ends
        // the AsyncThrowingStream iteration, whose onTermination terminates
        // the `darkbloom login` child process.
        accountLinkTask?.cancel()
        accountLinkTask = nil
        accountLinkRequestInFlight = false
    }
    func showAccountApproval(at date: Date = .now) {
        accountLinkSession = .fixture(issuedAt: date, attempt: accountLinkAttempt)
        accountPhase = .waitingForApproval
    }
    func retryAccountLink(at date: Date = .now) {
        accountLinkAttempt += 1
        accountLinkSession = .fixture(issuedAt: date, attempt: accountLinkAttempt)
        accountPhase = .waitingForApproval
    }
    func confirmAccountApproval() async {
        guard accountPhase == .waitingForApproval else { return }
        guard !accountLinkSession.isExpired(at: .now) else {
            accountPhase = .expired
            return
        }
        let revision = operationRevision
        accountPhase = .confirming
        guard await pause(.milliseconds(720)), revision == operationRevision else { return }
        accountPhase = .linked
    }

    // MARK: - Live account linking (real `darkbloom login --json`)

    /// The account step's primary action.
    ///
    /// Simulated→real boundary: frozen previews keep the fixture path
    /// (`showAccountApproval` / `retryAccountLink`) untouched. Live runs spawn
    /// ONE `darkbloom login --json` attempt per call and drive phases from
    /// its NDJSON event stream — the code shown is coordinator-issued, the
    /// verification URL deeplinks automatically, expiry follows the
    /// coordinator's `expires_in`, and `accountPhase == .linked` is now only
    /// reachable from a real terminal `.linked` event (or a pre-existing
    /// login). `AppFlowStore`'s completion gating is otherwise unchanged: the
    /// phase predicate stays the single source of truth.
    func startAccountLink() {
        guard accountLinkTask == nil, !accountLinkRequestInFlight else { return }
        guard accountPhase == .introduction
            || accountPhase == .expired
            || accountPhase == .unreachable
        else { return }

        if freezesAutomaticProgress {
            switch accountPhase {
            case .introduction: showAccountApproval()
            default: retryAccountLink()
            }
            return
        }
        guard let accountLinkRunner else { return }

        accountLinkAttempt += 1
        accountLinkFailureDetail = nil
        accountLinkRequestInFlight = true
        accountLinkTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.accountLinkTask = nil
                self.accountLinkRequestInFlight = false
            }
            do {
                for try await event in accountLinkRunner.linkEvents() {
                    if Task.isCancelled { break }
                    self.handleAccountLink(event)
                    if event.isTerminal { return }
                }
                // The stream ended without a terminal event (child died
                // silently): the outcome is unknown — surface it as a
                // retryable failure instead of spinning forever.
                guard !Task.isCancelled else { return }
                self.applyAccountLinkError("The login helper exited before the account was linked.")
            } catch {
                guard !Task.isCancelled else { return }
                self.applyAccountLinkError(error.localizedDescription)
            }
        }
    }

    private func handleAccountLink(_ event: AccountLinkEvent) {
        switch event {
        case let .code(userCode, verificationURI, expiresIn):
            accountLinkSession = .live(
                code: userCode,
                verificationURI: verificationURI,
                issuedAt: .now,
                expiresIn: expiresIn
            )
            accountLinkFailureDetail = nil
            accountPhase = .waitingForApproval
            if let url = URL(string: verificationURI) {
                verificationURLHandler(url)
            }
        case .linked:
            accountLinkFailureDetail = nil
            accountPhase = .linked
        case let .error(message):
            applyAccountLinkError(message)
        }
    }

    /// Maps the terminal `.error` message (a stable, user-facing
    /// `DeviceAuthError.description` from ProviderCore) onto the step's phase
    /// vocabulary.
    private func applyAccountLinkError(_ message: String) {
        if message.hasPrefix("Already logged in") {
            // The machine is already linked (e.g. a previous `darkbloom
            // login`): the account step's requirement is satisfied, exactly
            // as if this attempt had succeeded.
            accountLinkFailureDetail = nil
            accountPhase = .linked
        } else {
            accountLinkFailureDetail = message
            accountPhase = message.contains("expired") ? .expired : .unreachable
        }
    }

    func showEnrollmentInstructions() { enrollmentPhase = .instructions }
    func markSystemSettingsOpened() {
        guard enrollmentPhase == .instructions || enrollmentPhase == .systemSettingsOpen else { return }
        enrollmentPhase = .systemSettingsOpen
    }

    func confirmProfileInstallation() async {
        guard enrollmentPhase == .systemSettingsOpen || enrollmentPhase == .instructions else { return }
        await detectProfile()
    }

    func retryProfileDetection() async { await detectProfile() }
    func reopenSystemSettings() { enrollmentPhase = .systemSettingsOpen }
    func downloadProfileAgain() {
        guard !conflictingManagementPersists else { return }
        enrollmentPhase = .instructions
    }
    func retryReadinessChecks() async {
        readinessCompletedCount = 0
        readinessPhase = .checking
        if let immutableReadinessFailure {
            let revision = operationRevision
            guard await pause(.milliseconds(240)), revision == operationRevision else { return }
            readinessCompletedCount = immutableReadinessFailure.issueItemIndex ?? 0
            readinessPhase = immutableReadinessFailure
            return
        }
        await runReadinessChecks()
    }

    func previewPreparationRetry() {
        preparationProgress = 1
        preparationPhase = .ready
    }

    func retryVerification() async {
        verificationPhase = .profileDetected
        await runVerification()
    }
    func returnToEnrollmentForSettings() {
        enrollmentPhase = .systemSettingsOpen
        step = .enrollment
    }

    func returnToEnrollmentForDownload() {
        enrollmentPhase = .instructions
        step = .enrollment
    }

    func returnToReadinessForSystemCheck() {
        readinessCompletedCount = 0
        readinessPhase = .checking
        step = .readiness
    }

    private func detectProfile() async {
        let revision = operationRevision
        enrollmentPhase = .detectingProfile
        guard await pause(.milliseconds(760)), revision == operationRevision else { return }
        enrollmentPhase = conflictingManagementPersists ? .conflictingManagement : .profileDetected
    }

    private func runReadinessChecks() async {
        guard readinessPhase == .checking else { return }
        let revision = operationRevision
        while readinessCompletedCount < Self.readinessItemCount {
            guard await pause(.milliseconds(240)), revision == operationRevision else { return }
            readinessCompletedCount += 1
        }
        readinessPhase = .ready
    }

    /// Verification gate: profile accepted → hardware trust pending →
    /// verified, driven by REAL coordinator trust as mirrored into
    /// `daemon-state.json` by the running daemon (`DaemonStateFile.read` via
    /// the injected `daemonStateProvider`), NOT by timers. The trust
    /// status/level vocabulary is `DaemonSnapshotMapping`'s (see
    /// `OnboardingTrustGating`). Polls until a terminal verdict
    /// (`.hardwareTrusted` / `.trustFailed` / `.offline`) or cancellation;
    /// `.checkInDelayed` is advisory and self-heals — polling continues.
    private func runVerification() async {
        guard verificationPhase == .profileDetected
            || verificationPhase == .enrollmentPending
            || verificationPhase == .trustPending
        else { return }
        let revision = operationRevision
        if verificationPhase == .profileDetected {
            verificationPhase = .enrollmentPending
        }
        let checkInDelayedAt = ContinuousClock.now + verificationCheckInGrace
        while revision == operationRevision, !Task.isCancelled {
            if let trust = daemonStateProvider()?.trust {
                switch OnboardingTrustGating.verdict(for: trust) {
                case .verified:
                    verificationPhase = .hardwareTrusted
                    return
                case .refused:
                    verificationPhase = .trustFailed
                    return
                case .offline:
                    verificationPhase = .offline
                    return
                case .pending:
                    // Any trust record means the MDM server check-in
                    // happened; only the trust verdict is outstanding.
                    if verificationPhase != .trustPending {
                        verificationPhase = .trustPending
                    }
                }
            } else if verificationPhase == .enrollmentPending,
                      ContinuousClock.now >= checkInDelayedAt {
                // Keep polling after marking: a late check-in self-heals
                // into .trustPending without user action.
                verificationPhase = .checkInDelayed
            }
            guard await pause(verificationPollInterval), revision == operationRevision else { return }
        }
    }

    private func pause(_ duration: Duration) async -> Bool {
        do {
            try await Task.sleep(for: duration)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private func publishDraft() {
        guard !isApplyingDraft else { return }
        onDraftChange?(draft)
    }

    private func applyReconciliationOutcome() {
        switch reconciliationOutcome {
        case .matched:
            resumeReconciliationState = .reconciled
        case .accountLinkRequired:
            step = .account
            accountPhase = .introduction
            resumeReconciliationState = .reconciled
        case .profileMissing:
            step = .enrollment
            conflictingManagementPersists = false
            enrollmentPhase = .profileMissing
            resumeReconciliationState = .reconciled
        case .trustRequired:
            step = .verification
            verificationPhase = .trustFailed
            resumeReconciliationState = .reconciled
        case .unavailable:
            resumeReconciliationState = .unavailable
        }
    }

    private func applyPreview(_ preview: OnboardingPreviewState) {
        readinessCompletedCount = preview.readinessCompletedCount
        readinessPhase = preview.readinessPhase
        accountPhase = preview.accountPhase
        enrollmentPhase = preview.enrollmentPhase
        preparationPhase = preview.preparationPhase
        preparationProgress = preview.preparationProgress
        verificationPhase = preview.verificationPhase
        immutableReadinessFailure = switch preview.readinessPhase {
        case .unsupportedMac, .insufficientMemory: preview.readinessPhase
        default: nil
        }
        conflictingManagementPersists = preview.enrollmentPhase == .conflictingManagement
    }
}
