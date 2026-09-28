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
                var current = try JSONSerialization.jsonObject(with: ClusterRuntimeCapabilityCodec.encode(value)) as! [String: Any]
                current.removeValue(forKey: "supportedPrefillSchedules")
                var legacy = try JSONSerialization.data(withJSONObject: current, options: [.sortedKeys, .withoutEscapingSlashes])
                legacy.append(10)
                try capabilityCheck(try ClusterRuntimeCapabilityCodec.decode(legacy) == golden,
                    "Native metadata changed beyond advertised prefill schedules")
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
