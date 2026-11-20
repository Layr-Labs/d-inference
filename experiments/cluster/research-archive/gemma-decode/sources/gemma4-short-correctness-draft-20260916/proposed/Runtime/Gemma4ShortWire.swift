import Foundation
import MLX

/// Serial qualification transport over the existing completed P2P primitives.
/// It supplies checksums/scope binding, not authenticated or encrypted RDMA.
final class Gemma4ShortWire {
    let input: Gemma4ShortCheckInput
    let group: Collective
    private var sent = 0, received = 0, busy = false, failed = false
    private var pending: Gemma4ShortWireValue?
    var rank: Int { group.rank }

    init(input: Gemma4ShortCheckInput, group: Collective) throws {
        guard group.transport == .jaccl, group.size == 2, input.job.rank == group.rank else {
            throw ProbeError("Gemma wire requires its exact selected two-rank JACCL endpoint")
        }
        self.input = input; self.group = group
    }
    func poison() { failed = true }

    func operation<T>(_ body: () throws -> T) throws -> T {
        guard !failed, !busy else { throw ProbeError("Gemma transport failed or reentered") }
        busy = true; defer { busy = false }
        do { return try body() } catch { failed = true; throw error }
    }

    func send(_ value: Gemma4ShortWireValue, check: () throws -> Void) throws {
        guard sent < 64 else { throw ProbeError("Gemma control count exceeds its short operation") }
        try check()
        let data = try canonicalJSONData(Gemma4ShortWirePacket(schema: "gemma4_short_p2p_v1",
            scopeSHA256: input.scopeSHA256, senderRank: rank, ordinal: sent, value: value))
        guard (1...16_384).contains(data.count) else { throw ProbeError("Gemma control exceeds its byte bound") }
        _ = try group.sendCompleted(MLXArray([UInt32(data.count)]), to: 1-rank, maximumBytes: 4, check: check)
        _ = try group.sendCompleted(MLXArray(data, [data.count], dtype: .uint8), to: 1-rank, maximumBytes: 16_384, check: check)
        sent += 1; try check()
    }

    func receive(check: () throws -> Void) throws -> Gemma4ShortWireValue {
        guard received < 64 else { throw ProbeError("Gemma control count exceeds its short operation") }
        let prefix = try group.receiveCompleted(shape: [1], dtype: .uint32, from: 1-rank, maximumBytes: 4, check: check)
        let length = Int(prefix.item(UInt32.self)); try check()
        guard (1...16_384).contains(length) else { throw ProbeError("Gemma control prefix exceeds fixed cap") }
        let array = try group.receiveCompleted(shape: [length], dtype: .uint8, from: 1-rank, maximumBytes: 16_384, check: check)
        let data = array.asData(access: .copy).data; try check()
        let value = try Gemma4ShortWireCodec.decode(data, scope: input.scopeSHA256, sender: 1-rank, ordinal: received)
        received += 1; return value
    }

    func require(_ expected: Gemma4ShortWireValue, check: () throws -> Void) throws {
        guard try receive(check: check) == expected else { throw ProbeError("Gemma peer control differs from local expectation") }
    }

    func checkpoint(_ event: String, tokenIDs: [Int] = [], check: () throws -> Void) throws {
        try operation {
            guard pending == nil, ["begin", "ready", "request-retired", "model-released"].contains(event) else {
                throw ProbeError("Gemma checkpoint overlaps an unconsumed frame")
            }
            let value = Gemma4ShortWireValue(event: event, tokenIDsSHA256: qwenGenerationTokenHash(tokenIDs))
            if rank == 0 { try send(value, check: check); try require(value, check: check) }
            else { try require(value, check: check); try send(value, check: check) }
        }
    }

    func acceptToken(_ token: Int?, ordinal: Int, check: () throws -> Void) throws -> Int {
        try operation {
            guard pending == nil, (0...1).contains(ordinal), (rank == 1) == (token != nil) else {
                throw ProbeError("Gemma token responsibility/frontier differs")
            }
            var expected = Gemma4ShortWireValue(event: "token", sequence: ordinal, frontier: 32+ordinal, tokenID: token)
            if rank == 1 { try send(expected, check: check) }
            else {
                let actual = try receive(check: check)
                expected.tokenID = actual.tokenID
                guard actual == expected else { throw ProbeError("Gemma token frame differs") }
            }
            guard let selected = expected.tokenID, (0..<262_144).contains(selected) else {
                throw ProbeError("Gemma peer token is outside the admitted vocabulary")
            }
            let accepted = Gemma4ShortWireValue(event: "token-accepted", sequence: ordinal,
                frontier: 32+ordinal, tokenID: selected)
            if rank == 0 { try send(accepted, check: check) } else { try require(accepted, check: check) }
            return selected
        }
    }

    func retainPending(_ value: Gemma4ShortWireValue) throws {
        guard pending == nil else { throw ProbeError("Gemma unconsumed frame overlap") }; pending = value
    }
    func requireNoPending() throws {
        guard pending == nil else { throw ProbeError("Gemma payload overlaps an unconsumed frame") }
    }
    func consume(sequence: Int, frontier: Int, check: () throws -> Void) throws {
        try operation {
            guard rank == 1, let value = pending, value.event == "frame", value.sequence == sequence,
                  value.frontier == frontier else { throw ProbeError("Gemma consumption lacks exact committed frame") }
            let receipt = Gemma4ShortWireValue(event: "frame-consumed", sequence: value.sequence,
                frontier: value.frontier, count: value.count, tokenIDsSHA256: value.tokenIDsSHA256,
                payloadSHA256: value.payloadSHA256, dtype: value.dtype)
            try send(receipt, check: check); pending = nil
        }
    }
}
