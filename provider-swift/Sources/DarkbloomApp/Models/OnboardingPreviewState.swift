import Foundation

struct OnboardingPreviewState: Equatable, Sendable {
    let readinessCompletedCount: Int
    let readinessPhase: ReadinessPhase
    let accountPhase: AccountLinkPhase
    let enrollmentPhase: EnrollmentPhase
    let preparationPhase: PreparationPhase
    let preparationProgress: Double
    let verificationPhase: VerificationPhase

    init(step: OnboardingStep, variant: String?) {
        let variant = variant?.lowercased()
        var readinessCount = 0
        var readiness: ReadinessPhase = .checking
        var account: AccountLinkPhase = .introduction
        var enrollment: EnrollmentPhase = .overview
        var preparation: PreparationPhase = .reservingSpace
        var progress = 0.04
        var verification: VerificationPhase = .profileDetected

        switch step {
        case .readiness:
            switch variant {
            case "unsupported": readiness = .unsupportedMac
            case "low-memory": readinessCount = 3; readiness = .insufficientMemory
            case "low-storage": readinessCount = OnboardingFlowModel.readinessItemCount; readiness = .lowStorage
            case "offline": readinessCount = 5; readiness = .offline
            case "working": readinessCount = 3
            default: readinessCount = OnboardingFlowModel.readinessItemCount; readiness = .ready
            }
        case .account:
            switch variant {
            case "linked": account = .linked
            case "expired": account = .expired
            case "unreachable": account = .unreachable
            case "introduction": account = .introduction
            default: account = .waitingForApproval
            }
        case .enrollment:
            switch variant {
            case "overview": enrollment = .overview
            case "system-settings", "waiting": enrollment = .systemSettingsOpen
            case "checking": enrollment = .detectingProfile
            case "profile-detected", "installed": enrollment = .profileDetected
            case "profile-missing": enrollment = .profileMissing
            case "conflicting-mdm": enrollment = .conflictingManagement
            case "enrollment-failed": enrollment = .enrollmentFailed
            default: enrollment = .instructions
            }
        case .preparation:
            if variant == "ready" {
                preparation = .ready
                progress = 1
            } else if variant == "download-failed" {
                preparation = .downloadFailed
                progress = 0.43
            } else {
                preparation = .downloading
                progress = 0.58
            }
        case .verification:
            switch variant {
            case "ready", "hardware-trusted": verification = .hardwareTrusted
            case "trust-pending": verification = .trustPending
            case "check-in-delayed": verification = .checkInDelayed
            case "trust-failed": verification = .trustFailed
            case "offline": verification = .offline
            case "profile-detected": verification = .profileDetected
            default: verification = .enrollmentPending
            }
        case .complete:
            readinessCount = OnboardingFlowModel.readinessItemCount
            readiness = .ready
            account = .linked
            enrollment = .profileDetected
            preparation = .ready
            progress = 1
            verification = .hardwareTrusted
        }

        readinessCompletedCount = readinessCount
        readinessPhase = readiness
        accountPhase = account
        enrollmentPhase = enrollment
        preparationPhase = preparation
        preparationProgress = progress
        verificationPhase = verification
    }
}
