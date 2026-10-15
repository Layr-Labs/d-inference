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
    private var sequence = 0, busy = false, failed = false
    init(group: Collective, input: Gemma4RemoteMTPInput) throws {
        guard group.transport == .jaccl, group.size == 2, group.rank == input.job.rank else {
            throw ProbeError("Remote MTP cohort requires its actual JACCL rank")
        }
        self.group = group; scope = input.scopeSHA256
    }
    func checkpoint(_ phase: String, ordinal: Int, check: () throws -> Void) throws {
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
                try check()
                let frame = try PaddedControlFrame.encode(canonicalJSONData(value(group.rank)))
                try group.sendControlCompleted(frame,to:1-group.rank,maximumBytes:PaddedControlFrame.byteCount,check:check)
                try check()
            }
            func receive() throws {
                let frame = try group.receiveControlCompleted(byteCount:PaddedControlFrame.byteCount,from:1-group.rank,
                    maximumBytes:PaddedControlFrame.byteCount,check:check)
                try check(); let bytes = try PaddedControlFrame.decode(frame)
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
