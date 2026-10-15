import Foundation
import DarkbloomClusterProtocol

private struct StartupCheckFailure: Error { let message: String }
private func require(_ value: Bool, _ message: String) throws {
    if !value { throw StartupCheckFailure(message: message) }
}

@main enum StartupPreparationCheck {
    static func main() throws {
        let legacy = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let old = try ClusterRuntimeCapabilityCodec.decode(legacy)
        try require(old.startupPreparation == nil, "Legacy descriptor acquired startup work")
        try require(try ClusterRuntimeCapabilityCodec.encode(old) == legacy, "Legacy canonical bytes changed")
        let recipe: [String: Any] = ["kind": "configuredChunkAndDecode_v1", "requestCount": 1,
                                    "tokenPattern": [1, 2], "outputCount": 2]
        func encoded(_ modify: (inout [String: Any]) -> Void) throws -> Data {
            var value = try JSONSerialization.jsonObject(with: legacy) as! [String: Any]
            value["startupPreparation"] = recipe; modify(&value)
            var result = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
            result.append(10); return result
        }
        let bytes = try encoded { _ in }
        let value = try ClusterRuntimeCapabilityCodec.decode(bytes)
        guard let preparation = value.startupPreparation else { throw StartupCheckFailure(message: "Missing recipe") }
        try require(try ClusterRuntimeCapabilityCodec.encode(value) == bytes, "Recipe is not canonical")
        try require(value.profile == old.profile && value.partitions == old.partitions
            && value.maxRequests == 16 && value.maxLifetimeSeconds == 300 && !value.prefixReuse,
            "Startup metadata changed profile, quota, lifetime or state reuse")
        let request = try preparation.reservation(profile: value.profile, chunkSize: 512,
            deadlineUptimeNanoseconds: 99, capacityLimitBytes: 123)
        try require(request.promptTokenIDs == (0..<512).map { $0 % 2 + 1 }
            && request.outputCount == 2 && request.chunkSize == 512 && request.stopTokenIDs.isEmpty
            && request.deadlineUptimeNanoseconds == 99 && request.capacityLimitBytes == 123,
            "Recipe changed the caller deadline/capacity or selected geometry")
        let small = try preparation.reservation(profile: value.profile, chunkSize: 1,
            deadlineUptimeNanoseconds: 99, capacityLimitBytes: 123)
        try require(small.promptTokenIDs == [1] && small.outputCount == 2, "Small selected chunk differs")
        var rejected = 0
        func no(_ operation: () throws -> Void) throws {
            do { try operation() } catch { rejected += 1; return }
            throw StartupCheckFailure(message: "Malformed recipe accepted")
        }
        let wrongTypes: [Any] = [NSNull(), false, "recipe"]
        for replacement in wrongTypes {
            try no { _ = try ClusterRuntimeCapabilityCodec.decode(encoded { $0["startupPreparation"] = replacement }) }
        }
        let invalid: [(String, Any)] = [("kind", "unknown"), ("requestCount", 0), ("requestCount", 2),
            ("requestCount", true), ("tokenPattern", []), ("tokenPattern", Array(repeating: 1, count: 17)),
            ("tokenPattern", [-1]), ("tokenPattern", [248320]), ("tokenPattern", [true]),
            ("tokenPattern", [1.5]), ("outputCount", 1), ("outputCount", 9), ("outputCount", true), ("extra", 1)]
        for (key, replacement) in invalid {
            try no {
                _ = try ClusterRuntimeCapabilityCodec.decode(encoded { object in
                    var item = recipe; item[key] = replacement; object["startupPreparation"] = item
                })
            }
        }
        for key in recipe.keys.sorted() {
            try no {
                _ = try ClusterRuntimeCapabilityCodec.decode(encoded { object in
                    var item = recipe; item.removeValue(forKey: key); object["startupPreparation"] = item
                })
            }
        }
        try no { _ = try ClusterRuntimeCapabilityCodec.decode(encoded { $0["maxRequests"] = 1 }) }
        try no {
            _ = try ClusterRuntimeCapabilityCodec.decode(encoded { object in
                var profile = object["profile"] as! [String: Any]
                profile["maximumOutputTokens"] = 1; object["profile"] = profile
            })
        }
        for chunk in [0, 513, Int.max] {
            try no { _ = try preparation.reservation(profile: value.profile, chunkSize: chunk,
                deadlineUptimeNanoseconds: 99, capacityLimitBytes: 123) }
        }
        try no { _ = try preparation.reservation(profile: value.profile, chunkSize: 512,
            deadlineUptimeNanoseconds: 0, capacityLimitBytes: 123) }
        try no { _ = try preparation.reservation(profile: value.profile, chunkSize: 512,
            deadlineUptimeNanoseconds: 99, capacityLimitBytes: 0) }
        print("Startup recipe: legacy bytes, canonical recipe/profile binding, selected shapes and \(rejected) refusals checked; no native work")
    }
}
