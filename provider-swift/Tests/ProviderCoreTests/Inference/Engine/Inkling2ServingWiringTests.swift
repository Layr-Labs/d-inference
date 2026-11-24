import Foundation
import MLX
import MLXLLM
import MLXLMServer
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

/// Inkling 2 Mini's serving wiring that needs no weights: advertisement by
/// the exact native type, and the media refusals of its image path.
@Suite("Inkling 2 serving wiring")
struct Inkling2ServingWiringTests {
    @Test func onlyTheExactNativeTypeIsAdvertised() {
        #expect(EngineV2SupportedModels.isSupported(modelType: "inkling2_loop"))
        for other in [
            "Inkling2_Loop", "INKLING2_LOOP", "inkling2", "inkling2_loop_text", "inkling2_vision",
        ] {
            #expect(!EngineV2SupportedModels.isSupported(modelType: other), "\(other)")
        }
    }

    /// Inkling's load warm-up runs on every load (the shader-cache probe would
    /// skip it), unless the switch is off; other models keep the probe.
    @Test func warmupRunsOnEveryLoadUnlessSwitchedOff() {
        let key = ModelCalibrationPolicy.shapeWarmupEnvironmentKey
        #expect(
            ModelCalibrationPolicy.shapeWarmupMode(plan: .inkling2, environment: [:]) == .always)
        #expect(
            ModelCalibrationPolicy.shapeWarmupMode(plan: .inkling2, environment: [key: "always"])
                == .always)
        #expect(
            ModelCalibrationPolicy.shapeWarmupMode(plan: .inkling2, environment: [key: "0"]) == .off
        )
        #expect(
            ModelCalibrationPolicy.shapeWarmupMode(plan: .standard, environment: [:]) == .probed)
    }

    /// One full prefill chunk, then short greedy decodes at the widths served:
    /// greedy so the drafter's rounds run; every cell a warm-up.
    @Test func warmupCellsCoverAChunkAndTheServedWidths() {
        typealias Cell = ModelCalibrationPolicy.Cell
        #expect(
            ModelCalibrationPolicy.inkling2Warmup(
                chunkTokens: 2_048, width: 8, contextTokens: 1_048_576) == [
                    Cell(promptTokens: 2_048, outputTokens: 16, width: 1, warmup: true),
                    Cell(promptTokens: 256, outputTokens: 16, width: 2, warmup: true),
                    Cell(promptTokens: 256, outputTokens: 16, width: 8, warmup: true),
                ])
        #expect(
            ModelCalibrationPolicy.inkling2Warmup(chunkTokens: 2_048, width: 4, contextTokens: nil)
                .map(\.width)
                == [1, 2])
        #expect(
            ModelCalibrationPolicy.inkling2Warmup(
                chunkTokens: 2_048, width: 1, contextTokens: 1_000)
                == [Cell(promptTokens: 984, outputTokens: 16, width: 1, warmup: true)])
        #expect(
            ModelCalibrationPolicy.inkling2Warmup(
                chunkTokens: 2_048, width: 8, contextTokens: 8_192
            )
            .allSatisfy { $0.warmup && !$0.sampled })
    }

    /// The load-time native KV probe runs a forward on unpaged probe rows;
    /// Inkling's serving attention (the paged kernel core) needs paged rows,
    /// so the probe takes the SDK's gathered reference core and the kernel core
    /// is back before any engine exists. Without that the load traps. It runs
    /// on the GPU, as at load: on a CPU device the SDK's fused layer kernels
    /// launch nothing and its row-mix result is indexed unchecked.
    @Test func nativeKVProbeRunsOnAnInklingTarget() throws {
        let config: [String: Any] = [
            "model_type": "inkling2_loop",
            "text_config": [
                "hidden_size": 128, "num_hidden_layers": 6, "vocab_size": 64,
                "unpadded_vocab_size": 60, "num_attention_heads": 2, "num_key_value_heads": 1,
                "head_dim": 64, "d_rel": 4, "rel_extent": 24, "log_scaling_n_floor": 8,
                "log_scaling_alpha": 0.5, "qk_l2_clip_threshold": 8.0,
                "rel_l2_clip_threshold": 2.0, "local_layer_ids": [0, 2, 4],
                "sconv_kernel_size": 4, "final_logit_softcapping": 30.0,
                "sliding_window_size": 24, "n_layers_per_attn_res_block": 2,
                "n_routed_experts": 8, "num_experts_per_tok": 2, "intermediate_size": 32,
                "loop_config": ["core_start": 2, "core_end": 4, "num_passes": 3, "gate_rank": 8],
            ] as [String: Any],
        ]
        let configuration = try JSONDecoder().decode(
            Inkling2Configuration.self, from: JSONSerialization.data(withJSONObject: config))
        let model = Inkling2Model(configuration)
        let adapter = try #require(EngineV2Factory.ProductionModelAdapter(model: model))
        let result = try Device.withDefaultDevice(.gpu) {
            try EngineV2Factory.probeNativeKVTypes(model: model, adapter: adapter)
        }
        #expect(!result.layerDTypes.isEmpty)
        #expect(!result.observations.isEmpty)
        #expect(model.pagedAttentionCore is Inkling2KernelAttentionCore)
    }

    /// The per-depth warm-up: every depth 0-7 at
    /// one row with a 4,224-token prompt, 2 and 8 rows of 256 where the
    /// served width allows, and with the drafter one 2-row cell of unequal
    /// prompts; 12 output tokens each.
    @Test func depthWarmupCoversEveryServedWidth() {
        let full = Inkling2DepthWarmup.plan(
            servedRows: 14, speculativeRows: 8, drafterAvailable: true,
            contextTokens: 1_048_576)
        #expect(full.count == 5 + 7 * 6)
        #expect(Set(full.map(\.depth)) == Set(0 ... 7))
        for depth in 1 ... 7 {
            #expect(
                full.filter { $0.depth == depth && !$0.smallSegments }.map(\.promptTokens)
                    == [[4_224], [256, 256], Array(repeating: 256, count: 8), [256, 1_100]])
        }
        #expect(
            full.filter { $0.depth == 0 && !$0.smallSegments }.map(\.promptTokens)
                == [[4_224], [256, 256], Array(repeating: 256, count: 8)])
        // Every depth's wide and long cells also run on the small-segment pool (the large bindings).
        for depth in 0 ... 7 {
            #expect(
                full.filter { $0.depth == depth && $0.smallSegments }.map(\.promptTokens)
                    == [Array(repeating: 256, count: 8), [4_224]])
        }
        // A narrower served width warms its own width; one row warms one row.
        let four = Inkling2DepthWarmup.plan(
            servedRows: 4, speculativeRows: 8, drafterAvailable: true,
            contextTokens: nil)
        #expect(Set(four.map(\.rows)) == [1, 2, 4])
        let one = Inkling2DepthWarmup.plan(
            servedRows: 1, speculativeRows: 8, drafterAvailable: true,
            contextTokens: nil)
        #expect(one.allSatisfy { $0.promptTokens == [4_224] } && one.count == 16)
        // Without the drafter only the plain engine warms.
        #expect(
            Inkling2DepthWarmup.plan(
                servedRows: 8, speculativeRows: 8, drafterAvailable: false,
                contextTokens: nil
            ).allSatisfy { $0.depth == 0 })
        // A short served context drops the cells it cannot hold.
        let short = Inkling2DepthWarmup.plan(
            servedRows: 8, speculativeRows: 8, drafterAvailable: true,
            contextTokens: 2_048)
        #expect(!short.contains { $0.promptTokens.contains(4_224) })
        #expect(short.contains { $0.promptTokens == [256, 1_100] })
        // Rows draw exact lengths from one rendered prompt, each at its own offset.
        let base = Array(100 ..< 160)
        let first = Inkling2DepthWarmup.prompt(from: base, tokens: 4_224, row: 0)
        let second = Inkling2DepthWarmup.prompt(from: base, tokens: 4_224, row: 1)
        #expect(first.count == 4_224 && second.count == 4_224 && first != second)
        #expect(Set(first).isSubset(of: Set(base)))
        #expect(Inkling2DepthWarmup.enabled(environment: [:]))
        #expect(
            !Inkling2DepthWarmup.enabled(environment: [Inkling2DepthWarmup.environmentKey: " OFF "])
        )
    }

    /// Video, and media for a checkpoint without its tower, are refused
    /// before any decode or tower work, with a client-facing reason.
    @Test func mediaRefusalsAreExplicit() throws {
        try EngineV2VisionPrefill.validateInkling2Media(servesVision: true, videoCount: 0)
        for (servesVision, videos) in [(true, 1), (false, 0), (false, 2)] {
            do {
                try EngineV2VisionPrefill.validateInkling2Media(
                    servesVision: servesVision, videoCount: videos)
                Issue.record("accepted servesVision=\(servesVision) videos=\(videos)")
            } catch {
                let refusal = try #require(EngineV2VisionPrefill.clientFault(for: error))
                guard case .multimodalRejected(let message) = refusal else {
                    Issue.record("unexpected refusal \(refusal)")
                    continue
                }
                let failure = ProviderLoop.sanitizedInferenceFailure(
                    from: refusal, phase: .streamStart)
                #expect(failure.statusCode == 400)
                #expect(failure.code == .invalidMedia)
                #expect(failure.refusal == nil)
                #expect(message.contains(servesVision ? "video" : "no vision_config"), "\(message)")
            }
        }
    }

    /// Wire requests enter through the public decoder. The role guard runs on the
    /// loaded Inkling path before image bytes are read. Run with each process-wide
    /// media policy to exercise its public refusal and its native tool/user inputs.
    @Test(arguments: ["user", "tool", "assistant", "system", "developer"])
    func imageRolesMatchPublicContract(role: String) async throws {
        let fixture = try #require(
            Bundle.module.url(
                forResource: "image-role-requests", withExtension: "json",
                subdirectory: "Fixtures/Inkling2"))
        let bodies = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        let body = try JSONSerialization.data(withJSONObject: try #require(bodies[role]))
        let inbound = try ProviderLoop.decodeInboundChatRequest(body)
        let request = inbound.request
        let normalizedRole = role == "developer" ? "system" : role
        let imageMessage = try #require(
            request.messages.first { message in
                guard case .parts(let parts) = message.content else { return false }
                return parts.contains {
                    if case .imageURL = $0 { return true } else { return false }
                }
            })
        #expect(imageMessage.role.rawValue == normalizedRole)

        if role == "user" || role == "tool" {
            try EngineV2VisionPrefill.validateInkling2ImageRoles(request)
            let input = try await MediaIngest.buildUserInput(
                from: request, templateControls: inbound.extensions.templateControls,
                preserveTemplateFields: true,
                keepNonUserMedia: MediaIngest.placesNonUserMedia(request),
                modelType: Inkling2ModelIdentity.modelType)
            #expect(input.images.count == 1)
            return
        }

        do {
            try EngineV2VisionPrefill.validateInkling2ImageRoles(request)
            Issue.record("Accepted an image on the \(role) role")
        } catch {
            let fault = try #require(EngineV2VisionPrefill.clientFault(for: error))
            let failure = ProviderLoop.sanitizedInferenceFailure(from: fault, phase: .streamStart)
            #expect(failure.statusCode == 400)
            #expect(failure.errorReason == .clientError)
            let setting = ProcessInfo.processInfo.environment[MediaIngest.everyRoleEnvironmentKey]
            if !ToolOutputLeniencySwitch.isOff(setting) {
                #expect(failure.code == .invalidRequest)
                #expect(failure.refusal == .mediaRoleNotRendered)
            } else {
                #expect(failure.code == .invalidMedia)
                #expect(failure.refusal == nil)
            }
        }
    }
}
