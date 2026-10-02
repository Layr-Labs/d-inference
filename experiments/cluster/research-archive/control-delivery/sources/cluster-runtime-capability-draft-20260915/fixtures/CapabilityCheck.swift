import DarkbloomClusterProtocol
import DarkbloomClusterRuntime
import Darwin
import Foundation

struct CheckFailure: Error { let message: String }
@main enum CapabilityCheck {
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args.first == "--describe-runtime" { try WorkerCapabilityCommand.run(arguments: args); return }
            try checks(args)
        } catch {
            FileHandle.standardError.write(Data("REFUSED: \(error)\n".utf8)); Darwin.exit(1)
        }
    }

    static func checks(_ args: [String]) throws {
        guard args.count == 1 else { throw CheckFailure(message: "Expected retained metadata fixture") }
        let input = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[0]))) as! [String: [String: Any]]
        func metadata(_ model: String, _ name: String) -> Data { Data(base64Encoded: input[model]![name] as! String)! }
        let config = metadata("nine", "configuration"), manifest = metadata("nine", "manifest")
        let value = try QwenResidentCapabilityMetadata.describe(configuration: config, manifest: manifest, runtimeBinarySHA256: String(repeating: "1", count: 64))
        let encoded = try ClusterRuntimeCapabilityCodec.encode(value)
        var accepted: [String] = [], rejected: [String] = []
        func require(_ condition: Bool, _ message: String) throws { if !condition { throw CheckFailure(message: message) } }
        func yes(_ name: String, _ body: () throws -> Void) throws { try body(); accepted.append(name) }
        func no(_ name: String, _ body: () throws -> Void) throws {
            do { try body() } catch { rejected.append(name); return }
            throw CheckFailure(message: "Unexpected acceptance: " + name)
        }
        func modified(_ edit: (inout [String: Any]) -> Void) throws -> Data {
            var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            edit(&object)
            var result = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            result.append(10); return result
        }
        func refuse(_ name: String, _ edit: (inout [String: Any]) -> Void) throws {
            let bytes = try modified(edit); try no(name) { _ = try ClusterRuntimeCapabilityCodec.decode(bytes) }
        }
        func profileEdit(_ key: String, _ replacement: Any) throws {
            try refuse("profile-" + key + "-" + String(describing: replacement)) { object in
                var profile = object["profile"] as! [String: Any]; profile[key] = replacement; object["profile"] = profile
            }
        }
        func partitionEdit(_ name: String, _ edit: (inout [[String: Any]]) -> Void) throws {
            try refuse(name) { object in var partitions = object["partitions"] as! [[String: Any]]; edit(&partitions); object["partitions"] = partitions }
        }
        try yes("canonical-roundtrip") { try require(try ClusterRuntimeCapabilityCodec.decode(encoded) == value, "Roundtrip differs") }
        try yes("exact-native-profile-and-arithmetic") {
            try require(value.profileFingerprint == "73532005bbf8385dc43db4bdb529bcd5d612af7d1055becbefe721b4be2324ff", "Profile recipe changed")
            try require(value.arithmeticPolicySHA256 == "0ae9c7c21048fa94fc90353b84cd8578f4adc05b1b22c3d55bd70f01c9c3bc74", "Arithmetic receipt changed")
            try require(value.profile.maximumPromptTokens == 8192 && value.profile.maximumOutputTokens == 128
                && value.profile.maximumChunkTokens == 512 && value.profile.maximumContextTokens == 8320, "Native bounds differ")
        }
        try yes("native-cut4-plan-and-complete-partitions") {
            try require(value.partitions[0].planSHA256 == "67bf0b1bf94f229682df58ae1ae10c758e2a386d66d3e1b68146f5c090f6309f", "Known cut4 Plan differs")
            try require(value.partitions.map { $0.stages[0].sourceLayerEnd } == [4, 8, 12, 16], "Wrong admitted cuts")
            for partition in value.partitions {
                try require(try value.selection(planSHA256: partition.planSHA256) == partition, "Selection differs")
                try require(partition.stages.flatMap { Array($0.sourceLayerStart..<$0.sourceLayerEnd) } == Array(0..<32), "Partition differs")
            }
        }
        try yes("binary-binding-is-independent-of-model-identities") {
            let other = try QwenResidentCapabilityMetadata.describe(configuration: config, manifest: manifest, runtimeBinarySHA256: String(repeating: "2", count: 64))
            try require(other.runtimeBinarySHA256 != value.runtimeBinarySHA256 && other.partitions == value.partitions
                && other.profileFingerprint == value.profileFingerprint, "Binary identity substituted model identity")
        }
        try no("unknown-plan-selection") { _ = try value.selection(planSHA256: String(repeating: "f", count: 64)) }
        try no("unknown-model-metadata") { _ = try QwenResidentCapabilityMetadata.describe(configuration: metadata("twentySeven", "configuration"), manifest: metadata("twentySeven", "manifest"), runtimeBinarySHA256: value.runtimeBinarySHA256) }
        try no("changed-config") { _ = try QwenResidentCapabilityMetadata.describe(configuration: config + Data([32]), manifest: manifest, runtimeBinarySHA256: value.runtimeBinarySHA256) }
        try no("changed-manifest") { _ = try QwenResidentCapabilityMetadata.describe(configuration: config, manifest: manifest + Data([32]), runtimeBinarySHA256: value.runtimeBinarySHA256) }
        try no("oversized-config") { _ = try QwenResidentCapabilityMetadata.describe(configuration: Data(repeating: 32, count: 1_048_577), manifest: manifest, runtimeBinarySHA256: value.runtimeBinarySHA256) }
        for (key, replacement): (String, Any) in [
            ("adapterID", "unknown"), ("adapterVersion", 2), ("runtimeModelID", "registered_qwen38_27b"),
            ("workerProtocolVersion", 2), ("ownerProtocolVersion", 2), ("bootstrapABIVersion", 2),
            ("rankCount", 3), ("batchSize", 2), ("maxActiveRequests", 2), ("maxLifetimeSeconds", 301),
            ("maxRequests", 17), ("schedulingPolicy", "oneChunkLookahead"), ("selectionPolicy", "sampling"),
            ("speculation", "mtp"), ("prefixReuse", true), ("prefixReuse", 0), ("modality", "image"),
            ("stopPolicy", "string"), ("arithmeticPolicyID", "unknown"), ("stateSemantics", "sharedCache"),
            ("runtimeBinarySHA256", String(repeating: "A", count: 64)), ("adapterVersion", true), ("schema", NSNull()),
        ] { try refuse("closed-field-" + key + "-" + String(describing: replacement)) { $0[key] = replacement } }
        try refuse("unknown-top-key") { $0["ready"] = true }
        try refuse("missing-key") { $0.removeValue(forKey: "manifestSHA256") }
        try profileEdit("id", "unknown"); try profileEdit("extra", 1); try profileEdit("maximumContextTokens", Int.min)
        try profileEdit("maximumContextTokens", Int.max); try profileEdit("maximumContextTokens", 8192)
        try profileEdit("maximumPromptTokens", 0); try profileEdit("maximumOutputTokens", true)
        try partitionEdit("duplicate-plan") { $0[1]["planSHA256"] = $0[0]["planSHA256"] }
        try partitionEdit("unknown-kind") { $0[0]["kind"] = "tensorParallel" }
        try partitionEdit("unordered-partitions") { $0.swapAt(0, 1) }
        try partitionEdit("partition-extra-field") { $0[0]["extra"] = 1 }
        for (name, rank, key, replacement): (String, Int, String, Any) in [
            ("gap", 1, "sourceLayerStart", 5), ("overlap", 1, "sourceLayerStart", 3),
            ("wrong-rank", 0, "rank", 1), ("partial", 0, "sourceLayerStart", 1),
            ("inconsistent-end", 1, "sourceLayerEnd", 31), ("stage-extra", 0, "extra", true),
            ("stage-bool", 0, "rank", false), ("negative-start", 1, "sourceLayerStart", Int.min),
        ] {
            try partitionEdit(name) { parts in var stages = parts[0]["stages"] as! [[String: Any]]; stages[rank][key] = replacement; parts[0]["stages"] = stages }
        }
        let text = String(decoding: encoded, as: UTF8.self)
        for (name, bytes) in [
            ("missing-LF", Data(encoded.dropLast())), ("extra-LF", encoded + Data([10])),
            ("leading-space", Data([32]) + encoded), ("oversized", Data(repeating: 32, count: 16 * 1024 + 1)),
            ("duplicate-key", Data(text.replacingOccurrences(of: "\"adapterVersion\":1", with: "\"adapterVersion\":1,\"adapterVersion\":1").utf8)),
            ("escaped-duplicate", Data(text.replacingOccurrences(of: "\"adapterVersion\":1", with: "\"adapterVersion\":1,\"\\u0061dapterVersion\":1").utf8)),
            ("fraction", Data(text.replacingOccurrences(of: "\"adapterVersion\":1", with: "\"adapterVersion\":1.0").utf8)),
            ("exponent", Data(text.replacingOccurrences(of: "\"adapterVersion\":1", with: "\"adapterVersion\":1e0").utf8)),
            ("int-overflow", Data(text.replacingOccurrences(of: "\"adapterVersion\":1", with: "\"adapterVersion\":18446744073709551615").utf8)),
            ("negative-zero", Data(text.replacingOccurrences(of: "\"rank\":0", with: "\"rank\":-0").utf8)),
        ] { try no(name) { _ = try ClusterRuntimeCapabilityCodec.decode(bytes) } }

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = temporary.appendingPathComponent("bytes"), link = temporary.appendingPathComponent("link"), fifo = temporary.appendingPathComponent("fifo")
        try Data("abc".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        guard mkfifo(fifo.path, 0o600) == 0 else { throw CheckFailure(message: "Cannot create fixture FIFO") }
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        try yes("regular-file-and-streaming-hash") {
            try require(try WorkerCapabilityInput.read(file.path, maximumBytes: 3, deadline: deadline) == Data("abc".utf8), "Read differs")
            try require(try WorkerCapabilityInput.hash(file.path, maximumBytes: 3, deadline: deadline) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "Hash differs")
        }
        try no("read-size-bound") { _ = try WorkerCapabilityInput.read(file.path, maximumBytes: 2, deadline: deadline) }
        try no("read-symlink") { _ = try WorkerCapabilityInput.read(link.path, maximumBytes: 3, deadline: deadline) }
        try no("read-directory") { _ = try WorkerCapabilityInput.read(temporary.path, maximumBytes: 3, deadline: deadline) }
        try no("read-fifo-does-not-block") { _ = try WorkerCapabilityInput.read(fifo.path, maximumBytes: 3, deadline: deadline) }
        try no("expired-read") { _ = try WorkerCapabilityInput.read(file.path, maximumBytes: 3, deadline: 0) }
        let validArgs = ["--describe-runtime", "--config", "/config", "--manifest", "/manifest", "--expected-executable-sha256", value.runtimeBinarySHA256]
        try yes("explicit-command") { _ = try WorkerCapabilityCommand.Arguments(validArgs) }
        try no("command-extra") { _ = try WorkerCapabilityCommand.Arguments(validArgs + ["--mtp"]) }
        try no("command-empty") { var a = validArgs; a[2] = ""; _ = try WorkerCapabilityCommand.Arguments(a) }
        try no("command-wrong-binary-pin") { var a = validArgs; a[6] = String(repeating: "A", count: 64); _ = try WorkerCapabilityCommand.Arguments(a) }
        let result: [String: Any] = ["accepted": accepted, "rejected": rejected, "capabilityBytes": encoded.count,
                                   "modelOrGPUExecution": false, "installedNativeWorkerVerified": false]
        var output = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]); output.append(10)
        FileHandle.standardOutput.write(output)
    }
}
