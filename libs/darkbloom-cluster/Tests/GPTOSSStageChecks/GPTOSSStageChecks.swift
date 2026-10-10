import DarkbloomClusterProtocol
import Foundation

// Deterministic checks of the GPT-OSS adapter's metadata against the
// registered artifact's own configuration and manifest. See README.md.

@main enum GPTOSSStageChecks {
    nonisolated(unsafe) static var checks = 0

    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) {
        checks += 1
        guard (try? condition()) == true else {
            FileHandle.standardError.write(Data("GPT-OSS stage check failed: \(message)\n".utf8))
            exit(1)
        }
    }

    static func refuses(_ message: String, _ body: () throws -> Void) {
        checks += 1
        do { try body() } catch { return }
        FileHandle.standardError.write(Data("GPT-OSS stage check failed: accepted \(message)\n".utf8))
        exit(1)
    }

    static func main() throws {
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
        let configuration = try Data(contentsOf: fixtures.appendingPathComponent("registered-gpt-oss-20b.configuration.json"))
        let manifest = try Data(contentsOf: fixtures.appendingPathComponent("registered-gpt-oss-20b.manifest.json"))
        let spec = try GPTOSSRegisteredSpecification.specification(configuration: configuration)
        let root = try JSONSerialization.jsonObject(with: configuration) as! [String: Any]

        // The fixtures are the registered metadata, and the row is closed.
        expect(sha256(configuration) == spec.configurationSHA256 && sha256(manifest) == spec.manifestSHA256,
               "fixtures are not the registered configuration and manifest")
        expect((try? spec.requireManifest(manifest, configuration: configuration)) != nil, "manifest totals")
        expect(GPTOSSRegisteredSpecification.all.count == 1 && spec.model.rawValue == "registered_gpt_oss_20b"
               && spec.supportedCuts == [6, 8, 10, 12], "registered row")
        expect(spec.supportedGenerationModes == [.pipeline, .pipelineCompactDecode], "phase split is not in the row")
        refuses("an unregistered model ID") { _ = try GPTOSSRegisteredSpecification.specification(runtimeModelID: "registered_qwen35_9b") }
        refuses("a configuration with one changed byte") {
            var edited = configuration; edited[edited.count - 2] ^= 1
            _ = try GPTOSSRegisteredSpecification.specification(configuration: edited)
        }
        refuses("a manifest with one changed byte") {
            var edited = manifest; edited[10] ^= 1
            try spec.requireManifest(edited, configuration: configuration)
        }

        // The geometry reproduces the pinned inventory of 775 stored tensors.
        let tensors = GPTOSSStageMetadata.tensors(specification: spec)
        expect(tensors.count == 775 && tensors.reduce(0) { $0 + $1.byteCount } == 12_076_119_168, "inventory totals")
        expect(sha256(Data(tensors.map(\.identity).joined(separator: "\n").utf8)) == spec.inventorySHA256, "inventory pin")
        let byName = Dictionary(uniqueKeysWithValues: tensors.map { ($0.name, $0) })
        expect(byName["model.layers.0.mlp.experts.gate_proj.scales"]?.sourceDType == "U8"
               && byName["model.layers.0.mlp.experts.gate_proj.scales"]?.shape == [32, 2880, 90], "MXFP4 exponent bytes")
        expect(byName["model.layers.23.mlp.experts.down_proj.weight"]?.shape == [32, 2880, 360], "MXFP4 packed words")
        expect(byName["model.layers.5.self_attn.o_proj.weight"]?.shape == [2880, 1024]
               && byName["model.layers.5.self_attn.o_proj.scales"]?.sourceDType == "BF16", "affine 8-bit projection")
        expect(byName["model.layers.9.self_attn.sinks"]?.shape == [64], "attention sinks")
        expect(!tensors.contains { $0.name.contains("gate_up_proj") }, "no fused expert tensor is stored")
        expect(byName["model.layers.0.mlp.experts.gate_proj.biases"] == nil, "MXFP4 has no per-group bias")

        // Every admitted cut: contiguous ranges, each layer's own type, exact conservation.
        var plans: [GPTOSSLayerStagePlan] = []
        for cut in spec.supportedCuts {
            let plan = try GPTOSSLayerStagePlan(configuration: configuration, cut: cut)
            plans.append(plan)
            expect(plan.stages.map(\.sourceRange) == [0..<cut, cut..<24], "ranges at cut \(cut)")
            for stage in plan.stages {
                let stageRoot = try JSONSerialization.jsonObject(with: stage.constructionConfiguration) as! [String: Any]
                let types = stageRoot["layer_types"] as? [String]
                expect(BoundedProbeInput.integer(stageRoot["num_hidden_layers"]) == stage.sourceRange.count
                       && types == stage.sourceRange.map { $0 % 2 == 0 ? "sliding_attention" : "full_attention" }
                       && types == stage.layers.map(\.kind), "stage \(stage.index) keeps each layer's attention type at cut \(cut)")
                expect(stage.layers.map(\.globalIndex) == Array(stage.sourceRange)
                       && stage.layers.map(\.localIndex) == Array(0..<stage.sourceRange.count), "layer map")
                let quantization = stageRoot["quantization"] as! [String: Any]
                expect(try QwenStageMetadata.json(quantization) == QwenStageMetadata.json(stageRoot["quantization_config"]!),
                       "both quantization containers carry the stage's policy")
                expect(quantization["mode"] as? String == "mxfp4" && BoundedProbeInput.integer(quantization["bits"]) == 4
                       && BoundedProbeInput.integer(quantization["group_size"]) == 32, "experts keep the default MXFP4 policy")
                let last = stage.sourceRange.count - 1
                expect(quantization["model.layers.\(last).mlp.router"] is [String: Any]
                       && quantization["model.layers.\(last + 1).mlp.router"] == nil, "overrides are re-indexed to the stage")
                if stage.index == 0 {
                    expect(quantization["model.embed_tokens"] is [String: Any]
                           && (quantization["lm_head"] as? NSNumber)?.boolValue == false, "stage 0 owns the embedding, not the head")
                    expect(stage.inertModules.map(\.path) == ["model.norm", "lm_head"], "stage 0 inactive modules")
                } else {
                    expect(quantization["lm_head"] is [String: Any]
                           && (quantization["model.embed_tokens"] as? NSNumber)?.boolValue == false, "stage 1 owns the head, not the embedding")
                    expect(stage.inertModules.map(\.path) == ["model.embed_tokens"], "stage 1 inactive modules")
                }
            }
            let parameters = try plan.parameters()
            expect(parameters.count == 775 && Set(parameters.map(\.sourceName)) == Set(tensors.map(\.name)), "every tensor has one owner")
            expect(try plan.tensorBytes(stage: 0) + plan.tensorBytes(stage: 1) == spec.sourceBytes, "byte conservation at cut \(cut)")
            expect(try plan.parameter(sourceName: "model.embed_tokens.weight") == .init(sourceName: "model.embed_tokens.weight", stage: 0, localName: "model.embed_tokens.weight")
                   && plan.parameter(sourceName: "lm_head.scales").stage == 1 && plan.parameter(sourceName: "model.norm.weight").stage == 1,
                   "embedding, head and final norm ownership")
            expect(try plan.parameter(sourceName: "model.layers.\(cut).self_attn.sinks")
                   == .init(sourceName: "model.layers.\(cut).self_attn.sinks", stage: 1, localName: "model.layers.0.self_attn.sinks")
                   && plan.parameter(sourceName: "model.layers.\(cut - 1).mlp.experts.up_proj.scales").localName
                       == "model.layers.\(cut - 1).mlp.experts.up_proj.scales", "layer re-indexing at cut \(cut)")
            refuses("a tensor outside the inventory") { _ = try plan.parameter(sourceName: "model.layers.0.mlp.experts.gate_up_proj.weight") }
        }
        expect(Set(plans.map(\.fingerprint)).count == plans.count
               && Set(plans.flatMap { $0.stages.map(\.fingerprint) }).count == plans.count * 2, "plans and stages have distinct identities")
        expect(try GPTOSSLayerStagePlan(configuration: configuration, cut: 8).fingerprint == plans[1].fingerprint, "a plan is deterministic")
        // Pinned so a change of the plan's identity is seen as one.
        expect(plans[1].fingerprint.hasPrefix("2a9870e785d2") && plans[2].fingerprint.hasPrefix("841c884492b5"), "plan identity at cuts 8 and 10")
        for cut in [0, 24, -1] { refuses("cut \(cut)") { _ = try GPTOSSLayerStagePlan(configuration: configuration, cut: cut) } }

        // Configuration admission fails closed.
        func edited(_ change: (inout [String: Any]) -> Void) -> [String: Any] { var copy = root; change(&copy); return copy }
        expect((try? GPTOSSStageMetadata.validate(root, specification: spec)) != nil, "registered configuration validates")
        for (label, value) in [
            ("an unknown key", edited { $0["future_layer_policy"] = 1 }),
            ("another model type", edited { $0["model_type"] = "qwen3_5" }),
            ("another layer count", edited { $0["num_hidden_layers"] = 12 }),
            ("another window", edited { $0["sliding_window"] = 256 }),
            ("a missing layer type", edited { $0["layer_types"] = Array(($0["layer_types"] as! [String]).dropLast()) }),
            ("an unknown layer type", edited { var t = $0["layer_types"] as! [String]; t[3] = "linear_attention"; $0["layer_types"] = t }),
            ("tied embeddings", edited { $0["tie_word_embeddings"] = true }),
            ("another activation clip", edited { $0["swiglu_limit"] = 6.0 }),
        ] { refuses(label) { _ = try GPTOSSStageMetadata.validate(value, specification: spec) } }
        func policyEdited(_ change: (inout [String: Any]) -> Void) -> [String: Any] {
            edited { var q = $0["quantization"] as! [String: Any]; change(&q); $0["quantization"] = q; $0["quantization_config"] = q }
        }
        for (label, value) in [
            ("an affine default", policyEdited { $0["mode"] = "affine" }),
            ("a 4-bit attention projection", policyEdited { $0["model.layers.0.self_attn.q_proj"] = ["bits": 4, "group_size": 64] }),
            ("an override for an expert bank", policyEdited { $0["model.layers.0.mlp.experts.gate_proj"] = ["bits": 8, "group_size": 64] }),
            ("a missing override", policyEdited { $0["lm_head"] = nil }),
            ("an unknown module", policyEdited { $0["model.layers.24.mlp.router"] = ["bits": 8, "group_size": 64] }),
            ("disagreeing containers", edited { var q = $0["quantization_config"] as! [String: Any]; q["bits"] = 8; $0["quantization_config"] = q }),
        ] { refuses(label) { _ = try GPTOSSStageMetadata.policy(value, specification: spec) } }

        // The arithmetic contract: the product defaults, and no expert switch.
        let driver = ["DARKBLOOM_CBV2_ATTN_QUERY_BLOCK": "128", "DARKBLOOM_BF16_WEIGHTS": "1", "MLX_ENABLE_TF32": "1"]
        expect((try? GPTOSSArithmeticEnvironment.admit(driver)) != nil, "the pair driver's environment is admitted")
        expect(try GPTOSSArithmeticEnvironment.admit(driver) == GPTOSSArithmeticEnvironment.admit(["MLX_ENABLE_TF32": "1"]),
               "the receipt does not depend on variables the contract does not name")
        for (name, value) in [("DARKBLOOM_GPTOSS_FUSED_GATE_UP", "1"), ("DARKBLOOM_GPTOSS_FUSED_GATE_UP", "0"),
                              ("DARKBLOOM_GPTOSS_COMPILED_EXPERTS", "1"), ("DARKBLOOM_GPTOSS_PREFILL_OUTPUT", "full"),
                              ("MLX_COMPILED_DECODE", "1"), ("MLX_SDPA_BLOCKS", "4"), ("MLX_METAL_GPU_ARCH", "")] {
            refuses("\(name)=\(value)") { var e = driver; e[name] = value; _ = try GPTOSSArithmeticEnvironment.admit(e) }
        }
        refuses("a missing TF32 declaration") { _ = try GPTOSSArithmeticEnvironment.admit([:]) }

        // The request-state ledger: named, bounded, and larger with more tokens.
        let plan = plans[1]
        for rank in 0...1 {
            let small = try GPTOSSRequestStateBudget.estimate(specification: spec, layers: plan.stages[rank].layers, rank: rank,
                maximumTokens: 158, chunkSize: 30, bound: { $0 })
            let large = try GPTOSSRequestStateBudget.estimate(specification: spec, layers: plan.stages[rank].layers, rank: rank,
                maximumTokens: 8320, chunkSize: 512, bound: { $0 })
            expect(small.fullAttentionLayers + small.slidingLayers == plan.stages[rank].layers.count
                   && small.fullAttentionLayers == small.slidingLayers, "rank \(rank) layer kinds")
            expect(small.reservedBytes < large.reservedBytes && large.reservedBytes < 2 << 30
                   && (large.rowBytes > 0) == (rank == 1), "rank \(rank) ledger")
            expect(large.reservedBytes == large.fullAttentionStateBytes + large.slidingStateBytes + large.boundaryBytes
                   + large.rowBytes + large.workspaceBytes, "rank \(rank) ledger sums its terms")
        }
        refuses("a request beyond the profile") {
            _ = try GPTOSSRequestStateBudget.estimate(specification: spec, layers: plan.stages[0].layers, rank: 0,
                maximumTokens: 8321, chunkSize: 512, bound: { $0 })
        }

        // The capability record names this adapter, model, profile, partitions and policy.
        let binary = String(repeating: "a", count: 64)
        let capability = try GPTOSSResidentCapabilityMetadata.describe(configuration: configuration, manifest: manifest,
                                                                      runtimeBinarySHA256: binary)
        expect(capability.adapterID == ClusterRuntimeAdapter.gptossLayerStage.rawValue
               && capability.runtimeModelID == spec.model.rawValue && capability.profile.id == spec.profileID
               && capability.profile.vocabularySize == 201_088 && capability.profile.maximumContextTokens == 8320, "capability identity")
        expect(capability.partitions.map { $0.stages[0].sourceLayerEnd } == spec.supportedCuts
               && capability.partitions.map(\.planSHA256) == plans.map(\.fingerprint), "capability partitions are the admitted plans")
        expect(capability.arithmeticPolicyID == GPTOSSArithmeticEnvironment.contract
               && capability.arithmeticPolicyID == ClusterRuntimeAdapter.gptossLayerStage.arithmeticPolicyID, "arithmetic policy")
        expect(capability.supportedGenerationModes == [.pipeline, .pipelineCompactDecode]
               && capability.supportedPrefillSchedules == [.serial, .oneChunkLookahead], "modes and schedules")
        expect(try ClusterRuntimeCapabilityCodec.decode(ClusterRuntimeCapabilityCodec.encode(capability)) == capability, "capability codec round trip")
        expect(ClusterRuntimeAdapter.registering(runtimeModelID: spec.model.rawValue) == .gptossLayerStage
               && ClusterRuntimeAdapter.admittedModels.contains { $0.runtimeModelID == spec.model.rawValue && $0.profileID == spec.profileID },
               "the protocol registers the pair under this adapter")
        refuses("the dense adapter naming this model") {
            _ = try ClusterRuntimeCapability(runtimeBinarySHA256: binary, adapterID: ClusterRuntimeAdapter.qwen35Dense.rawValue,
                adapterVersion: 1, runtimeModelID: capability.runtimeModelID, artifactSHA256: capability.artifactSHA256,
                configurationSHA256: capability.configurationSHA256, manifestSHA256: capability.manifestSHA256,
                profile: capability.profile, profileFingerprint: capability.profileFingerprint, partitions: capability.partitions,
                arithmeticPolicyID: capability.arithmeticPolicyID, arithmeticPolicySHA256: capability.arithmeticPolicySHA256,
                maxLifetimeSeconds: 300, maxRequests: 16)
        }
        refuses("this adapter under the dense arithmetic policy") {
            _ = try ClusterRuntimeCapability(runtimeBinarySHA256: binary, adapterID: capability.adapterID,
                adapterVersion: 1, runtimeModelID: capability.runtimeModelID, artifactSHA256: capability.artifactSHA256,
                configurationSHA256: capability.configurationSHA256, manifestSHA256: capability.manifestSHA256,
                profile: capability.profile, profileFingerprint: capability.profileFingerprint, partitions: capability.partitions,
                arithmeticPolicyID: ClusterRuntimeAdapter.qwen35Dense.arithmeticPolicyID,
                arithmeticPolicySHA256: capability.arithmeticPolicySHA256, maxLifetimeSeconds: 300, maxRequests: 16)
        }
        refuses("a capability for another manifest") {
            var edited = manifest; edited[10] ^= 1
            _ = try GPTOSSResidentCapabilityMetadata.describe(configuration: configuration, manifest: edited, runtimeBinarySHA256: binary)
        }
        print("GPT-OSS stage checks passed: \(checks) expectations")
    }
}
