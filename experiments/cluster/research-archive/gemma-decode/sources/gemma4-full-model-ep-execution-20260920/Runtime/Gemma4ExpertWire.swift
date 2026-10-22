import Foundation
import MLX

/// One reference to the SAME admitted Collective; never creates another group.
/// Checksummed plaintext research transport, not authenticated/encrypted RDMA.
final class Gemma4ExpertWire: Gemma4ExpertUnweightedExchange {
    let input: Gemma4ExpertCorrectnessInput
    let group: Collective
    private var sent = 0, received = 0, busy = false, failed = false
    private var schedule = Gemma4ExpertExchangeSchedule()
    private(set) var observations: [Gemma4ExpertExchangeObservation] = []
    private(set) var sentTensorBytes = 0, receivedTensorBytes = 0
    var rank: Int { group.rank }
    var controlRecordsSent: Int { sent }
    var controlRecordsReceived: Int { received }
    var complete: Bool { !failed && !busy && schedule.released && observations.count == 150
        && sent == Gemma4ExpertResourceTerms.expectedControlRecords
        && received == Gemma4ExpertResourceTerms.expectedControlRecords }

    init(input: Gemma4ExpertCorrectnessInput, group: Collective) throws {
        guard group.transport == .jaccl, group.size == 2, group.rank == input.job.rank,
              input.partition != nil else { throw ProbeError("Gemma EP group differs from its actual admitted rank") }
        self.input = input; self.group = group
    }
    func poison() { failed = true; schedule.poison() }
    func operation<T>(_ body: () throws -> T) throws -> T {
        guard !failed, !busy else { throw ProbeError("Gemma EP wire failed or reentered") }
        busy = true; defer { busy = false }
        do { return try body() } catch { poison(); throw error }
    }
    func send(_ value: Gemma4ExpertWireValue, check: () throws -> Void) throws {
        guard !failed, sent < Gemma4ExpertResourceTerms.controlRecordLimit else {
            throw ProbeError("Gemma EP send exceeded its lifetime record bound")
        }
        try check()
        let data = try canonicalJSONData(Gemma4ExpertWirePacket(schema: "gemma4_full_expert_wire_v1",
            scopeSHA256: input.scopeSHA256, senderRank: rank, ordinal: sent, value: value))
        guard (1...Gemma4ExpertResourceTerms.controlBytes).contains(data.count) else {
            throw ProbeError("Gemma EP control is oversized")
        }
        _ = try group.sendCompleted(MLXArray([UInt32(data.count)]), to: 1-rank, maximumBytes: 4, check: check)
        _ = try group.sendCompleted(MLXArray(data, [data.count], dtype: .uint8), to: 1-rank,
            maximumBytes: Gemma4ExpertResourceTerms.controlBytes, check: check)
        sent += 1; try check()
    }
    func receive(check: () throws -> Void) throws -> Gemma4ExpertWireValue {
        guard !failed, received < Gemma4ExpertResourceTerms.controlRecordLimit else {
            throw ProbeError("Gemma EP receive exceeded its lifetime record bound")
        }
        try check()
        let prefix = try group.receiveCompleted(shape: [1], dtype: .uint32, from: 1-rank, maximumBytes: 4, check: check)
        let length = Int(prefix.item(UInt32.self)); try check()
        guard (1...Gemma4ExpertResourceTerms.controlBytes).contains(length) else {
            throw ProbeError("Gemma EP control length exceeded its bound")
        }
        let array = try group.receiveCompleted(shape: [length], dtype: .uint8, from: 1-rank,
            maximumBytes: Gemma4ExpertResourceTerms.controlBytes, check: check)
        let bytes = array.asData(access: .copy).data; try check()
        let value = try Gemma4ExpertWireCodec.decode(bytes, scope: input.scopeSHA256, sender: 1-rank, ordinal: received)
        received += 1; return value
    }
    func require(_ expected: Gemma4ExpertWireValue, check: () throws -> Void) throws {
        guard try receive(check: check) == expected else { throw ProbeError("Gemma EP peer control differs from actual local state") }
    }
    private func agree(_ value: Gemma4ExpertWireValue, check: () throws -> Void) throws {
        if rank == 0 { try send(value, check: check); try require(value, check: check) }
        else { try require(value, check: check); try send(value, check: check) }
    }
    func checkpoint(_ event: String, selected: [Int] = [], check: () throws -> Void) throws {
        try operation {
            switch event {
            case "begin": try schedule.begin()
            case "ready": try schedule.ready()
            case "request-retired": try schedule.retire()
            case "model-released": try schedule.releaseModel()
            default: throw ProbeError("Unknown Gemma EP checkpoint")
            }
            guard (event == "request-retired" || event == "model-released") ? selected.count == 2 : selected.isEmpty else {
                throw ProbeError("Gemma EP checkpoint token cardinality differs")
            }
            try agree(.init(event: event, tokenIDsSHA256: qwenGenerationTokenHash(selected)), check: check)
        }
    }
    func frameCommitted(_ frame: QwenLayerStageFrame, tokens: [Int], row: Gemma4ShortRow?, check: () throws -> Void) throws {
        try operation {
            try schedule.committed(Self.position(frame))
            guard frame == (try input.request.frame(sequence: frame.sequence)), tokens.count == frame.tokenCount,
                  (frame.sequence == 0) == (row == nil), row.map({ $0.ordinal == frame.sequence-1 }) ?? true else {
                throw ProbeError("Gemma EP committed frame or actual local full row differs")
            }
            try agree(.init(event: "frame-committed", frame: frame,
                tokenIDsSHA256: qwenGenerationTokenHash(tokens), rowSHA256: row?.logicalBytesSHA256,
                tokenID: row?.tokenID), check: check)
        }
    }
    func noteSentTensor(_ bytes: Int) throws {
        sentTensorBytes = try QwenLongPrefillCheckedBytes.sum([sentTensorBytes, bytes])
    }
    func noteReceivedTensor(_ bytes: Int) throws {
        receivedTensorBytes = try QwenLongPrefillCheckedBytes.sum([receivedTensorBytes, bytes])
    }
    static func position(_ frame: QwenLayerStageFrame) -> Gemma4ExpertExchangeFrame {
        .init(sequence: frame.sequence, phase: frame.phase.rawValue, offset: frame.tokenOffset,
            count: frame.tokenCount, finalPrompt: frame.finalPromptChunk)
    }

    func exchange(scope: Gemma4ExpertLayerScope, localRank: Int,
                  localRows: MLXArray?, check: () throws -> Void) throws -> Gemma4ExpertPeerRows {
        try operation {
            try check()
            guard localRank == rank, let partition = input.partition,
                  scope.binding == input.binding(purpose: scope.binding.purpose),
                  (1...16).contains(scope.tokenCount), scope.tokenCount == scope.frame.tokenCount, scope.dtype == "bfloat16",
                  scope.assignmentCounts.count == 2, scope.projectionPolicies.count == 2,
                  scope.assignmentCounts.allSatisfy({ (0...(scope.tokenCount*8)).contains($0) }),
                  scope.assignmentCounts.reduce(0,+) == scope.tokenCount*8,
                  [scope.routeSHA256,scope.inputSHA256,scope.weightsSHA256].allSatisfy(qwenStageWireIsSHA256) else {
                throw ProbeError("Gemma EP actual layer scope differs from admitted job")
            }
            try schedule.requireExchange(purpose: scope.binding.purpose.rawValue,
                frame: Self.position(scope.frame), layer: scope.globalLayer)
            for peer in 0..<2 {
                let expected = try ExpertAxisProjectionPolicy(globalAssignments: scope.tokenCount*8,
                    globalExperts: 128, ownedExperts: partition.globalIDsByRank[peer].count,
                    localAssignments: scope.assignmentCounts[peer])
                guard scope.projectionPolicies[peer] == expected else { throw ProbeError("Gemma EP projection policy changed") }
            }
            let scopeSHA = sha256(try canonicalJSONData(scope))
            try agree(.init(event: "layer", layerScopeSHA256: scopeSHA), check: check)
            let peer: (MLXArray?, String)
            let localSHA: String
            if rank == 0 {
                localSHA = try sendRows(localRows, rows: scope.assignmentCounts[0], layerScope: scopeSHA, check: check)
                peer = try receiveRows(rows: scope.assignmentCounts[1], layerScope: scopeSHA, check: check)
            } else {
                peer = try receiveRows(rows: scope.assignmentCounts[0], layerScope: scopeSHA, check: check)
                localSHA = try sendRows(localRows, rows: scope.assignmentCounts[1], layerScope: scopeSHA, check: check)
            }
            try check()
            try schedule.completeExchange(purpose: scope.binding.purpose.rawValue,
                frame: Self.position(scope.frame), layer: scope.globalLayer)
            guard observations.count < Gemma4ExpertResourceTerms.maximumLayerExchanges else {
                throw ProbeError("Gemma EP observation record bound exceeded")
            }
            observations.append(.init(scope: scope, scopeSHA256: scopeSHA,
                rank0OutputSHA256: rank == 0 ? localSHA : peer.1,
                rank1OutputSHA256: rank == 1 ? localSHA : peer.1))
            return .init(scope: scope, producerRank: 1-rank, array: peer.0)
        }
    }
}

struct Gemma4ExpertExchangeObservation: Encodable {
    let scope: Gemma4ExpertLayerScope
    let scopeSHA256: String
    let rank0OutputSHA256: String
    let rank1OutputSHA256: String
}
