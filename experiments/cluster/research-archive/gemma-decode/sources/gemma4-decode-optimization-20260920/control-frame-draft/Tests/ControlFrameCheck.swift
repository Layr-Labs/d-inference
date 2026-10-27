import Foundation

@main enum ControlFrameCheck {
    static func main() throws {
        var passed: [String] = []
        func require(_ value: Bool, _ label: String) throws {
            guard value else { throw NSError(domain: "ControlFrameCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
            passed.append(label)
        }
        func refusal(_ label: String, _ expected: PaddedControlFrame.Failure,
                     _ body: () throws -> Void) throws {
            var found: PaddedControlFrame.Failure?
            do { try body() } catch { found = error as? PaddedControlFrame.Failure }
            try require(found == expected, label)
        }
        let payload = Data([0x7b, 0x7d, 0x0a])
        let encoded = try PaddedControlFrame.encode(payload)
        try require(encoded.count == 16_384 && Array(encoded.prefix(7)) == [0,0,0,3,0x7b,0x7d,0x0a], "exact-prefix-and-payload")
        try require(encoded.dropFirst(7).allSatisfy({ $0 == 0 }), "complete-zero-tail")
        let decoded = try PaddedControlFrame.decode(encoded)
        try require(decoded == payload, "payload-roundtrip")
        let maximum = Data(repeating: 0xa5, count: 16_380)
        let maximumFrame = try PaddedControlFrame.encode(maximum)
        let maximumDecoded = try PaddedControlFrame.decode(maximumFrame)
        try require(Array(maximumFrame.prefix(4)) == [0,0,0x3f,0xfc] && maximumDecoded == maximum, "maximum-payload")
        let zeros = Data([0,0,0,0])
        let zerosDecoded = try PaddedControlFrame.decode(PaddedControlFrame.encode(zeros))
        try require(zerosDecoded == zeros, "payload-trailing-zeros-retained")
        try refusal("empty-encode", .invalidPayloadLength) { _ = try PaddedControlFrame.encode(Data()) }
        try refusal("oversized-encode", .invalidPayloadLength) { _ = try PaddedControlFrame.encode(Data(count: 16_381)) }
        try refusal("empty-frame", .invalidFrameLength) { _ = try PaddedControlFrame.decode(Data()) }
        try refusal("truncated-prefix", .invalidFrameLength) { _ = try PaddedControlFrame.decode(Data([0,0,0])) }
        try refusal("truncated-frame", .invalidFrameLength) { _ = try PaddedControlFrame.decode(encoded.dropLast()) }
        try refusal("oversized-frame", .invalidFrameLength) { _ = try PaddedControlFrame.decode(encoded + Data([0])) }
        var empty = encoded; empty.replaceSubrange(0..<4, with: [0,0,0,0])
        try refusal("zero-wire-length", .invalidPayloadLength) { _ = try PaddedControlFrame.decode(empty) }
        var tooLarge = encoded; tooLarge.replaceSubrange(0..<4, with: [0,0,0x3f,0xfd])
        try refusal("length-exceeds-body", .invalidPayloadLength) { _ = try PaddedControlFrame.decode(tooLarge) }
        var overflow = encoded; overflow.replaceSubrange(0..<4, with: [255,255,255,255])
        try refusal("uint32-maximum-length", .invalidPayloadLength) { _ = try PaddedControlFrame.decode(overflow) }
        var firstPad = encoded; firstPad[7] = 1
        try refusal("first-padding-byte", .nonzeroPadding) { _ = try PaddedControlFrame.decode(firstPad) }
        var lastPad = encoded; lastPad[16_383] = 1
        try refusal("last-padding-byte", .nonzeroPadding) { _ = try PaddedControlFrame.decode(lastPad) }
        var retained = Data([0x99]); retained.append(encoded)
        let slice = retained.dropFirst()
        let sliceDecoded = try PaddedControlFrame.decode(slice)
        try require(slice.startIndex != 0 && sliceDecoded == payload, "nonzero-data-slice-index")
        let hash = String(repeating: "f", count: 64)
        let value = Gemma4ShortWireValue(event: "probe-buffer-received", sequence: 142, frontier: 8207,
            count: 128, tokenIDsSHA256: hash, payloadSHA256: hash, tokenID: 262143, dtype: "bfloat16")
        let packet = Gemma4ShortWirePacket(schema: "gemma4_benchmark_p2p_v1", scopeSHA256: hash,
            senderRank: 1, ordinal: 511, value: value)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = try encoder.encode(packet)
        let recovered = try PaddedControlFrame.decode(PaddedControlFrame.encode(json))
        let restored = try JSONDecoder().decode(Gemma4ShortWirePacket.self, from: recovered)
        try require(json.count == 434 && json.count < PaddedControlFrame.maximumPayloadBytes
                    && recovered == json && restored.value == value, "all-fields-existing-dto-bound")
        let output = try JSONSerialization.data(withJSONObject: ["passed": passed,
            "nativeExecuted": false, "frameBytes": 16_384, "maximumPayloadBytes": 16_380,
            "allFieldsControlJSONBytes": json.count], options: [.sortedKeys])
        try FileHandle.standardOutput.write(contentsOf: output + Data([10]))
    }
}
