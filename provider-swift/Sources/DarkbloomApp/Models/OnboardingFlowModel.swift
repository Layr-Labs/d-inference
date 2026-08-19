import AppKit
import Foundation
import Observation
import ProviderCoreFoundation

@MainActor
@Observable
final class OnboardingFlowModel {
    var step: OnboardingStep { didSet { publishDraft() } }
    var readinessCompletedCount = 0 { didSet { publishDraft() } }
    var readinessPhase: ReadinessPhase = .checking { didSet { publishDraft() } }
    var readinessItems: [ReadinessEvaluation.Item] = []
    var accountPhase: AccountLinkPhase = .introduction { didSet { publishDraft() } }
    var enrollmentPhase: EnrollmentPhase = .overview { didSet { publishDraft() } }
    var enrollmentFailureDetail: String?
    var enrollmentProfilePath: String?
    var preparationPhase: PreparationPhase = .reservingSpace { didSet { publishDraft() } }
    var preparationProgress = 0.04 { didSet { publishDraft() } }
    var preparationChoices: [OnboardingModelChoice] = []
    var selectedModelID: String? { didSet { publishDraft() } }
    var downloadCompletedModelID: String? { didSet { publishDraft() } }
    var preparationFailureDetail: String?
    var providerStartCompleted = false
    var verificationPhase: VerificationPhase = .profileDetected { didSet { publishDraft() } }
    var isRestoredFromDraft = false
    var resumeReconciliationState: ResumeReconciliationState = .notNeeded
    var accountLinkSession: OnboardingAccountLinkSession
    var accountLinkRequestInFlight = false
    var accountLinkFailureDetail: String?
    var showsProfilePrivacyDetails = false

    @ObservationIgnored let freezesAutomaticProgress: Bool
    @ObservationIgnored let reconciliationOutcome: ResumeReconciliationOutcome
    @ObservationIgnored var operationRevision = 0
    @ObservationIgnored var accountLinkAttempt = 0
    @ObservationIgnored var immutableReadinessFailure: ReadinessPhase?
    @ObservationIgnored var conflictingManagementPersists = false
    @ObservationIgnored var isApplyingDraft = false
    @ObservationIgnored var onDraftChange: ((OnboardingDraft) -> Void)?

    @ObservationIgnored let diagnosticsRunner: (any DiagnosticsCLIRunning)?
    @ObservationIgnored let readinessFactsProvider: @Sendable () -> ReadinessMachineFacts
    @ObservationIgnored let accountLinkRunner: (any AccountLinkRunning)?
    @ObservationIgnored let enrollmentRunner: (any EnrollmentCLIRunning)?
    @ObservationIgnored let preparationService: (any OnboardingPreparationServicing)?
    @ObservationIgnored let verificationURLHandler: @MainActor (URL) -> Void
    @ObservationIgnored let providerEvidenceProvider: @Sendable () -> OnboardingProviderEvidence
    @ObservationIgnored let enrollmentPollInterval: Duration
    @ObservationIgnored let preparationEvidencePollInterval: Duration
    @ObservationIgnored let preparationEvidenceTimeout: Duration
    @ObservationIgnored let verificationPollInterval: Duration
    @ObservationIgnored let verificationCheckInGrace: Duration
    @ObservationIgnored var accountLinkTask: Task<Void, Never>?
    @ObservationIgnored var enrollmentPollTask: Task<Void, Never>?
    @ObservationIgnored var enrollmentPollSession: UUID?
    @ObservationIgnored var preparationTask: Task<Void, Never>?

    nonisolated static let readinessItemCount = 6
    nonisolated static let verificationItemCount = 4

    init(
        startingAt step: OnboardingStep = .readiness,
        previewVariant: String? = nil,
        freezesAutomaticProgress: Bool = false,
        reconciliationOutcome: ResumeReconciliationOutcome = .matched,
        accountLinkIssuedAt: Date = .now,
        diagnosticsRunner: (any DiagnosticsCLIRunning)? = ProcessDiagnosticsCLIRunner(),
        readinessFactsProvider: @escaping @Sendable () -> ReadinessMachineFacts = { .live },
        accountLinkRunner: (any AccountLinkRunning)? = ProcessAccountLinkCLI(),
        enrollmentRunner: (any EnrollmentCLIRunning)? = ProcessEnrollmentCLI(),
        preparationService: (any OnboardingPreparationServicing)? = OnboardingPreparationService(),
        verificationURLHandler: (@MainActor (URL) -> Void)? = nil,
        daemonStateProvider: (@Sendable () -> DaemonState?)? = nil,
        providerEvidenceProvider: (@Sendable () -> OnboardingProviderEvidence)? = nil,
        enrollmentPollInterval: Duration = .seconds(2),
        preparationEvidencePollInterval: Duration = .milliseconds(250),
        preparationEvidenceTimeout: Duration = .seconds(30),
        verificationPollInterval: Duration = .seconds(2),
        verificationCheckInGrace: Duration = .seconds(90)
    ) {
        self.step = step
        self.freezesAutomaticProgress = freezesAutomaticProgress
        self.reconciliationOutcome = reconciliationOutcome
        self.diagnosticsRunner = diagnosticsRunner
        self.readinessFactsProvider = readinessFactsProvider
        self.accountLinkRunner = accountLinkRunner
        self.enrollmentRunner = enrollmentRunner
        self.preparationService = preparationService
        self.verificationURLHandler = verificationURLHandler ?? { NSWorkspace.shared.open($0) }
        let daemonStateProvider = daemonStateProvider ?? { DaemonStateFile.read() }
        self.providerEvidenceProvider = providerEvidenceProvider ?? {
            OnboardingProviderEvidence(
                daemonState: daemonStateProvider(),
                localEndpoint: LocalEndpointDiscovery.readInfo()
            )
        }
        self.enrollmentPollInterval = enrollmentPollInterval
        self.preparationEvidencePollInterval = preparationEvidencePollInterval
        self.preparationEvidenceTimeout = preparationEvidenceTimeout
        self.verificationPollInterval = verificationPollInterval
        self.verificationCheckInGrace = verificationCheckInGrace
        accountLinkSession = .fixture(issuedAt: accountLinkIssuedAt, attempt: 0)
        readinessItems = Self.previewReadinessItems(completedCount: 0, phase: .checking)

        if freezesAutomaticProgress {
            applyPreview(OnboardingPreviewState(step: step, variant: previewVariant))
        }
    }

    var usesLiveReadiness: Bool { !freezesAutomaticProgress && diagnosticsRunner != nil }
    var usesLiveAccountLink: Bool { !freezesAutomaticProgress && accountLinkRunner != nil }
    var usesLiveEnrollment: Bool { !freezesAutomaticProgress && enrollmentRunner != nil }
    var usesLivePreparation: Bool { !freezesAutomaticProgress && preparationService != nil }
    var usesLiveVerification: Bool { !freezesAutomaticProgress }
    var verificationCompletedCount: Int { verificationPhase.completedMilestoneCount }

    var selectedPreparationChoice: OnboardingModelChoice? {
        guard let selectedModelID else { return nil }
        return preparationChoices.first { $0.id == selectedModelID }
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
            verificationPhase: verificationPhase,
            selectedModelID: selectedModelID,
            downloadCompletedModelID: downloadCompletedModelID
        )
    }

    func setDraftChangeHandler(_ handler: ((OnboardingDraft) -> Void)?) {
        onDraftChange = handler
    }

    func restore(from draft: OnboardingDraft) {
        let draft = draft.normalizedForResume
        cancelPendingOperations()
        isApplyingDraft = true
        step = draft.step
        readinessCompletedCount = draft.readinessCompletedCount
        readinessPhase = draft.readinessPhase
        readinessItems = Self.previewReadinessItems(
            completedCount: draft.readinessCompletedCount,
            phase: draft.readinessPhase
        )
        accountPhase = draft.accountPhase
        enrollmentPhase = draft.enrollmentPhase
        preparationPhase = draft.preparationPhase
        preparationProgress = draft.preparationProgress
        selectedModelID = draft.selectedModelID
        downloadCompletedModelID = draft.downloadCompletedModelID
        providerStartCompleted = false
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

    func resetForNewSetup() {
        cancelPendingOperations()
        isApplyingDraft = true
        step = .readiness
        readinessCompletedCount = 0
        readinessPhase = .checking
        readinessItems = Self.previewReadinessItems(completedCount: 0, phase: .checking)
        accountPhase = .introduction
        enrollmentPhase = .overview
        enrollmentFailureDetail = nil
        enrollmentProfilePath = nil
        preparationPhase = .reservingSpace
        preparationProgress = 0.04
        preparationChoices = []
        selectedModelID = nil
        downloadCompletedModelID = nil
        preparationFailureDetail = nil
        providerStartCompleted = false
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
        case .preparation:
            preparationPhase == .ready && (freezesAutomaticProgress || providerStartCompleted)
        case .verification: verificationPhase == .hardwareTrusted
            && (freezesAutomaticProgress || hasLiveVerifiedSelectedProvider())
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
        case .readiness:
            await runReadinessChecks()
        case .enrollment:
            if enrollmentPhase == .systemSettingsOpen || enrollmentPhase == .detectingProfile {
                startEnrollmentPolling()
            }
        case .preparation:
            if preparationPhase == .reservingSpace || preparationPhase == .loadingCatalog {
                await loadPreparationCatalog()
            }
        case .verification:
            await runVerification()
        case .account, .complete:
            break
        }
    }

    func continueToNextStep() {
        guard canContinue else { return }
        switch step {
        case .readiness: step = .account
        case .account: step = .enrollment
        case .enrollment: step = .preparation
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
        accountLinkTask?.cancel()
        accountLinkTask = nil
        accountLinkRequestInFlight = false
        enrollmentPollTask?.cancel()
        enrollmentPollTask = nil
        enrollmentPollSession = nil
        preparationTask?.cancel()
        preparationTask = nil
    }

    // MARK: - Account linking

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
        guard freezesAutomaticProgress, accountPhase == .waitingForApproval else { return }
        guard !accountLinkSession.isExpired(at: .now) else {
            accountPhase = .expired
            return
        }
        let revision = operationRevision
        accountPhase = .confirming
        guard await pause(.milliseconds(720)), revision == operationRevision else { return }
        accountPhase = .linked
    }

    func startAccountLink() {
        guard accountLinkTask == nil, !accountLinkRequestInFlight else { return }
        guard accountPhase == .introduction || accountPhase == .expired || accountPhase == .unreachable else {
            return
        }

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
            if let url = URL(string: verificationURI) { verificationURLHandler(url) }
        case .linked:
            accountLinkFailureDetail = nil
            accountPhase = .linked
        case let .error(message):
            applyAccountLinkError(message)
        }
    }

    private func applyAccountLinkError(_ message: String) {
        if message.hasPrefix("Already logged in") {
            accountLinkFailureDetail = nil
            accountPhase = .linked
        } else {
            accountLinkFailureDetail = message
            accountPhase = message.contains("expired") ? .expired : .unreachable
        }
    }

    // MARK: - Shared helpers

    func pause(_ duration: Duration) async -> Bool {
        do {
            try await Task.sleep(for: duration)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    func publishDraft() {
        guard !isApplyingDraft else { return }
        onDraftChange?(draft)
    }

    func applyPreview(_ preview: OnboardingPreviewState) {
        readinessCompletedCount = preview.readinessCompletedCount
        readinessPhase = preview.readinessPhase
        readinessItems = Self.previewReadinessItems(
            completedCount: preview.readinessCompletedCount,
            phase: preview.readinessPhase
        )
        accountPhase = preview.accountPhase
        enrollmentPhase = preview.enrollmentPhase
        preparationPhase = preview.preparationPhase
        preparationProgress = preview.preparationProgress
        providerStartCompleted = preview.preparationPhase == .ready
        downloadCompletedModelID = preview.preparationPhase == .ready ? selectedModelID : nil
        verificationPhase = preview.verificationPhase
        immutableReadinessFailure = switch preview.readinessPhase {
        case .unsupportedMac, .insufficientMemory: preview.readinessPhase
        default: nil
        }
        conflictingManagementPersists = preview.enrollmentPhase == .conflictingManagement
    }

    nonisolated static func previewReadinessItems(
        completedCount: Int,
        phase: ReadinessPhase
    ) -> [ReadinessEvaluation.Item] {
        let definitions = [
            ("apple-silicon", "Apple silicon", "Apple silicon is required"),
            ("supported-macos", "macOS", "Sonoma or later"),
            ("secure-enclave", "Secure Enclave", "Available for private identity"),
            ("unified-memory", "Unified memory", "8 GB minimum"),
            ("available-storage", "Available storage", "Exact model size is checked before download"),
            ("boot-security", "Boot security", "SIP and authenticated root"),
        ]
        return definitions.enumerated().map { index, definition in
            let state: SetupItemState
            if phase.issueItemIndex == index {
                state = phase == .lowStorage ? .advisory : .issue
            } else if index < completedCount {
                state = .complete
            } else if phase == .checking, index == completedCount {
                state = .working
            } else {
                state = .waiting
            }
            return ReadinessEvaluation.Item(
                id: definition.0,
                title: definition.1,
                detail: definition.2,
                action: nil,
                state: state,
                doctorCheckIDs: []
            )
        }
    }
}
