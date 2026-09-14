import Foundation
import SandboxCore

/// Explicit phase commands keep the privileged disk operation separate from
/// the selected GUI session that owns Virtualization.framework installation.
enum AccountlessBaseCommand {
    static func run(_ arguments: [String]) async throws {
        let options = try AccountlessBaseOptions(arguments)
        let report: AccountlessBasePhaseReport
        switch options.phase {
        case .reserve: report = try await AccountlessBaseReservationCommand.run(options)
        case .payload, .stage: report = try await AccountlessBaseRootCommand.run(options)
        case .authorizeBoot: report = try await AccountlessAuthorizeBootCommand.run(options)
        case .boot: report = try await AccountlessBootCommand.run(options)
        case .collect: report = try await AccountlessCollectCommand.run(options, aborting: false)
        case .abortCollection: report = try await AccountlessCollectCommand.run(options, aborting: true)
        case .publishInstalled: report = try await AccountlessPublishInstalledCommand.run(options)
        case .qualify: report = try await AccountlessQualificationCommand.run(options)
        }
        if options.json {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
        } else {
            print("\(report.name): \(report.phase.rawValue)")
            print("Candidate: \(report.candidateID.uuidString.lowercased())")
            if let path = report.payloadPath { print("Payload: \(path)") }
            if let path = report.journalPath { print("Journal: \(path)") }
            if let path = report.permitPath { print("Boot permit: \(path)") }
            if let path = report.collectionPath { print("Collection: \(path)") }
            print("Installed: \(report.installed.map(String.init) ?? "unverified"); qualified: \(report.qualified)")
        }
        if report.phase == .qualificationAborted { throw DaemonCLIError.qualificationIncomplete }
    }
}

struct AccountlessBasePhaseReport: Encodable, Sendable {
    enum Phase: String, Encodable, Sendable {
        case awaitingRootInstallation, payloadPrepared, payloadStaged, installerBootAuthorized, installerBootStopped, installerAttemptRecovered
        case installationCollected, collectionAborted, installedAwaitingQualification
        case templateQualified, qualificationAborted
    }
    let phase: Phase
    let name: String
    let candidateID: UUID
    let bootstrapAttemptID: UUID
    let payloadPath: String?
    let journalPath: String?
    let replayed: Bool
    let permitPath: String?
    let nativeExitCode: Int32?
    let observedRunning: Bool?
    let sourceStopped: Bool?
    let collectionPath: String?
    let installed: Bool?
    let qualified: Bool
    let qualificationID: UUID?

    init(phase: Phase, candidate: AccountlessBaseCandidateRecord, payloadPath: String? = nil,
         journalPath: String? = nil, replayed: Bool = false, permitPath: String? = nil,
         nativeExitCode: Int32? = nil, observedRunning: Bool? = nil, sourceStopped: Bool? = nil,
         collectionPath: String? = nil, installed: Bool? = false, qualified: Bool = false, qualificationID: UUID? = nil) {
        self.phase = phase; name = candidate.source.name; candidateID = candidate.candidateID
        bootstrapAttemptID = candidate.bootstrapAttemptID; self.payloadPath = payloadPath
        self.journalPath = journalPath; self.replayed = replayed
        self.permitPath = permitPath; self.nativeExitCode = nativeExitCode
        self.observedRunning = observedRunning; self.sourceStopped = sourceStopped
        self.collectionPath = collectionPath; self.installed = installed
        self.qualified = qualified; self.qualificationID = qualificationID
    }
}
