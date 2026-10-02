import Darwin
import Foundation

enum Gemma4ShortLocalChecks {
    static func run(directory: String) throws -> Data {
        var accepted = 0, refused = 0
        func require(_ value: Bool) throws {
            guard value else { throw ProbeError("Gemma local fixture assertion failed") }; accepted += 1
        }
        func refuses(_ body: () throws -> Void) throws {
            do { try body() } catch { refused += 1; return }
            throw ProbeError("Gemma local fixture failed to refuse")
        }
        for (sequence, offset, count) in [(0,0,16),(1,16,16),(2,32,1)] {
            let frame = try Gemma4ShortFrames.frame(sequence)
            try require(frame.tokenOffset == offset && frame.tokenCount == count && frame.finalPromptChunk == (sequence == 1))
        }
        for sequence in [-1,3,Int.max] { try refuses { _ = try Gemma4ShortFrames.frame(sequence) } }
        try require(try Gemma4ShortFrames.probeCount(0) == 2 && Gemma4ShortFrames.probeCount(1) == 1)
        try refuses { _ = try Gemma4ShortFrames.probeCount(2) }
        let scope = String(repeating: "a", count: 64), value = Gemma4ShortWireValue(event: "begin")
        let data = try canonicalJSONData(Gemma4ShortWirePacket(schema: "gemma4_short_p2p_v1",
            scopeSHA256: scope, senderRank: 0, ordinal: 0, value: value))
        try require(try Gemma4ShortWireCodec.decode(data, scope: scope, sender: 0, ordinal: 0) == value)
        try refuses { _ = try Gemma4ShortWireCodec.decode(data, scope: String(repeating: "b", count: 64), sender: 0, ordinal: 0) }
        try refuses { _ = try Gemma4ShortWireCodec.decode(data, scope: scope, sender: 1, ordinal: 0) }
        try refuses { _ = try Gemma4ShortWireCodec.decode(data, scope: scope, sender: 0, ordinal: 1) }
        var object = try QwenLayerStageGenerationWireJSON.object(data); object["extra"] = 1
        try refuses { _ = try Gemma4ShortWireCodec.decode(JSONSerialization.data(withJSONObject: object), scope: scope, sender: 0, ordinal: 0) }
        try refuses { _ = try Gemma4ShortWireCodec.decode(Data(repeating: 32, count: 16_385), scope: scope, sender: 0, ordinal: 0) }
        let sidecars = try Gemma4ShortSidecars(directory: directory)
        let bytes = Data([0,1,2,255])
        let written = try sidecars.write("state-0-kv.position_offsets.bin", data: bytes, check: {})
        try require(written.bytes == 4 && written.sha256 == sha256(bytes)
            && (try Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent(written.name))) == bytes)
        try refuses { _ = try sidecars.write(written.name, data: bytes, check: {}) }
        try refuses { _ = try sidecars.write("../escape", data: bytes, check: {}) }
        try refuses { _ = try sidecars.write("empty.bin", data: Data(), check: {}) }
        guard symlink(written.name, directory + "/link.bin") == 0 else { throw ProbeError("Gemma symlink fixture setup failed") }
        try refuses { _ = try sidecars.write("link.bin", data: bytes, check: {}) }
        try refuses { _ = try sidecars.write("cancel.bin", data: bytes, check: { throw ProbeError("fixture cancellation") }) }
        try require(sidecars.files.count == 1)
        guard rename(directory, directory + "-held") == 0, mkdir(directory, 0o700) == 0 else {
            throw ProbeError("Gemma changed-directory fixture setup failed")
        }
        try refuses { _ = try sidecars.write("changed.bin", data: bytes, check: {}) }
        return try JSONSerialization.data(withJSONObject: ["accepted": accepted, "refused": refused,
            "nativeExecuted": false, "modelConstructed": false, "payloadRead": false], options: [.sortedKeys])
    }
}
