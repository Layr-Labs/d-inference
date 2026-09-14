import Foundation
import SandboxCore

struct AccountlessInstallationBinding: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let candidateID: UUID
    let bootstrapAttemptID: UUID
    let source: SandboxGuestBaseSource
    let payload: SandboxGuestPayloadIdentity

    init(candidate: AccountlessBaseCandidateRecord, release: BaseGuestRelease) throws {
        let payload = SandboxGuestPayloadIdentity(releaseManifestSHA256: release.manifestSHA256,
            guestSHA256: release.hashes["darkbloom-sandbox-guest"] ?? "",
            bootstrapSHA256: release.hashes["darkbloom-sandbox-bootstrap.sh"] ?? "",
            launchdSHA256: release.hashes["io.darkbloom.sandbox.guest.plist"] ?? "",
            installerSHA256: release.hashes["install-sandbox-guest.sh"] ?? "")
        guard candidate.isValid, candidate.payload == payload,
              !candidate.source.reference.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw AccountlessInstallationError.invalidBinding }
        schemaVersion = 1; candidateID = candidate.candidateID; bootstrapAttemptID = candidate.bootstrapAttemptID
        source = candidate.source; self.payload = payload
    }

    func matches(_ candidate: AccountlessBaseCandidateRecord) -> Bool {
        schemaVersion == 1 && candidate.isValid && candidateID == candidate.candidateID
            && bootstrapAttemptID == candidate.bootstrapAttemptID && source == candidate.source && payload == candidate.payload
    }
}

enum AccountlessInstallationError: Error {
    case invalidBinding, invalidReceipt, incompleteInstallation, unsafeDestination, releaseChanged, copyFailed
    case stagingInProgress, stagingClosed
}

struct AccountlessInstallationPayloadPlan: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let binding: AccountlessInstallationBinding
    let bindingSHA256: String
    let guestStagePath: String
    let guestLaunchDaemonPath: String
    let guestReceiptPath: String
    let maximumBootSeconds: UInt32
    /// Relative paths under data-overlay, including only known generated and signed files.
    let files: [String: String]
}

/// The wrapper binds diagnostics to one candidate. Its schema2 installation is
/// absent until the guest has actual context and signature observations.
struct AccountlessInstallationResult: Codable, Equatable, Sendable {
    enum Stage: String, Codable, Sendable {
        case rootJobStarted, verifyingPayload, installing, verifyingInstallation, complete, failed
    }
    enum Failure: String, Codable, Sendable {
        case none, contextUnavailable, invalidPayload, installerFailed, installedPayloadInvalid
        case bootstrapAccountPresent, tenantIdentityInvalid, logCaptureFailed, shutdownFailed, unexpectedFailure
    }
    let schemaVersion: Int
    let binding: AccountlessInstallationBinding
    let stage: Stage
    let error: Failure
    let shellExitCode: Int32?
    let guestOperatingSystemVersion: String?
    let guestArchitecture: String?
    let virtualizedRootObserved: Bool?
    let installation: SandboxAccountlessInstallationReceipt?

    func validate(candidate: AccountlessBaseCandidateRecord) throws {
        guard schemaVersion == 1, binding.matches(candidate),
              shellExitCode.map({ (0...255).contains($0) }) ?? true else { throw AccountlessInstallationError.invalidReceipt }
        if let installation {
            guard installation.isValidStartedRecord, installation.source == binding.source,
                  installation.payload == binding.payload, installation.rootJobID == binding.bootstrapAttemptID,
                  installation.guestOperatingSystemVersion == guestOperatingSystemVersion,
                  installation.guestArchitecture == guestArchitecture, virtualizedRootObserved == true,
                  installation.phase == .installationComplete || stage != .complete
            else { throw AccountlessInstallationError.invalidReceipt }
        }
        switch stage {
        case .complete:
            guard error == .none, shellExitCode == 0, installation?.installationComplete == true
            else { throw AccountlessInstallationError.invalidReceipt }
        case .failed:
            guard error != .none, shellExitCode.map({ $0 != 0 }) == true else { throw AccountlessInstallationError.invalidReceipt }
            switch error {
            case .invalidPayload:
                guard installation?.signedInstallerVerified != true else { throw AccountlessInstallationError.invalidReceipt }
            case .installerFailed:
                guard installation?.installerExitCode.map({ $0 != 0 }) == true else { throw AccountlessInstallationError.invalidReceipt }
            case .installedPayloadInvalid:
                guard installation?.installedPayloadVerified == false else { throw AccountlessInstallationError.invalidReceipt }
            case .bootstrapAccountPresent:
                guard installation?.bootstrapAccountAbsent == false else { throw AccountlessInstallationError.invalidReceipt }
            case .tenantIdentityInvalid:
                guard installation?.tenantIdentityVerified == false else { throw AccountlessInstallationError.invalidReceipt }
            case .shutdownFailed:
                guard installation?.installationComplete == true else { throw AccountlessInstallationError.invalidReceipt }
            default: break
            }
        default:
            guard error == .none, shellExitCode == nil, installation?.phase != .installationComplete
            else { throw AccountlessInstallationError.invalidReceipt }
        }
    }

    func completedInstallation(candidate: AccountlessBaseCandidateRecord) throws -> SandboxAccountlessInstallationReceipt {
        try validate(candidate: candidate)
        guard stage == .complete, let installation else { throw AccountlessInstallationError.incompleteInstallation }
        return installation
    }
}
