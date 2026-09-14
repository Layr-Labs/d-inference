import Darwin
import Foundation
import SandboxCore

/// Host evidence only. It is neither template readiness nor a disk content hash.
package struct LumeCandidateDiskIdentity: Codable, Equatable, Sendable {
    package let device: UInt64
    package let inode: UInt64
    package let size: UInt64
    package let modifiedSeconds: Int64
    package let modifiedNanoseconds: Int64
    package let changedSeconds: Int64
    package let changedNanoseconds: Int64

    package init(_ info: stat) {
        device = UInt64(UInt32(bitPattern: info.st_dev)); inode = UInt64(info.st_ino)
        size = UInt64(info.st_size); modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        changedSeconds = Int64(info.st_ctimespec.tv_sec); changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
    }

    var isValid: Bool {
        size > 0 && inode > 0 && (0..<1_000_000_000).contains(modifiedNanoseconds)
            && (0..<1_000_000_000).contains(changedNanoseconds)
    }
}

/// Published after validating the collected installation and cleanup records.
/// Construction alone neither observes those operations nor grants readiness;
/// the base runtime rechecks source ownership, resources and the disk snapshot.
package struct LumeInstalledCandidateCheckpoint: Codable, Equatable, Sendable {
    package static let fileName = ".darkbloom-accountless-installed.json"
    package static let reservationFileName = ".darkbloom-accountless-candidate.json"
    package static let installationFileName = ".darkbloom-accountless-installation.json"
    package static let cleanupFileName = ".darkbloom-accountless-cleanup.json"
    package enum Phase: String, Codable, Sendable { case installedAwaitingQualification }

    package let schemaVersion: Int
    package let phase: Phase
    package let candidateID: UUID
    package let bootstrapAttemptID: UUID
    package let reservationSHA256: String
    package let installationReceiptSHA256: String
    package let cleanupReceiptSHA256: String
    package let source: SandboxGuestBaseSource
    package let payload: SandboxGuestPayloadIdentity
    package let resources: SandboxResourceSpecification
    package let disk: LumeCandidateDiskIdentity

    var isValid: Bool {
        schemaVersion == 1 && phase == .installedAwaitingQualification
            && candidateID != bootstrapAttemptID && candidateID != source.installationID
            && bootstrapAttemptID != source.installationID && source.isValid && source.kind == .appleRestore
            && payload.isValid && disk.isValid
            && [reservationSHA256, installationReceiptSHA256, cleanupReceiptSHA256].allSatisfy(Self.isDigest)
    }

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// A separately retained cleanup observation, bound to the original root job
/// and the exact disk snapshot after detach. It contains no credentials or logs.
package struct LumeCandidateInstallationCleanup: Codable, Equatable, Sendable {
    package let schemaVersion: Int
    package let candidateID: UUID
    package let bootstrapAttemptID: UUID
    package let source: SandboxGuestBaseSource
    package let installationReceiptSHA256: String
    package let disk: LumeCandidateDiskIdentity
    package let temporaryJobRemoved: Bool
    package let temporaryPayloadRemoved: Bool
    package let fullyDetached: Bool
    package let sourceStoppedVerified: Bool

    package init(schemaVersion: Int = 1, candidateID: UUID, bootstrapAttemptID: UUID,
                 source: SandboxGuestBaseSource, installationReceiptSHA256: String,
                 disk: LumeCandidateDiskIdentity, temporaryJobRemoved: Bool,
                 temporaryPayloadRemoved: Bool, fullyDetached: Bool, sourceStoppedVerified: Bool) {
        self.schemaVersion = schemaVersion; self.candidateID = candidateID; self.bootstrapAttemptID = bootstrapAttemptID
        self.source = source; self.installationReceiptSHA256 = installationReceiptSHA256; self.disk = disk
        self.temporaryJobRemoved = temporaryJobRemoved; self.temporaryPayloadRemoved = temporaryPayloadRemoved
        self.fullyDetached = fullyDetached; self.sourceStoppedVerified = sourceStoppedVerified
    }

    func matches(_ checkpoint: LumeInstalledCandidateCheckpoint) -> Bool {
        schemaVersion == 1 && candidateID == checkpoint.candidateID
            && bootstrapAttemptID == checkpoint.bootstrapAttemptID && source == checkpoint.source
            && installationReceiptSHA256 == checkpoint.installationReceiptSHA256 && disk == checkpoint.disk
            && temporaryJobRemoved && temporaryPayloadRemoved && fullyDetached && sourceStoppedVerified
    }
}

/// Reads the existing immutable reservation format; it never advances its phase.
struct LumeReservedCandidateRecord: Decodable, Equatable {
    let schemaVersion: Int
    let phase: String
    let candidateID: UUID
    let bootstrapAttemptID: UUID
    let source: SandboxGuestBaseSource
    let payload: SandboxGuestPayloadIdentity
    let resources: SandboxResourceSpecification
    let disk: LumeCandidateDiskIdentity
    let installed: Bool
    let qualified: Bool

    func matches(_ checkpoint: LumeInstalledCandidateCheckpoint) -> Bool {
        schemaVersion == 1 && phase == "awaitingRootInstallation" && !installed && !qualified
            && candidateID == checkpoint.candidateID && bootstrapAttemptID == checkpoint.bootstrapAttemptID
            && source == checkpoint.source && payload == checkpoint.payload && resources == checkpoint.resources
            && disk.isValid && disk.device == checkpoint.disk.device && disk.inode == checkpoint.disk.inode
            && disk.size == checkpoint.disk.size
    }
}
