import Foundation
import SandboxCore
import SandboxGuestProtocol
import SandboxRuntime
import SandboxRuntimeLume

/// One immutable attempt per private directory. Recovery can verify an existing
/// publication or clean up and abort; it cannot restart native checks.
final class AccountlessQualificationJournal {
    private let files: AccountlessPrivateJournal
    let intent: AccountlessQualificationIntent
    let isNew: Bool

    init(directory: URL, permit: AccountlessBootPermit, collection: AccountlessCollectionRecord,
        capacityDirectory: URL, guestReleaseDirectory: URL,
        guestReleaseSHA256: @autoclosure () throws -> String,
        leaseDurationSeconds: TimeInterval = 300, now: Date = Date()) throws {
        files = try .init(directory: directory, lockName: "qualification.lock")
        if let bytes = try files.read("intent.json") {
            intent = try AccountlessJournalJSON.decode(AccountlessQualificationIntent.self, bytes)
            try intent.validate()
            guard bytes == (try AccountlessJournalJSON.encode(intent)), intent.permit == permit, intent.collection == collection,
                  intent.capacityDirectory == capacityDirectory.path, intent.guestReleaseDirectory == guestReleaseDirectory.path else {
                throw AccountlessInstallationError.invalidBinding
            }
            isNew = false
        } else {
            try files.requireAbsent(["lease.json", "clone.json", "checks.json", "ready.json", "published.json", "aborted.json"])
            guard leaseDurationSeconds.isFinite, (30...SandboxCapacityPolicy.maximumSupportedLeaseDurationSeconds).contains(leaseDurationSeconds) else {
                throw AccountlessInstallationError.invalidBinding
            }
            intent = .init(schemaVersion: 1, permit: permit, collection: collection, capacityDirectory: capacityDirectory.path,
                guestReleaseDirectory: guestReleaseDirectory.path, guestReleaseSHA256: try guestReleaseSHA256(),
                qualificationID: UUID(), sandboxID: SandboxID(), expiresAt: now.addingTimeInterval(leaseDurationSeconds))
            try intent.validate()
            try files.publishMatching(AccountlessJournalJSON.encode(intent), name: "intent.json")
            isNew = true
        }
    }

    func lease() throws -> SandboxCapacityLease? {
        guard let data = try files.read("lease.json") else { return nil }
        let value = try AccountlessJournalJSON.decode(SandboxCapacityLease.self, data)
        try intent.validateLease(value)
        return value
    }
    func recordLease(_ lease: SandboxCapacityLease) throws {
        try requireOpen(); try intent.validateLease(lease)
        try files.publishMatching(AccountlessJournalJSON.encode(lease), name: "lease.json")
    }
    func recordClone(_ observation: LumeQualificationCloneObservation) throws {
        try requireOpen()
        guard try lease() != nil, observation.cloneInstallationID == observation.materialsInstanceID else {
            throw AccountlessInstallationError.invalidBinding
        }
        try files.publishMatching(AccountlessJournalJSON.encode(Clone(qualificationID: intent.qualificationID,
            cloneInstallationID: observation.cloneInstallationID, materialsInstanceID: observation.materialsInstanceID)), name: "clone.json")
    }
    func recordChecks(_ result: LumeNativeQualificationResult) throws {
        try requireOpen()
        guard let clone = try clone(), result.initialBootID != result.restartedBootID,
              result.markerSHA256 == markerHash(clone) else { throw AccountlessInstallationError.invalidBinding }
        try files.publishMatching(AccountlessJournalJSON.encode(Checks(clone: clone, initialBootID: result.initialBootID,
            restartedBootID: result.restartedBootID, markerSHA256: result.markerSHA256)), name: "checks.json")
    }
    func recordReady(_ record: SandboxGuestTemplateReceipt) throws {
        try requireOpen()
        guard let checks = try checks(), let evidence = record.accountless,
              record.schemaVersion == 2, evidence.ready, evidence.installation == intent.collection.installation,
              evidence.qualification.qualificationID == intent.qualificationID,
              evidence.qualification.cloneName == intent.cloneName,
              evidence.qualification.cloneInstallationID == checks.clone.cloneInstallationID,
              evidence.qualification.cleanup.materialsInstanceID == checks.clone.materialsInstanceID else {
            throw AccountlessInstallationError.invalidBinding
        }
        try files.publishMatching(AccountlessJournalJSON.encode(record), name: "ready.json")
    }
    func ready() throws -> SandboxGuestTemplateReceipt? {
        guard let bytes = try files.read("ready.json") else { return nil }
        let value = try AccountlessJournalJSON.decode(SandboxGuestTemplateReceipt.self, bytes)
        guard try lease() != nil, let checks = try checks(), let evidence = value.accountless, value.schemaVersion == 2, evidence.ready,
              evidence.installation == intent.collection.installation, evidence.qualification.qualificationID == intent.qualificationID,
              evidence.qualification.cloneName == intent.cloneName,
              evidence.qualification.cloneInstallationID == checks.clone.cloneInstallationID,
              evidence.qualification.cleanup.materialsInstanceID == checks.clone.materialsInstanceID else {
            throw AccountlessInstallationError.invalidBinding
        }
        return value
    }
    func recordPublished() throws {
        guard let ready = try ready() else { throw AccountlessInstallationError.invalidBinding }
        try files.publishMatching(terminal(kind: "published", ready: ready), name: "published.json")
    }
    func aborted() throws -> Bool {
        guard let value = try files.read("aborted.json") else { return false }
        guard value == (try terminal(kind: "aborted", ready: nil)) else { throw AccountlessInstallationError.invalidBinding }
        return true
    }
    func recordAborted() throws {
        guard try !published() else { throw AccountlessInstallationError.invalidBinding }
        try files.publishMatching(terminal(kind: "aborted", ready: nil), name: "aborted.json")
    }

    private func published() throws -> Bool {
        guard let value = try files.read("published.json") else { return false }
        guard let ready = try ready(), value == (try terminal(kind: "published", ready: ready)) else {
            throw AccountlessInstallationError.invalidBinding
        }
        return true
    }
    private func terminal(kind: String, ready: SandboxGuestTemplateReceipt?) throws -> Data {
        try AccountlessJournalJSON.encode(Terminal(schemaVersion: 1, intentSHA256: BaseGuestRelease.digest(AccountlessJournalJSON.encode(intent)),
            kind: kind, readySHA256: try ready.map { BaseGuestRelease.digest(try AccountlessJournalJSON.encode($0)) }))
    }

    private func requireOpen() throws {
        guard try !aborted(), try !published() else { throw AccountlessInstallationError.stagingClosed }
    }
    private func clone() throws -> Clone? {
        guard let data = try files.read("clone.json") else { return nil }
        let value = try AccountlessJournalJSON.decode(Clone.self, data)
        guard try lease() != nil, value.qualificationID == intent.qualificationID, value.cloneInstallationID == value.materialsInstanceID,
              value.cloneInstallationID != (try intent.permit.candidate().source.installationID) else { throw AccountlessInstallationError.invalidBinding }
        return value
    }
    private func checks() throws -> Checks? {
        guard let data = try files.read("checks.json") else { return nil }
        let value = try AccountlessJournalJSON.decode(Checks.self, data)
        guard value.clone == (try clone()), value.initialBootID != value.restartedBootID,
              value.markerSHA256 == markerHash(value.clone) else { throw AccountlessInstallationError.invalidBinding }
        return value
    }
    private func markerHash(_ clone: Clone) -> String {
        BaseGuestRelease.digest(GuestQualificationProtocol.marker(qualificationID: intent.qualificationID, cloneInstallationID: clone.cloneInstallationID))
    }
    private struct Clone: Codable, Equatable { let qualificationID: UUID; let cloneInstallationID: UUID; let materialsInstanceID: UUID }
    private struct Checks: Codable { let clone: Clone; let initialBootID: UUID; let restartedBootID: UUID; let markerSHA256: String }
    private struct Terminal: Codable { let schemaVersion: Int; let intentSHA256: String; let kind: String; let readySHA256: String? }
}
