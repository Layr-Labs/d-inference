import Foundation
import DarkbloomClusterProtocol

private struct Failure: Error { let message: String }
private func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(message: message) }
}
private func refuses(_ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw Failure(message: "Invalid media was accepted")
}

@main struct QwenMediaChecks {
    static let imageToken = 20, videoToken = 21, startToken = 22, endToken = 23
    static let tokens = [1, 22] + Array(repeating: 20, count: 4) + [23, 2, 22]
        + Array(repeating: 21, count: 8) + [23, 3]
    static let hash = String(repeating: "a", count: 64)
    static func fixture(_ bytes: Data = Data([0, 1, 2])) -> ClusterQwenMedia {
        .init(artifactSHA256: hash, configurationSHA256: hash, processorSHA256: hash,
            processorPolicy: .qwen35, promptLength: tokens.count,
            promptSHA256: ClusterQwenMedia.int32SHA256(tokens.map(Int32.init)),
            positionIDsSHA256: hash, decodeDeltas: [-4], items: [
                .init(kind: .image, sha256: ClusterQwenMedia.sha256(bytes), byteCount: bytes.count,
                    decodedPixels: 4096, encoded: bytes, temporal: 1, height: 4, width: 4, tokenOffset: 2,
                    tokenCount: 4, patchesSHA256: hash),
                .init(kind: .video, sha256: ClusterQwenMedia.sha256(bytes), byteCount: bytes.count,
                    decodedPixels: 4096, encoded: bytes, temporal: 2, height: 4, width: 4, tokenOffset: 9,
                    tokenCount: 8, patchesSHA256: hash),
            ])
    }
    static func validate(_ media: ClusterQwenMedia, prompt: [Int] = tokens, limit: Int = 32) throws {
        try media.validate(prompt: prompt, imageToken: imageToken, videoToken: videoToken,
            startToken: startToken, endToken: endToken, maximumPromptTokens: limit)
    }
    static func mutate(_ media: ClusterQwenMedia = fixture(), _ edit: (inout [String: Any]) -> Void) throws -> ClusterQwenMedia {
        var object = try JSONSerialization.jsonObject(with: media.encoded()) as! [String: Any]
        edit(&object)
        return try .decodeBounded(JSONSerialization.data(withJSONObject: object, options: .sortedKeys))
    }
    static func mutateItem(_ media: ClusterQwenMedia = fixture(), _ index: Int = 0,
                           _ edit: (inout [String: Any]) -> Void) throws -> ClusterQwenMedia {
        try mutate(media) { root in
            var items = root["items"] as! [[String: Any]]; edit(&items[index]); root["items"] = items
        }
    }
    static func frame(_ media: ClusterQwenMedia?, prompt: [Int] = tokens) -> ClusterWorkerCommandFrame {
        .init(membershipEpoch: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, sequence: 0,
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            command: .reserve(.init(profileID: "registered_qwen38_27b_greedy_generation_v1", promptTokenIDs: prompt,
                stopTokenIDs: [], outputCount: 8, chunkSize: 4, deadlineUptimeNanoseconds: 1,
                capacityLimitBytes: 1 << 30, sampling: nil, prefixCache: nil, qwenMedia: media)))
    }

    static func main() throws {
        let media = fixture()
        try validate(media); try media.verifyEncodedBytes()
        let decoded = try ClusterQwenMedia.decodeBounded(media.encoded())
        try check(decoded == media, "Exact carrier round trip")
        let follower = media.withoutEncodedBytes
        try validate(follower)
        try check(!follower.carriesEncodedBytes && follower.items.allSatisfy { $0.encoded == nil }, "Follower received payload")
        try check(follower.fingerprint == media.fingerprint, "Rank identities differ")
        try refuses { try follower.verifyEncodedBytes() }
        try check(try ClusterWorkerCodec.decodeCommand(ClusterWorkerCodec.encode(frame(media))) == frame(media), "Worker carrier lost")
        try check(try ClusterWorkerCodec.decodeCommand(ClusterWorkerCodec.encode(frame(follower))) == frame(follower), "Follower carrier lost")
        let text = try ClusterWorkerCodec.encode(frame(nil))
        try check(!String(decoding: text, as: UTF8.self).contains("qwenMedia"), "Nil media changed text wire")
        var changed = tokens; changed[0] = 4
        try refuses { try validate(media, prompt: changed) }
        try refuses { _ = try ClusterWorkerCodec.encode(frame(media, prompt: changed)) }
        try refuses { try validate(media, limit: tokens.count - 1) }
        let wrongMarker = try mutate(media) { $0["promptSHA256"] = ClusterQwenMedia.int32SHA256(changed.map(Int32.init)) }
        try check(wrongMarker.fingerprint != media.fingerprint, "Prompt missing from fingerprint")

        for key in ["artifactSHA256", "configurationSHA256", "processorSHA256", "positionIDsSHA256"] {
            let changedIdentity = try mutate(media) { $0[key] = String(repeating: "b", count: 64) }
            try check(changedIdentity.fingerprint != media.fingerprint, "Identity missing from fingerprint")
            try refuses { _ = try mutate(media) { $0[key] = "bad" } }
        }
        try refuses { _ = try mutate(media) { $0["contract"] = "glm53_tp_media_v1" } }
        try refuses { _ = try mutate(media) { $0["processorPolicy"] = "unchecked" } }
        try refuses { _ = try mutate(media) { $0["unknown"] = 1 } }
        try refuses { _ = try mutate(media) { $0["promptLength"] = true } }
        try refuses { _ = try mutate(media) { $0["decodeDeltas"] = [Int64(Int32.max) + 1] } }
        try refuses { _ = try mutate(media) { $0["decodeDeltas"] = [] } }
        try refuses { _ = try mutate(media) { $0["decodeDeltas"] = [0, 0] } }
        let delta = try mutate(media) { $0["decodeDeltas"] = [-3] }
        try check(delta.fingerprint != media.fingerprint, "Decode delta missing from fingerprint")
        var duplicate = String(decoding: try media.encoded(), as: UTF8.self)
        duplicate.insert(contentsOf: "\"promptLength\":19,", at: duplicate.index(after: duplicate.startIndex))
        try refuses { _ = try ClusterQwenMedia.decodeBounded(Data(duplicate.utf8)) }

        for bad in [Int.min, -1, 0, 3, Int.max] {
            try refuses { _ = try mutateItem { $0["height"] = bad } }
        }
        for (key, value) in [("width", Int.max), ("temporal", 2), ("tokenCount", 5),
                             ("tokenOffset", 0), ("tokenOffset", tokens.count - 4),
                             ("byteCount", ClusterQwenMedia.maximumEncodedBytes + 1)] {
            try refuses { _ = try mutateItem { $0[key] = value } }
        }
        try refuses { _ = try mutateItem(media, 1) { $0["temporal"] = 5 } }
        try refuses { _ = try mutateItem(media, 1) { $0["tokenOffset"] = 3 } }
        try refuses { _ = try mutateItem { $0["byteCount"] = true } }
        try refuses { _ = try mutateItem { $0["encoded"] = "$" } }
        try refuses { _ = try mutateItem { $0.removeValue(forKey: "encoded") } }
        let tampered = try mutateItem { $0["encoded"] = Data([9, 8, 7]).base64EncodedString() }
        try refuses { try tampered.verifyEncodedBytes() }
        for value in [0, -1, ClusterQwenMedia.maximumItemPixels + 1, Int.max] {
            try refuses { _ = try mutateItem { $0["decodedPixels"] = value } }
        }
        try refuses { _ = try mutateItem { $0["decodedPixels"] = true } }
        try refuses { _ = try mutateItem { $0.removeValue(forKey: "decodedPixels") } }
        let differentRaster = try mutateItem { $0["decodedPixels"] = 4097 }
        try check(differentRaster.fingerprint != media.fingerprint, "Source raster omitted from fingerprint")
        let wrongPatches = try mutateItem { $0["patchesSHA256"] = String(repeating: "c", count: 64) }
        try check(wrongPatches.fingerprint != media.fingerprint, "Patch receipt missing from fingerprint")
        try refuses { _ = try mutate(media) { $0["items"] = ( $0["items"] as! [[String: Any]]).reversed().map { $0 } } }
        try refuses { _ = try mutate(media) { $0["items"] = [] } }

        let memory = try media.memory(hiddenSize: 5120, elementBytes: 2)
        try check(memory.encodedBytes == 6 && memory.positionBytes == tokens.count * 3 * 4,
            "Encoded or position memory underquoted")
        try check(memory.patchesBytes == 12 * 4 * 1536 * 4 && memory.featureBytes == 12 * 5120 * 2,
            "Patch or feature memory underquoted")
        try check(memory.largestTowerPatches == 32, "Video tower must include all temporal frames")
        try refuses { _ = try media.memory(hiddenSize: Int.max, elementBytes: 4) }
        try refuses { _ = try media.memory(hiddenSize: 5120, elementBytes: 1) }
        try check(ClusterQwenMedia.int32SHA256([1, -2]) == ClusterQwenMedia.sha256(Data([1, 0, 0, 0, 254, 255, 255, 255])),
            "Position hash is not canonical little-endian Int32")

        // A larger encoded local payload uses the existing bounded media
        // command allowance. Its metadata-only follower still uses normal IO.
        let large = fixture(Data(repeating: 7, count: 4 * 1024 * 1024))
        let encoded = try ClusterWorkerCodec.encode(frame(large))
        try check(encoded.count > ClusterWorkerLimits.commandBytes && encoded.count < ClusterWorkerLimits.mediaCommandBytes,
            "Large local media allowance missing")
        _ = try ClusterWorkerCodec.decodeCommand(encoded)
        try check(try ClusterWorkerCodec.encode(frame(large.withoutEncodedBytes)).count < ClusterWorkerLimits.commandBytes,
            "Follower carries encoded bytes")
        print("{\"passed\":true,\"groups\":9,\"modelExecution\":false,\"gpuUsed\":false,\"scope\":\"actual media carrier, codec and bounded arithmetic; no media recognition claim\"}")
    }
}
