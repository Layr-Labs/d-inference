import Foundation

/// Six bounded cohort barriers, on the SAME serialized native group. Call only
/// after the corresponding actual load/request/model retirement on this rank.
final class Gemma4RemoteMTPCohortControl {
    private struct Value: Codable, Equatable {
        let schema: String, scopeSHA256: String, phase: String
        let ordinal: Int, senderRank: Int, sequence: Int
    }
    private let group: Collective
    private let scope: String
    let controlOperations: Gemma4MTPControlOperation
    private var sequence = 0, busy = false, failed = false
    init(group: Collective, input: Gemma4RemoteMTPInput, controlOperations: Gemma4MTPControlOperation) throws {
        guard group.transport == .jaccl, group.size == 2, group.rank == input.job.rank,
              PaddedControlFrame.byteCount == 16_384 else {
            throw ProbeError("Remote MTP cohort requires its actual JACCL rank")
        }
        self.group = group; scope = input.scopeSHA256
        self.controlOperations = controlOperations
    }
    func checkpoint(_ phase: String, ordinal: Int, check: () throws -> Void,
                    lifetimeCheck: () throws -> Void) throws {
        guard !failed, !busy, sequence < 6,
              (sequence == 0 && phase == "loaded" && ordinal == -1)
                || (sequence >= 1 && sequence <= 4 && phase == "request-retired" && ordinal == sequence-1)
                || (sequence == 5 && phase == "models-released" && ordinal == -1) else {
            throw ProbeError("Remote MTP cohort checkpoint is out of order")
        }
        busy = true; defer { busy = false }
        do {
            func value(_ rank: Int) -> Value { .init(schema:"gemma4_remote_mtp_cohort_control_v1",
                scopeSHA256:scope,phase:phase,ordinal:ordinal,senderRank:rank,sequence:sequence) }
            func send() throws {
                try controlOperations.send(resourceCheck:check,lifetimeCheck:{
                    guard !self.failed, self.busy else { throw ProbeError("Remote MTP cohort control is no longer active") }
                    try lifetimeCheck()
                }) { checkpoint in
                    let frame = try PaddedControlFrame.encode(canonicalJSONData(value(group.rank)))
                    try group.sendControlCompleted(frame,to:1-group.rank,
                        maximumBytes:PaddedControlFrame.byteCount,check:checkpoint.check)
                }
            }
            func receive() throws {
                let frame = try controlOperations.receive(resourceCheck:check,lifetimeCheck:{
                    guard !self.failed, self.busy else { throw ProbeError("Remote MTP cohort control is no longer active") }
                    try lifetimeCheck()
                }) { checkpoint in
                    try group.receiveControlCompleted(byteCount:PaddedControlFrame.byteCount,from:1-group.rank,
                        maximumBytes:PaddedControlFrame.byteCount,check:checkpoint.check)
                }
                let bytes = try PaddedControlFrame.decode(frame)
                try validateWorkerJSON(bytes)
                let actual = try JSONDecoder().decode(Value.self,from:bytes)
                try QwenLayerStageGenerationWireJSON.requireExact(QwenLayerStageGenerationWireJSON.object(bytes),actual)
                guard actual == value(1-group.rank) else { throw ProbeError("Remote MTP cohort peer checkpoint differs") }
            }
            if group.rank == 1 { try send(); try receive() } else { try receive(); try send() }
            sequence += 1
        } catch { failed = true; throw error }
    }
}
