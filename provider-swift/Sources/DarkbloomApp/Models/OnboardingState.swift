import Foundation

enum ReadinessPhase: Int, Codable, Equatable, Sendable {
    case checking
    case ready
    case unsupportedMac
    case insufficientMemory
    case lowStorage
    case offline
    case requirementsFailed
    case insufficientStorage
    case unavailable

    var issueItemIndex: Int? {
        switch self {
        case .unsupportedMac: 0
        case .insufficientMemory: 3
        case .lowStorage, .insufficientStorage: 4
        case .offline: 5
        case .requirementsFailed, .unavailable, .checking, .ready: nil
        }
    }

    var allowsContinuation: Bool {
        self == .ready || self == .lowStorage
    }

}

enum AccountLinkPhase: Int, Codable, Equatable, Sendable {
    case introduction
    case waitingForApproval
    case confirming
    case linked
    case expired
    case unreachable
}

enum EnrollmentPhase: Int, Codable, Equatable, Sendable {
    case overview = 0
    case instructions = 1
    case systemSettingsOpen = 2
    case detectingProfile = 3
    case profileDetected = 4
    case profileMissing = 5
    case conflictingManagement = 6
    case enrollmentFailed = 7
    case requestingProfile = 8
}

enum PreparationPhase: Int, Codable, Equatable, Sendable {
    case reservingSpace
    case downloading
    case verifying
    case ready
    case downloadFailed
    case loadingCatalog
    case choosingModel
    case startingProvider
    case catalogFailed
    case noCompatibleModel
    case startFailed
}

enum VerificationPhase: Int, Codable, Equatable, Sendable {
    case profileDetected
    case enrollmentPending
    case trustPending
    case hardwareTrusted
    case checkInDelayed
    case trustFailed
    case offline

    var completedMilestoneCount: Int {
        switch self {
        case .profileDetected, .enrollmentPending, .checkInDelayed, .offline: 1
        case .trustPending, .trustFailed: 2
        case .hardwareTrusted: 4
        }
    }

    init(legacyCompletedCount: Int) {
        switch legacyCompletedCount {
        case ..<1: self = .profileDetected
        case 1: self = .enrollmentPending
        case 2 ... 3: self = .trustPending
        default: self = .hardwareTrusted
        }
    }
}

enum ResumeReconciliationState: Equatable, Sendable {
    case notNeeded
    case required
    case rechecking
    case reconciled
    case unavailable

    var blocksProgress: Bool {
        self == .required || self == .rechecking || self == .unavailable
    }
}

enum ResumeReconciliationOutcome: Equatable, Sendable {
    case matched
    case accountLinkRequired
    case profileMissing
    case trustRequired
    case unavailable
}

enum SetupItemState: Equatable, Sendable {
    case waiting
    case working
    case complete
    case advisory
    case issue
}

struct SetupStatusItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let state: SetupItemState
}
