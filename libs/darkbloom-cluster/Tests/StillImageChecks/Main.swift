import Foundation
import DarkbloomClusterProtocol

@main @MainActor enum StillImageChecks {
    static var checks = 0
    static func expect(_ value: Bool, _ label: String) throws {
        guard value else { throw Failure(label) }; checks += 1
    }
    struct Failure: Error { let label: String; init(_ label: String) { self.label = label } }
    static func refuses(_ label: String, _ action: () throws -> Void) throws {
        do { try action() } catch { checks += 1; return }
        throw Failure("Accepted " + label)
    }
    static func main() throws {
        let config = String(repeating: "a", count: 64)
        let png = Data([137,80,78,71,13,10,26,10] + Array(repeating: UInt8(0), count: 48))
        let prompt = [1,154830,154854,154854,154831,2]
        func media(offset: Int = 2, count: Int = 2, width: Int = 28, height: Int = 28,
                   bytes: Data? = nil, identity: String? = nil) -> ClusterStillImages {
            .init(configurationSHA256: identity ?? config, images: [.init(png: bytes ?? png,
                width: width, height: height, tokenOffset: offset, tokenCount: count)])
        }
        func valid(_ media: ClusterStillImages, _ tokens: [Int] = prompt) throws {
            try media.validate(prompt: tokens, imageToken: 154854, startToken: 154830, endToken: 154831, videoToken: 154855)
        }
        try valid(media()); checks += 1
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(media())
        try expect(try ClusterStillImages.decodeBounded(encoded) == media(), "image round trip")
        try expect(media().fingerprint != media(bytes: png + Data([1])).fingerprint, "pixel commitment")
        try expect(media().fingerprint != media(identity: String(repeating: "b", count: 64)).fingerprint, "config commitment")
        try expect(media().fingerprint != media(offset: 3).fingerprint, "position commitment")
        for value in [media(offset: -1), media(offset: Int.max), media(count: Int.max), media(count: 0),
                      media(width: Int.max), media(height: 0), media(identity: "A"),
                      media(bytes: Data(repeating: 0, count: ClusterStillImages.maximumEncodedBytes + 1))] {
            try refuses("bad structure") { try valid(value) }
        }
        try refuses("unowned marker") { try valid(media(), prompt + [154854]) }
        try refuses("video") { try valid(media(), prompt + [154855]) }
        try refuses("bad bracket") { try valid(media(), [1,3,154854,154854,154831,2]) }
        try refuses("span token mismatch") { try valid(media(), [1,154830,154854,3,154831,2]) }
        try refuses("zero images") { try valid(.init(configurationSHA256: config, images: [])) }
        try refuses("multiple images") { try valid(.init(configurationSHA256: config, images: media().images + media().images)) }
        try refuses("duplicate key") { _ = try ClusterStillImages.decodeBounded(Data("{\"images\":[],\"images\":[]}".utf8)) }
        try refuses("unknown key") {
            var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            object["url"] = "file:///not-permitted"
            _ = try ClusterStillImages.decodeBounded(JSONSerialization.data(withJSONObject: object))
        }
        try refuses("oversized envelope") { _ = try ClusterStillImages.decodeBounded(Data(repeating: 32, count: 135_001)) }
        let epoch = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        func frame(_ images: ClusterStillImages?, profile: String = ClusterStillImages.glmProfileID,
                   route: ClusterWorkerRoute? = nil) -> ClusterWorkerCommandFrame {
            .init(membershipEpoch: epoch, sequence: 0, requestID: id, command: .reserve(.init(
                profileID: profile, promptTokenIDs: prompt, stopTokenIDs: [2], outputCount: 1, chunkSize: 4,
                deadlineUptimeNanoseconds: 100, capacityLimitBytes: 1024, sampling: nil,
                route: route, stillImages: images)))
        }
        let wire = try ClusterWorkerCodec.encode(frame(media()))
        let decoded = try ClusterWorkerCodec.decodeCommand(wire)
        guard case .reserve(let reservation) = decoded.command else { throw Failure("reservation roundtrip") }
        try expect(reservation.stillImages == media(), "reservation preserves image")
        let text = try ClusterWorkerCodec.encode(frame(nil))
        try expect(!String(decoding: text, as: UTF8.self).contains("stillImages"), "nil omits field")
        try refuses("foreign profile") { _ = try ClusterWorkerCodec.encode(frame(media(), profile: "qwen")) }
        try refuses("alternate route") { _ = try ClusterWorkerCodec.encode(frame(media(), route: .decodingRankAlone)) }
        print("Still-image CPU protocol checks passed: \(checks)")
    }
}
