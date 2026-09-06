import Foundation

/// Persisted UI-only progress for setup. This intentionally contains no account
/// identifiers, profile payloads, authorization codes, or model file paths.
struct OnboardingDraft: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 4
    private static let readinessItemCount = 6
    private static let verificationItemCount = 4

    var schemaVersion: Int
    var step: OnboardingStep
    var readinessCompletedCount: Int
    var readinessPhase: ReadinessPhase
    var accountPhase: AccountLinkPhase
    var enrollmentPhase: EnrollmentPhase
    var preparationPhase: PreparationPhase
    var preparationProgress: Double
    var selectedModelID: String?
    var downloadCompletedModelID: String?
    var verificationPhase: VerificationPhase

    /// Retained as a computed compatibility surface for older tests and encoded
    /// drafts. New UI logic is driven by the explicit verification phase.
    var verificationCompletedCount: Int {
        verificationPhase.completedMilestoneCount
    }

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        step: OnboardingStep,
        readinessCompletedCount: Int,
        accountPhase: AccountLinkPhase,
        enrollmentPhase: EnrollmentPhase,
        preparationPhase: PreparationPhase,
        preparationProgress: Double,
        verificationCompletedCount: Int,
        readinessPhase: ReadinessPhase? = nil,
        verificationPhase: VerificationPhase? = nil,
        selectedModelID: String? = nil,
        downloadCompletedModelID: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.step = step
        self.readinessCompletedCount = readinessCompletedCount
        self.readinessPhase = readinessPhase
            ?? (readinessCompletedCount >= Self.readinessItemCount ? .ready : .checking)
        self.accountPhase = accountPhase
        self.enrollmentPhase = enrollmentPhase
        self.preparationPhase = preparationPhase
        self.preparationProgress = preparationProgress
        self.selectedModelID = selectedModelID
        self.downloadCompletedModelID = downloadCompletedModelID
        self.verificationPhase = verificationPhase
            ?? VerificationPhase(legacyCompletedCount: verificationCompletedCount)
    }

    var isSupported: Bool {
        (1 ... Self.currentSchemaVersion).contains(schemaVersion)
    }

    var progressLabel: String {
        "Step \(step.progressOrdinal) of 5 · \(step.resumeTitle)"
    }

    /// Transient work cannot safely continue after a process exit. Normalize it
    /// to a user-actionable point; the flow still performs a reconciliation pass
    /// before allowing restored progress to advance.
    var normalizedForResume: Self {
        var result = self
        result.schemaVersion = Self.currentSchemaVersion
        result.readinessCompletedCount = min(
            Self.readinessItemCount,
            max(0, readinessCompletedCount)
        )
        result.preparationProgress = min(1, max(0.04, preparationProgress))

        if result.accountPhase == .confirming {
            result.accountPhase = .waitingForApproval
        }
        if result.enrollmentPhase == .detectingProfile {
            result.enrollmentPhase = .systemSettingsOpen
        }
        if result.enrollmentPhase == .requestingProfile {
            result.enrollmentPhase = .overview
        }
        if result.verificationPhase == .enrollmentPending
            || result.verificationPhase == .trustPending
        {
            result.verificationPhase = .profileDetected
        }

        if result.preparationPhase == .downloading || result.preparationPhase == .verifying {
            result.preparationPhase = .downloadFailed
            result.preparationProgress = min(result.preparationProgress, 0.99)
            result.downloadCompletedModelID = nil
        } else if result.preparationPhase == .startingProvider || result.preparationPhase == .ready {
            result.preparationPhase = .startFailed
            result.preparationProgress = 1
            result.downloadCompletedModelID = result.downloadCompletedModelID ?? result.selectedModelID
        } else if result.preparationPhase == .downloadFailed {
            result.preparationProgress = min(result.preparationProgress, 0.81)
        } else if result.preparationPhase == .reservingSpace || result.preparationPhase == .loadingCatalog {
            result.preparationPhase = .reservingSpace
        } else if result.preparationPhase != .choosingModel
            && result.preparationPhase != .catalogFailed
            && result.preparationPhase != .noCompatibleModel
            && result.preparationPhase != .startFailed {
            switch result.preparationProgress {
            case ..<0.18: result.preparationPhase = .reservingSpace
            case ..<0.82: result.preparationPhase = .downloading
            default: result.preparationPhase = .verifying
            }
        }
        if result.preparationPhase == .startFailed, result.preparationProgress == 1 {
            result.downloadCompletedModelID = result.downloadCompletedModelID ?? result.selectedModelID
        }

        if result.step != .readiness {
            result.readinessCompletedCount = Self.readinessItemCount
            result.readinessPhase = .ready
        }
        if result.step == .enrollment || result.step == .verification || result.step == .complete {
            result.accountPhase = .linked
        }
        if result.step == .verification || result.step == .complete {
            result.enrollmentPhase = .profileDetected
        }
        if result.step == .complete {
            result.verificationPhase = .hardwareTrusted
        }

        return result
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case step
        case readinessCompletedCount
        case readinessPhase
        case accountPhase
        case enrollmentPhase
        case preparationPhase
        case preparationProgress
        case verificationPhase
        case verificationCompletedCount
        case selectedModelID
        case downloadCompletedModelID
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        step = try values.decode(OnboardingStep.self, forKey: .step)
        readinessCompletedCount = try values.decodeIfPresent(
            Int.self,
            forKey: .readinessCompletedCount
        ) ?? 0
        readinessPhase = try values.decodeIfPresent(ReadinessPhase.self, forKey: .readinessPhase)
            ?? (readinessCompletedCount >= Self.readinessItemCount ? .ready : .checking)
        accountPhase = try values.decode(AccountLinkPhase.self, forKey: .accountPhase)
        enrollmentPhase = try values.decode(EnrollmentPhase.self, forKey: .enrollmentPhase)
        preparationPhase = try values.decode(PreparationPhase.self, forKey: .preparationPhase)
        preparationProgress = try values.decode(Double.self, forKey: .preparationProgress)
        selectedModelID = try values.decodeIfPresent(String.self, forKey: .selectedModelID)
        downloadCompletedModelID = try values.decodeIfPresent(
            String.self,
            forKey: .downloadCompletedModelID
        )
        let legacyCount = try values.decodeIfPresent(
            Int.self,
            forKey: .verificationCompletedCount
        ) ?? 0
        verificationPhase = try values.decodeIfPresent(
            VerificationPhase.self,
            forKey: .verificationPhase
        ) ?? VerificationPhase(legacyCompletedCount: legacyCount)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(step, forKey: .step)
        try values.encode(readinessCompletedCount, forKey: .readinessCompletedCount)
        try values.encode(readinessPhase, forKey: .readinessPhase)
        try values.encode(accountPhase, forKey: .accountPhase)
        try values.encode(enrollmentPhase, forKey: .enrollmentPhase)
        try values.encode(preparationPhase, forKey: .preparationPhase)
        try values.encode(preparationProgress, forKey: .preparationProgress)
        try values.encodeIfPresent(selectedModelID, forKey: .selectedModelID)
        try values.encodeIfPresent(downloadCompletedModelID, forKey: .downloadCompletedModelID)
        try values.encode(verificationPhase, forKey: .verificationPhase)
        try values.encode(verificationCompletedCount, forKey: .verificationCompletedCount)
    }
}
