import Foundation
import Observation

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
    var showsProfilePrivacyDetails = false

    @ObservationIgnored private let freezesAutomaticProgress: Bool
    @ObservationIgnored private let reconciliationOutcome: ResumeReconciliationOutcome
    @ObservationIgnored private var operationRevision = 0
    @ObservationIgnored private var accountLinkAttempt = 0
    @ObservationIgnored private var immutableReadinessFailure: ReadinessPhase?
    @ObservationIgnored private var conflictingManagementPersists = false
    @ObservationIgnored private var isApplyingDraft = false
    @ObservationIgnored private var onDraftChange: ((OnboardingDraft) -> Void)?

    nonisolated static let readinessItemCount = 6
    nonisolated static let verificationItemCount = 4
    init(
        startingAt step: OnboardingStep = .readiness,
        previewVariant: String? = nil,
        freezesAutomaticProgress: Bool = false,
        reconciliationOutcome: ResumeReconciliationOutcome = .matched,
        accountLinkIssuedAt: Date = .now
    ) {
        self.step = step
        self.freezesAutomaticProgress = freezesAutomaticProgress
        self.reconciliationOutcome = reconciliationOutcome
        accountLinkSession = .fixture(issuedAt: accountLinkIssuedAt, attempt: 0)

        if freezesAutomaticProgress {
            applyPreview(OnboardingPreviewState(step: step, variant: previewVariant))
        }
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

    private func runVerification() async {
        guard verificationPhase == .profileDetected
            || verificationPhase == .enrollmentPending
            || verificationPhase == .trustPending
        else { return }
        let revision = operationRevision
        if verificationPhase == .profileDetected {
            guard await pause(.milliseconds(340)), revision == operationRevision else { return }
            verificationPhase = .enrollmentPending
        }
        if verificationPhase == .enrollmentPending {
            guard await pause(.milliseconds(620)), revision == operationRevision else { return }
            verificationPhase = .trustPending
        }
        if verificationPhase == .trustPending {
            guard await pause(.milliseconds(620)), revision == operationRevision else { return }
            verificationPhase = .hardwareTrusted
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
