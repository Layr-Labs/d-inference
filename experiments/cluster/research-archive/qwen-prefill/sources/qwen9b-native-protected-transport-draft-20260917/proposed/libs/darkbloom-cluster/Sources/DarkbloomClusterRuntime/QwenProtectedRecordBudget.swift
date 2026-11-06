import DarkbloomClusterSecurity
import Foundation

/// Called only by the existing serialized native owner. Reservations consume
/// worst-case session credit before work and are never refunded on an error.
/// The sole actual codec still owns strict send/receive sequence numbers.
final class QwenProtectedRecordBudget {
    private let limits: ClusterRecordLimits
    private var records: UInt64 = 0, bytes: UInt64 = 0
    private var failed = false
    init() throws { limits = try QwenResidentProtectedExperiment.limits(); try reserve(Self.setup()) }

    static func setup() throws -> ClusterRecordTransferEnvelope {
        try .init(entries: [(.exact(256), 2)],
            maximumTransportFrameBytes: QwenResidentProtectedExperiment.maximumFrameBytes)
    }
    static func request() throws -> ClusterRecordTransferEnvelope {
        // Each direction conservatively reserves BOTH ranks' traffic classes:
        // readiness, three header/payload frames, six boundary ACKs, two token
        // and two decision packets/ACKs, and the final retirement ACK.
        try .init(entries: [(.exact(256), 1), (.exact(4), 3), (.exact(16_384), 3),
            (.exact(QwenResidentProtectedExperiment.maximumPlaintextBytes), 3), (.exact(256), 6),
            (.exact(4), 4), (.exact(4096), 4), (.exact(256), 4), (.exact(256), 1)],
            maximumTransportFrameBytes: QwenResidentProtectedExperiment.maximumFrameBytes)
    }
    func reserveRequest(status: ClusterRecordTransportStatus) throws {
        try requireStatus(status)
        try reserve(Self.request())
    }
    func requireCredit(status: ClusterRecordTransportStatus, sending: Bool, plaintextBytes: Int) throws {
        try requireStatus(status)
        let usedRecords = sending ? status.codec.sealedRecords : status.codec.openedRecords
        let usedBytes = sending ? status.codec.sealedPlaintextBytes : status.codec.openedPlaintextBytes
        guard plaintextBytes > 0, usedRecords < records, UInt64(plaintextBytes) <= bytes - usedBytes else {
            failed = true; throw ProbeError("Protected operation exceeds reserved directional credit")
        }
    }
    private func requireStatus(_ status: ClusterRecordTransportStatus) throws {
        guard !failed, status.active, !status.operationInFlight, status.codec.active, !status.codec.operationInFlight,
              status.codec.sealedRecords <= records, status.codec.openedRecords <= records,
              status.codec.sealedPlaintextBytes <= bytes, status.codec.openedPlaintextBytes <= bytes else {
            failed = true; throw ProbeError("Protected actual record counters exceed reserved session credit")
        }
    }
    private func reserve(_ envelope: ClusterRecordTransferEnvelope) throws {
        do {
            guard !failed else { throw ProbeError("Protected record budget failed") }
            try envelope.requireRemaining(usedRecords: records, usedPlaintextBytes: bytes, limits: limits)
            records += envelope.records; bytes += envelope.plaintextBytes
        } catch { failed = true; throw error }
    }
}
