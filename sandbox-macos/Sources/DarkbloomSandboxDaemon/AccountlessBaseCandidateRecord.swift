import Foundation
import SandboxCore

/// A stopped image snapshot, not a content hash or native qualification proof.
struct AccountlessBaseDiskIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
}

enum AccountlessBaseCandidatePhase: String, Codable, Sendable {
    case awaitingRootInstallation
}

struct AccountlessBaseCandidateRecord: Codable, Equatable, Sendable {
    static let fileName = ".darkbloom-accountless-candidate.json"
    let schemaVersion: Int
    let phase: AccountlessBaseCandidatePhase
    let candidateID: UUID
    let bootstrapAttemptID: UUID
    let source: SandboxGuestBaseSource
    let payload: SandboxGuestPayloadIdentity
    let resources: SandboxResourceSpecification
    let disk: AccountlessBaseDiskIdentity
    let installed: Bool
    let qualified: Bool

    var isValid: Bool {
        schemaVersion == 1 && phase == .awaitingRootInstallation && !installed && !qualified
            && source.isValid && source.kind == .appleRestore && payload.isValid
            && candidateID != bootstrapAttemptID && candidateID != source.installationID
            && bootstrapAttemptID != source.installationID && disk.size > 0
            && (0..<1_000_000_000).contains(disk.modifiedNanoseconds)
            && (0..<1_000_000_000).contains(disk.changedNanoseconds)
    }
}

struct AccountlessBaseCandidateReport: Encodable, Equatable, Sendable {
    let candidate: AccountlessBaseCandidateRecord
    let recordPath: String
    let replayed: Bool
    let installed: Bool
    let qualified: Bool

    init(candidate: AccountlessBaseCandidateRecord, recordPath: String, replayed: Bool) {
        self.candidate = candidate; self.recordPath = recordPath; self.replayed = replayed
        installed = false; qualified = false
    }
}

enum AccountlessBaseCandidateError: Error {
    case unsupportedSource
    case existingBaseWithoutCandidate
    case unsafeImage
    case invalidRecord
    case candidateChanged
    case preparedArtifactsPresent
    case notStopped
}
