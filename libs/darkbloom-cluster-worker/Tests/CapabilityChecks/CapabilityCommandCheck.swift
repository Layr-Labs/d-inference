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
            // A second adapter, through the one catalog the worker's command asks: MiMo's own
            // row, its own session bound and no phase split. Described without MLX, like the others.
            try checks.yes("registered-mimo-is-described-from-its-own-row") {
                let mimoConfiguration = try Data(contentsOf: fixtures.appendingPathComponent("registered-mimo-v26-flash-mopd.configuration.json"))
                let mimoManifest = try Data(contentsOf: fixtures.appendingPathComponent("registered-mimo-v26-flash-mopd.manifest.json"))
                let mimo = try ClusterResidentModelCatalog.describe(configuration: mimoConfiguration, manifest: mimoManifest,
                                                                    runtimeBinarySHA256: binary)
                try capabilityCheck(mimo.adapterID == "mimo-v26-layer-stage" && mimo.runtimeModelID == "registered_mimo_v26_flash_mopd"
                    && mimo.supportedGenerationModes == [.pipeline, .pipelineCompactDecode]
                    && mimo.supportedPrefillSchedules == [.serial] && mimo.maxLifetimeSeconds == 1800
                    && mimo.partitions.map { $0.stages[0].sourceLayerEnd } == [16, 20, 24, 28, 30, 32, 34, 36, 38, 40, 42, 44]
                    && mimo.partitions.allSatisfy { $0.stages.count == 2 && $0.stages[1].sourceLayerEnd == 48 },
                    "The MiMo capability differs from its resident row")
                try capabilityCheck(try ClusterRuntimeCapabilityCodec.decode(ClusterRuntimeCapabilityCodec.encode(mimo)) == mimo,
                    "The MiMo capability does not round-trip within the byte bound")
                // The catalog answers for the dense rows exactly as their own producer does.
                try capabilityCheck(try ClusterResidentModelCatalog.describe(configuration: configuration, manifest: manifest,
                    runtimeBinarySHA256: binary) == QwenResidentCapabilityMetadata.describe(configuration: configuration,
                    manifest: manifest, runtimeBinarySHA256: binary), "The catalog changed a dense capability")
            }
            try checks.no("mimo-changed-manifest") {
                _ = try ClusterResidentModelCatalog.describe(
                    configuration: try Data(contentsOf: fixtures.appendingPathComponent("registered-mimo-v26-flash-mopd.configuration.json")),
                    manifest: manifest, runtimeBinarySHA256: binary)
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
