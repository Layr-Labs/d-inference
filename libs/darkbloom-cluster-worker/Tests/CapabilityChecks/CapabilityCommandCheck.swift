import DarkbloomClusterProtocol
import DarkbloomClusterRuntime
import Darwin
import Foundation

@main enum CapabilityCommandCheck {
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args.first == "--describe-runtime" { try WorkerCapabilityCommand.run(arguments: args); return }
            guard args.count == 2 else { throw CapabilityCheckFailure(message: "Expected metadata and capability fixtures") }
            var checks = CapabilityCheckResults()
            let fixtures = URL(fileURLWithPath: args[0])
            let configuration = try Data(contentsOf: fixtures.appendingPathComponent("registered-qwen35-9b.configuration.json"))
            let manifest = try Data(contentsOf: fixtures.appendingPathComponent("registered-qwen35-9b.manifest.json"))
            let golden = try ClusterRuntimeCapabilityCodec.decode(Data(contentsOf: URL(fileURLWithPath: args[1])))
            let binary = String(repeating: "1", count: 64)
            try checks.yes("actual-native-metadata-matches-golden-profile-and-four-plans") {
                let value = try QwenResidentCapabilityMetadata.describe(configuration: configuration, manifest: manifest, runtimeBinarySHA256: binary)
                try capabilityCheck(value.supportedPrefillSchedules == [.serial, .oneChunkLookahead], "Adapter schedules differ")
                try capabilityCheck(value.supportedGenerationModes == [.pipeline, .pipelineCompactDecode, .phaseSplit],
                    "Adapter generation modes differ")
                var current = try JSONSerialization.jsonObject(with: ClusterRuntimeCapabilityCodec.encode(value)) as! [String: Any]
                current.removeValue(forKey: "supportedPrefillSchedules")
                current.removeValue(forKey: "supportedGenerationModes")
                var legacy = try JSONSerialization.data(withJSONObject: current, options: [.sortedKeys, .withoutEscapingSlashes])
                legacy.append(10)
                try capabilityCheck(try ClusterRuntimeCapabilityCodec.decode(legacy) == golden,
                    "Native metadata changed beyond advertised prefill schedules and generation modes")
            }
            // The 27B's row carries the same modes; nothing else in its record depends on them.
            try checks.yes("registered-27b-advertises-its-own-rows-modes") {
                let large = try QwenResidentCapabilityMetadata.describe(
                    configuration: try Data(contentsOf: fixtures.appendingPathComponent("registered-qwen38-27b.configuration.json")),
                    manifest: try Data(contentsOf: fixtures.appendingPathComponent("registered-qwen38-27b.manifest.json")),
                    runtimeBinarySHA256: binary)
                try capabilityCheck(large.runtimeModelID == "registered_qwen38_27b"
                    && large.supportedGenerationModes == [.pipeline, .pipelineCompactDecode, .phaseSplit]
                    && large.partitions.count == 15, "The 27B capability differs from its resident row")
                try capabilityCheck(try ClusterRuntimeCapabilityCodec.decode(ClusterRuntimeCapabilityCodec.encode(large)) == large,
                    "The 27B capability does not round-trip within the byte bound")
            }
            // The Prism Hadamard pack has the 27B's geometry and cuts under its own adapter
            // and arithmetic policy; its Plans are its own because its configuration is.
            try checks.yes("registered-bonsai-is-described-under-its-own-adapter-and-policy") {
                let large = try QwenResidentCapabilityMetadata.describe(
                    configuration: try Data(contentsOf: fixtures.appendingPathComponent("registered-qwen38-27b.configuration.json")),
                    manifest: try Data(contentsOf: fixtures.appendingPathComponent("registered-qwen38-27b.manifest.json")),
                    runtimeBinarySHA256: binary)
                let packed = try QwenResidentCapabilityMetadata.describe(
                    configuration: try Data(contentsOf: fixtures.appendingPathComponent("registered-ternary-bonsai-2-27b.configuration.json")),
                    manifest: try Data(contentsOf: fixtures.appendingPathComponent("registered-ternary-bonsai-2-27b.manifest.json")),
                    runtimeBinarySHA256: binary)
                try capabilityCheck(packed.runtimeModelID == "registered_ternary_bonsai_2_27b"
                    && packed.profile.id == "registered_ternary_bonsai_2_27b_greedy_generation_v1"
                    && packed.adapterID == ClusterRuntimeAdapter.qwen35PrismHadamard.rawValue
                    && packed.arithmeticPolicyID == ClusterRuntimeAdapter.qwen35PrismHadamard.arithmeticPolicyID
                    && packed.supportedGenerationModes == [.pipeline, .pipelineCompactDecode, .phaseSplit]
                    && packed.supportedPrefillSchedules == [.serial, .oneChunkLookahead]
                    && packed.partitions.count == 15, "The Bonsai capability differs from its resident row")
                try capabilityCheck(packed.partitions.map { $0.stages.map(\.sourceLayerEnd) }
                    == large.partitions.map { $0.stages.map(\.sourceLayerEnd) }
                    && Set(packed.partitions.map(\.planSHA256)).isDisjoint(with: large.partitions.map(\.planSHA256))
                    && packed.profileFingerprint != large.profileFingerprint
                    && packed.arithmeticPolicySHA256 != large.arithmeticPolicySHA256
                    && large.adapterID == ClusterRuntimeAdapter.qwen35Dense.rawValue
                    && large.arithmeticPolicyID == ClusterRuntimeAdapter.qwen35Dense.arithmeticPolicyID,
                    "The Bonsai capability borrows the 27B's plans, profile, adapter or arithmetic")
                try capabilityCheck(try ClusterRuntimeCapabilityCodec.decode(ClusterRuntimeCapabilityCodec.encode(packed)) == packed,
                    "The Bonsai capability does not round-trip within the byte bound")
                // A capability that names the pack under the dense adapter or the dense policy is refused.
                var crossed = try JSONSerialization.jsonObject(with: ClusterRuntimeCapabilityCodec.encode(packed)) as! [String: Any]
                crossed["arithmeticPolicyID"] = ClusterRuntimeAdapter.qwen35Dense.arithmeticPolicyID
                var bytes = try JSONSerialization.data(withJSONObject: crossed, options: [.sortedKeys, .withoutEscapingSlashes]); bytes.append(10)
                try capabilityCheck((try? ClusterRuntimeCapabilityCodec.decode(bytes)) == nil, "The dense arithmetic policy was accepted for the pack")
                crossed = try JSONSerialization.jsonObject(with: ClusterRuntimeCapabilityCodec.encode(packed)) as! [String: Any]
                crossed["adapterID"] = ClusterRuntimeAdapter.qwen35Dense.rawValue
                bytes = try JSONSerialization.data(withJSONObject: crossed, options: [.sortedKeys, .withoutEscapingSlashes]); bytes.append(10)
                try capabilityCheck((try? ClusterRuntimeCapabilityCodec.decode(bytes)) == nil, "The dense adapter was accepted for the pack")
            }
            try checks.yes("binary-binding-remains-separate-from-model-identities") {
                let value = try QwenResidentCapabilityMetadata.describe(configuration: configuration, manifest: manifest, runtimeBinarySHA256: String(repeating: "2", count: 64))
                try capabilityCheck(value.runtimeBinarySHA256 != golden.runtimeBinarySHA256 && value.partitions == golden.partitions
                    && value.profileFingerprint == golden.profileFingerprint, "Binary identity substituted model identity")
            }
            try checks.no("changed-config") { _ = try QwenResidentCapabilityMetadata.describe(configuration: configuration + Data([32]), manifest: manifest, runtimeBinarySHA256: binary) }
            try checks.no("changed-manifest") { _ = try QwenResidentCapabilityMetadata.describe(configuration: configuration, manifest: manifest + Data([32]), runtimeBinarySHA256: binary) }
            try checks.no("oversized-config") { _ = try QwenResidentCapabilityMetadata.describe(configuration: Data(repeating: 32, count: 1_048_577), manifest: manifest, runtimeBinarySHA256: binary) }
            try checks.no("invalid-binary-pin") { _ = try QwenResidentCapabilityMetadata.describe(configuration: configuration, manifest: manifest, runtimeBinarySHA256: String(repeating: "A", count: 64)) }
            try checks.no("unknown-metadata") { _ = try QwenResidentCapabilityMetadata.describe(configuration: Data("{\"model_type\":\"unknown\"}".utf8), manifest: manifest, runtimeBinarySHA256: binary) }
            try checkCapabilityFiles(&checks)
            var output = try JSONSerialization.data(withJSONObject: ["accepted": checks.accepted, "rejected": checks.rejected,
                "nativeWorkerExecuted": false, "modelOrGPUExecution": false] as [String: Any], options: [.sortedKeys])
            output.append(10); FileHandle.standardOutput.write(output)
        } catch {
            FileHandle.standardError.write(Data("REFUSED: \(error)\n".utf8)); Darwin.exit(1)
        }
    }
}
