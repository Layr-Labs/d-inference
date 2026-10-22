import Foundation
import MLX

/// Qualification transport over the existing completed P2P primitives.
/// Optional prefill tickets defer only the consumed ACK, never native completion.
/// It supplies checksums/scope binding, not authenticated or encrypted RDMA.
final class Gemma4BenchmarkWire {
    let input: Gemma4BenchmarkRequestInput
    let group: Collective
    let guardMetrics: Gemma4BenchmarkGuardMetrics
    private var sent = 0, received = 0, busy = false, failed = false
    private var pending: Gemma4BenchmarkWireValue?
    struct SentFrameTicket { let value: Gemma4BenchmarkWireValue }
    var rank: Int { group.rank }

    init(input: Gemma4BenchmarkRequestInput, group: Collective, guardMetrics: Gemma4BenchmarkGuardMetrics) throws {
        guard group.transport == .jaccl, group.size == 2, input.job.rank == group.rank else {
            throw ProbeError("Gemma wire requires its exact selected two-rank JACCL endpoint")
        }
        self.input = input; self.group = group; self.guardMetrics = guardMetrics
    }
    func poison() { failed = true }

    func operation<T>(_ body: () throws -> T) throws -> T {
        guard !failed, !busy else { throw ProbeError("Gemma transport failed or reentered") }
        busy = true; defer { busy = false }
        do { return try body() } catch { failed = true; throw error }
    }

    func send(_ value: Gemma4BenchmarkWireValue, check: () throws -> Void) throws {
        guard sent < 512 else { throw ProbeError("Gemma control count exceeds its bounded resident request") }
        try check()
        let data = try canonicalJSONData(Gemma4BenchmarkWirePacket(schema: "gemma4_benchmark_p2p_v1",
            scopeSHA256: input.scopeSHA256, senderRank: rank, ordinal: sent, value: value))
        let frame = try PaddedControlFrame.encode(data)
        try guardMetrics.measure(.wireSendCompleted) {
            try group.sendControlCompleted(frame,
                to: 1-rank, maximumBytes: PaddedControlFrame.byteCount, check: check)
        }
        sent += 1; try check()
    }

    func receive(check: () throws -> Void) throws -> Gemma4BenchmarkWireValue {
        guard received < 512 else { throw ProbeError("Gemma control count exceeds its bounded resident request") }
        let frame = try guardMetrics.measure(.wireReceiveCompleted) {
            try group.receiveControlCompleted(byteCount: PaddedControlFrame.byteCount,
                from: 1-rank, maximumBytes: PaddedControlFrame.byteCount, check: check)
        }
        try check()
        let data = try PaddedControlFrame.decode(frame)
        let value = try Gemma4BenchmarkWireCodec.decode(data, scope: input.scopeSHA256, sender: 1-rank, ordinal: received)
        received += 1; return value
    }

    func require(_ expected: Gemma4BenchmarkWireValue, check: () throws -> Void) throws {
        guard try receive(check: check) == expected else { throw ProbeError("Gemma peer control differs from local expectation") }
    }

    func checkpoint(_ event: String, tokenIDs: [Int] = [], check: () throws -> Void) throws {
        try operation {
            guard pending == nil, ["begin", "ready", "request-retired", "model-released"].contains(event) else {
                throw ProbeError("Gemma checkpoint overlaps an unconsumed frame")
            }
            let value = Gemma4BenchmarkWireValue(event: event, tokenIDsSHA256: qwenGenerationTokenHash(tokenIDs))
            if rank == 0 { try send(value, check: check); try require(value, check: check) }
            else { try require(value, check: check); try send(value, check: check) }
        }
    }

    func acceptToken(_ token: Int?, ordinal: Int, check: () throws -> Void) throws -> Int {
        try operation {
            guard pending == nil, (0..<input.request.outputCount).contains(ordinal), (rank == 1) == (token != nil) else {
                throw ProbeError("Gemma token responsibility/frontier differs")
            }
            var expected = Gemma4BenchmarkWireValue(event: "token", sequence: ordinal, frontier: input.request.promptCount+ordinal, tokenID: token)
            if rank == 1 { try send(expected, check: check) }
            else {
                let actual = try receive(check: check)
                expected.tokenID = actual.tokenID
                guard actual == expected else { throw ProbeError("Gemma token frame differs") }
            }
            guard let selected = expected.tokenID, (0..<262_144).contains(selected) else {
                throw ProbeError("Gemma peer token is outside the admitted vocabulary")
            }
            let accepted = Gemma4BenchmarkWireValue(event: "token-accepted", sequence: ordinal,
                frontier: input.request.promptCount+ordinal, tokenID: selected)
            if rank == 0 { try send(accepted, check: check) } else { try require(accepted, check: check) }
            return selected
        }
    }

    func finishFrameConsumed(_ ticket: SentFrameTicket, check: () throws -> Void) throws {
        try operation {
            let value = ticket.value
            guard rank == 0, input.job.prefill == .oneChunkLookahead, value.event == "frame",
                  pending == value else { throw ProbeError("Gemma consumed ticket differs or was replayed") }
            let expected = Gemma4BenchmarkWireValue(event: "frame-consumed", sequence: value.sequence,
                frontier: value.frontier, count: value.count, tokenIDsSHA256: value.tokenIDsSHA256,
                payloadSHA256: value.payloadSHA256, dtype: value.dtype)
            try require(expected, check: check); pending = nil
        }
    }

    func retainPending(_ value: Gemma4BenchmarkWireValue) throws {
        guard pending == nil else { throw ProbeError("Gemma unconsumed frame overlap") }; pending = value
    }
    func requireNoPending() throws {
        guard pending == nil else { throw ProbeError("Gemma payload overlaps an unconsumed frame") }
    }
    func consume(sequence: Int, frontier: Int, check: () throws -> Void) throws {
        try operation {
            guard rank == 1, let value = pending, value.event == "frame", value.sequence == sequence,
                  value.frontier == frontier else { throw ProbeError("Gemma consumption lacks exact committed frame") }
            let receipt = Gemma4BenchmarkWireValue(event: "frame-consumed", sequence: value.sequence,
                frontier: value.frontier, count: value.count, tokenIDsSHA256: value.tokenIDsSHA256,
                payloadSHA256: value.payloadSHA256, dtype: value.dtype)
            try send(receipt, check: check); pending = nil
        }
    }
}
