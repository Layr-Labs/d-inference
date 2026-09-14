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
            print("Installed: false; qualified: false")
        }
    }
}

struct AccountlessBasePhaseReport: Encodable, Sendable {
    enum Phase: String, Encodable, Sendable {
        case awaitingRootInstallation, payloadPrepared, payloadStaged, installerBootAuthorized, installerBootStopped, installerAttemptRecovered
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
    let installed = false
    let qualified = false

    init(phase: Phase, candidate: AccountlessBaseCandidateRecord, payloadPath: String? = nil,
         journalPath: String? = nil, replayed: Bool = false, permitPath: String? = nil,
         nativeExitCode: Int32? = nil, observedRunning: Bool? = nil, sourceStopped: Bool? = nil) {
        self.phase = phase; name = candidate.source.name; candidateID = candidate.candidateID
        bootstrapAttemptID = candidate.bootstrapAttemptID; self.payloadPath = payloadPath
        self.journalPath = journalPath; self.replayed = replayed
        self.permitPath = permitPath; self.nativeExitCode = nativeExitCode
        self.observedRunning = observedRunning; self.sourceStopped = sourceStopped
    }
}
