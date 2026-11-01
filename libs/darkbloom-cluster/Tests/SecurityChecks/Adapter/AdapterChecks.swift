import Dispatch
import Foundation

@main struct AdapterChecks {
    static func main() throws {
        try exactFrames(); print("PASS exact one-frame and bidirectional records")
        try variableFrames(); print("PASS variable two-frame and expected bounds")
        try allRecordTypes(); print("PASS closed setup and inference record coverage")
        try malformedFrames(); print("PASS capped framing rejects before payload return")
        try localContextAndReplay(); print("PASS expected context and replay fail closed")
        try localCancellation(); print("PASS cancellation before IO and after authenticated open")
        try blockedIO(); print("PASS blocked IO invalidation and concurrent use")
        try accounting(); print("PASS exact frame and cumulative admission accounting")
        print("PASS 8 adapter groups; no native/model/membership qualification")
    }

    static func exactFrames() throws {
        let pair = try FixturePair(), expected = try expectation(.exact(512))
        let plaintext = Data(repeating: 0x91, count: 512)
        try pair.first.send(plaintext, expecting: expected, check: {})
        let record = pair.frames.first(rank: 1)
        try require(record.count == 552 && record != plaintext, "Combined frame includes AEAD overhead")
        try require(pair.frames.sends(0) == [552], "Hot path must have exactly one send")
        try require(try pair.second.receive(expecting: expected, check: {}) == plaintext, "Exact authenticated payload")
        try require(pair.frames.receives(1) == [552], "Hot path must have exactly one receive")
        try pair.second.send(plaintext, expecting: expected, check: {})
        try require(try pair.first.receive(expecting: expected, check: {}) == plaintext, "Opposite direction")
        try require(pair.first.status.codec.sealedRecords == 1 && pair.first.status.codec.openedRecords == 1,
            "Distinct directional sequence accounting")
    }

    static func variableFrames() throws {
        let pair = try FixturePair(), expected = try expectation(.bounded(maximum: 512), type: .targetToken)
        let plaintext = Data(repeating: 0x72, count: 73)
        try pair.first.send(plaintext, expecting: expected, check: {})
        try require(pair.frames.sends(0) == [24, 89], "Variable frame is prefix then ciphertext/tag")
        try require(try pair.second.receive(expecting: expected, check: {}) == plaintext, "Variable roundtrip")
        try require(pair.frames.receives(1) == [24, 89], "No extra plaintext length frame")
        let mismatch = try FixturePair()
        try mismatch.first.send(plaintext, expecting: expected, check: {})
        let different = try expectation(.bounded(maximum: 513), type: .targetToken)
        try refuses { _ = try mismatch.second.receive(expecting: different, check: {}) }
        try require(!mismatch.second.status.active && mismatch.second.status.codec.openedRecords == 0,
            "Locally expected variable bounds are authenticated")
    }

    static func allRecordTypes() throws {
        let pair = try FixturePair()
        let types: [ClusterRecordType] = [.keyConfirmation, .loadAgreement, .loadedReady, .requestAgreement,
            .residualHeader, .residualPayload, .targetToken, .generationDecision, .acknowledgement, .requestRetired]
        for type in types {
            let expected = try expectation(.exact(32), type: type)
            let payload = Data(repeating: type.rawValue, count: 32)
            try pair.first.send(payload, expecting: expected, check: {})
            try require(try pair.second.receive(expecting: expected, check: {}) == payload, "Closed type roundtrip")
        }
        try require(pair.second.status.codec.openedRecords == 10, "Setup and request sequence does not reset")
    }

    static func malformedFrames() throws {
        let expected = try expectation(.exact(64))
        for kind in 0..<3 {
            let pair = try FixturePair()
            try pair.first.send(Data(repeating: 0x42, count: 64), expecting: expected, check: {})
            pair.frames.transformFirst(rank: 1) { input in
                var value = input
                if kind == 0 { value[value.count - 1] ^= 1 }
                else if kind == 1 { value.removeLast() }
                else { value[4] = 0xff }
                return value
            }
            var reconstructed = false
            try refuses { _ = try pair.second.receive(expecting: expected, check: {}); reconstructed = true }
            try require(!reconstructed && pair.second.status.codec.openedRecords == 0 && !pair.second.status.active,
                "Unauthenticated record never reaches reconstruction")
            try refuses { _ = try pair.second.receive(expecting: expected, check: {}) }
            try require(pair.frames.receives(1).count == 1, "Poisoned record path never retries raw IO")
        }
        let pair = try FixturePair(), variable = try expectation(.bounded(maximum: 64))
        try pair.first.send(Data(repeating: 0x42, count: 64), expecting: variable, check: {})
        pair.frames.transformFirst(rank: 1) { input in
            var value = input; for index in 16..<20 { value[index] = 0xff }; return value
        }
        try refuses { _ = try pair.second.receive(expecting: variable, check: {}) }
        try require(pair.frames.receives(1) == [24], "Oversize prefix cannot allocate/read a body")
    }

    static func localContextAndReplay() throws {
        for different in [try expectation(.exact(64), type: .targetToken), try expectation(.exact(64), metadata: 0x32)] {
            let pair = try FixturePair(), expected = try expectation(.exact(64))
            try pair.first.send(Data(repeating: 1, count: 64), expecting: expected, check: {})
            try refuses { _ = try pair.second.receive(expecting: different, check: {}) }
            try require(pair.second.status.codec.openedRecords == 0, "Wrong locally expected phase/type refused")
        }
        let pair = try FixturePair(), expected = try expectation(.exact(64))
        try pair.first.send(Data(repeating: 1, count: 64), expecting: expected, check: {})
        let replay = pair.frames.first(rank: 1)
        _ = try pair.second.receive(expecting: expected, check: {})
        pair.frames.inject(replay, rank: 1)
        try refuses { _ = try pair.second.receive(expecting: expected, check: {}) }
        try require(pair.second.status.codec.openedRecords == 1, "Replay cannot advance receive state")
    }

    static func localCancellation() throws {
        let cancelled = try FixturePair(), expected = try expectation(.exact(64))
        try refuses { try cancelled.first.send(Data(repeating: 1, count: 64), expecting: expected,
            check: { throw AdapterFixtureError.cancelled }) }
        try require(cancelled.frames.sends(0).isEmpty && cancelled.first.status.codec.sealedRecords == 0,
            "Expired admission never starts encryption or IO")
        let pair = try FixturePair()
        try pair.first.send(Data(repeating: 1, count: 64), expecting: expected, check: {})
        var reconstructed = false
        try refuses {
            _ = try pair.second.receive(expecting: expected, check: {
                if pair.second.status.codec.openedRecords == 1 { throw AdapterFixtureError.cancelled }
            })
            reconstructed = true
        }
        try require(!reconstructed && pair.second.status.codec.openedRecords == 1 && !pair.second.status.active,
            "Post-authentication cancellation still prevents publication")
    }

    static func blockedIO() throws {
        for concurrent in [false, true] {
            let pair = try FixturePair(blockReceive: true), expected = try expectation(.exact(64))
            try pair.first.send(Data(repeating: 1, count: 64), expecting: expected, check: {})
            let outcome = FixtureOutcome(), done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                defer { done.signal() }
                do { _ = try pair.second.receive(expecting: expected, check: {}); outcome.success() }
                catch { outcome.failure() }
            }
            try require(pair.secondIO.entered!.wait(timeout: .now() + 1) == .success, "Receive entered")
            if concurrent { try refuses { _ = try pair.second.receive(expecting: expected, check: {}) } }
            else { pair.second.invalidate() }
            try require(!pair.second.status.active && pair.second.status.operationInFlight,
                "Invalidation returns while underlying IO remains owned/in flight")
            pair.secondIO.resume!.signal()
            try require(done.wait(timeout: .now() + 1) == .success, "Owned fixture operation joined")
            try require(outcome.wasRefused && !pair.second.status.operationInFlight,
                "Blocked cancelled receive never publishes payload")
        }
    }

    static func accounting() throws {
        let size = 5 * 1024 * 1024, ceiling = 16 * 1024 * 1024
        let exact = try ClusterRecordTransferAccounting(length: .exact(size), maximumTransportFrameBytes: ceiling)
        try require(exact.maximumFrameByteCounts == [size + 40] && exact.additionalFramingDataBytes == 0,
            "Exact frame charge")
        let variable = try ClusterRecordTransferAccounting(length: .bounded(maximum: size), maximumTransportFrameBytes: ceiling)
        try require(variable.maximumFrameByteCounts == [24, size + 16]
            && variable.additionalFramingDataBytes == size + 40, "Variable frame/copy charge")
        try refuses { _ = try ClusterRecordTransferAccounting(length: .exact(ceiling), maximumTransportFrameBytes: ceiling) }
        let envelope = try ClusterRecordTransferEnvelope(entries: [(.exact(size), 16), (.exact(10 * 1024), 127)],
            maximumTransportFrameBytes: ceiling)
        try require(envelope.records == 143 && envelope.nativeTransfers == 143
            && envelope.sealedBytes == envelope.plaintextBytes + 143 * 40, "Worst-case directional request envelope")
        let limits = try ClusterRecordLimits(maximumPlaintextBytes: size, maximumRecordsPerDirection: 143,
            maximumCumulativePlaintextBytesPerDirection: envelope.plaintextBytes)
        try envelope.requireRemaining(usedRecords: 0, usedPlaintextBytes: 0, limits: limits)
        try refuses { try envelope.requireRemaining(usedRecords: 1, usedPlaintextBytes: 0, limits: limits) }
        try refuses { try envelope.requireRemaining(usedRecords: 0, usedPlaintextBytes: 1, limits: limits) }
        try refuses { _ = try ClusterRecordTransferEnvelope(entries: [(.exact(64), UInt64.max)],
            maximumTransportFrameBytes: ceiling) }
        try refuses { _ = try expectation(.exact(0)) }
        try refuses { _ = try expectation(.bounded(maximum: -1)) }
    }
}
