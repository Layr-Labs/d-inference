// Copyright © 2026 Eigen Labs.
//
// The MTP acceptance rule a production slot installs, read back from the
// real engine and from the slot posture event. A tiny random-init Gemma-4
// target and a construction-only drafter double drive the real
// `EngineV2SlotFactory.makeProductionBundle`; no model is downloaded or
// loaded, and no draft step runs.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing

@testable import ProviderCore

private let slotModelID = "tiny-gemma-acceptance"

/// Construction-only drafter. `supportsTargetPrefixAcceptance` is the
/// capability under test; every other declaration keeps the engine on its
/// serial-target path.
private final class AcceptanceDrafter: CBv2MTPDrafter, @unchecked Sendable {
    private final class Capture: CBv2MTPPreparedCapture {}
    private let target: Gemma4TextModel
    let supportsTargetPrefixAcceptance: Bool
    init(_ target: Gemma4TextModel, supportsTargetPrefixAcceptance: Bool) {
        self.target = target
        self.supportsTargetPrefixAcceptance = supportsTargetPrefixAcceptance
    }
    var mtpTargetIdentity: ObjectIdentifier? { ObjectIdentifier(target) }
    var requiredVerificationMode: CBv2MTPVerificationMode? { .serialTarget }
    var maximumDraftTokens: Int? { 1 }
    func prepare(rows: [CBv2MTPRowCapture]) -> any CBv2MTPPreparedCapture { Capture() }
    func draftStep(tokens: MLXArray, hidden: MLXArray, prepared: any CBv2MTPPreparedCapture)
        -> (tokens: MLXArray, hidden: MLXArray)
    {
        preconditionFailure("construction-only drafter must not run draft math")
    }
}

private struct AcceptanceProcessor: UserInputProcessor {
    func prepare(input: UserInput) async throws -> LMInput { throw CancellationError() }
}

private final class AcceptanceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [TelemetryEvent] = []
    private var storedWarnings: [String] = []
    var events: [TelemetryEvent] { lock.withLock { storedEvents } }
    var warnings: [String] { lock.withLock { storedWarnings } }
    func record(_ event: TelemetryEvent) { lock.withLock { storedEvents.append(event) } }
    func warn(_ line: String) { lock.withLock { storedWarnings.append(line) } }
    var postureAcceptance: String? {
        events.last { $0.fields?["operation"]?.description == "engine_v2_slot_posture" }?
            .fields?["mtp_acceptance"]?.description
    }
}

private struct InstalledSlot {
    let acceptance: CBv2MTPAcceptance?
    let postureAcceptance: String?
    let warnings: [String]
}

private func tinyGemmaTarget() throws -> Gemma4TextModel {
    let data = Data(
        """
        {"model_type":"gemma4_text","hidden_size":64,"num_hidden_layers":2,
         "intermediate_size":128,"num_attention_heads":4,"head_dim":64,"global_head_dim":64,
         "vocab_size":128,"vocab_size_per_layer_input":128,"num_key_value_heads":2,
         "num_kv_shared_layers":0,"hidden_size_per_layer_input":32,"sliding_window":16,
         "sliding_window_pattern":2,"max_position_embeddings":2048,"use_double_wide_mlp":false}
        """.utf8)
    return Gemma4TextModel(try JSONDecoder().decode(Gemma4TextConfiguration.self, from: data))
}

/// Builds one real production slot and reports what it installed.
/// `drafterTargetPrefix` nil builds the slot without an MTP drafter.
private func installSlot(
    byModel: [String: String], drafterTargetPrefix: Bool?
) async throws -> InstalledSlot {
    let target = try tinyGemmaTarget()
    let tokenizer = StubBridgeTokenizer()
    let container = ModelContainer(
        context: ModelContext(
            configuration: ModelConfiguration(id: slotModelID), model: target,
            processor: AcceptanceProcessor(), tokenizer: tokenizer))
    let assistant = drafterTargetPrefix.map {
        ProviderMTPAssistantHandle(
            owner: NSObject(),
            drafter: AcceptanceDrafter(target, supportsTargetPrefixAcceptance: $0))
    }
    let status: MTPActivationStatus =
        assistant == nil
        ? .disabled(.configDisabled, configured: false)
        : MTPActivationStatus.disabled(.configDisabled, configured: true)
            .activated(assistantBytes: 1 << 20)
    let prepared = EngineV2PreparedModel(
        snapshot: EngineV2ModelSnapshot(model: target, eosTokenIds: [1], extraEOSTokens: []),
        servingModel: target, assistant: assistant, mtpStatus: status, mtpArtifact: nil)
    let recorder = AcceptanceRecorder()
    let bundle = try await EngineV2SlotFactory.makeProductionBundle(
        modelId: slotModelID, modelType: "gemma4_text", isVLM: false, modelDirectory: nil,
        container: container, tokenizer: TokenizerHandle(tokenizer),
        sizing: SlotSizingSnapshot(
            weightsBytes: 1, fp16KVBytesPerToken: 1_024, maxContextLength: 2_048,
            defaultMaxTokens: 32),
        kvBytesCapacity: 8 << 20, maxConcurrentRequests: 1, kvBudget: nil,
        kvBackendConfig: "contiguous",
        mtpAcceptanceConfigByModel: byModel,
        specDecPreparation: SpecDecPreparation(artifact: nil, status: status),
        preparedModel: prepared,
        assemblyOverrides: .init(promptContractID: "tiny-gemma-acceptance-contract"),
        environment: [KVBackendGuardStore.pathEnvKey: "/dev/null"],
        startServingTelemetry: false,
        emitTelemetry: { recorder.record($0) },
        logWarning: { recorder.warn($0) })
    // One posture sample from the real producer; the periodic sampler is off.
    await bundle.bridge.sampleSlotPosture()
    let engine = await bundle.bridge.ownedEngine as? EngineV2
    let acceptance = engine?.mtpMetricsSnapshot()?.acceptance
    await bundle.bridge.shutdown()
    return InstalledSlot(
        acceptance: acceptance, postureAcceptance: recorder.postureAcceptance,
        warnings: recorder.warnings)
}

private func acceptanceWarnings(_ slot: InstalledSlot) -> [String] {
    slot.warnings.filter { $0.contains("mtp_acceptance") }
}

@Suite("MTP acceptance slot installation", .serialized)
struct MTPAcceptanceSlotInstallationTests {
    @Test("a model without a per-model entry installs exact")
    func unconfiguredModelInstallsExact() async throws {
        let slot = try await installSlot(byModel: [:], drafterTargetPrefix: true)
        #expect(slot.acceptance == .exact)
        #expect(slot.postureAcceptance == "exact")
        #expect(acceptanceWarnings(slot).isEmpty)

        let other = try await installSlot(
            byModel: ["another-model": "typical"], drafterTargetPrefix: true)
        #expect(other.acceptance == .exact)
        #expect(other.postureAcceptance == "exact")
    }

    @Test("a per-model typical entry installs typical when the drafter supports it")
    func perModelTypicalInstallsTypical() async throws {
        let slot = try await installSlot(
            byModel: [slotModelID: "typical"], drafterTargetPrefix: true)
        #expect(slot.acceptance == .typical(delta: CBv2MTPAcceptance.defaultTypicalDelta))
        #expect(slot.postureAcceptance == "typical")
        #expect(acceptanceWarnings(slot).isEmpty)
    }

    @Test("a per-model exact entry installs exact")
    func perModelExactInstallsExact() async throws {
        let slot = try await installSlot(
            byModel: [slotModelID: "exact"], drafterTargetPrefix: true)
        #expect(slot.acceptance == .exact)
        #expect(slot.postureAcceptance == "exact")
        #expect(acceptanceWarnings(slot).isEmpty)
    }

    @Test("typical on a drafter without target-prefix acceptance installs exact and warns once")
    func drafterWithoutTargetPrefixFallsBackToExact() async throws {
        let slot = try await installSlot(
            byModel: [slotModelID: "typical"], drafterTargetPrefix: false)
        #expect(slot.acceptance == .exact)
        #expect(slot.postureAcceptance == "exact")
        let warnings = acceptanceWarnings(slot)
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains(slotModelID) == true)
        #expect(warnings.first?.contains("target-prefix acceptance") == true)
    }

    @Test("typical on a slot with MTP off installs no rule and warns once")
    func mtpOffSlotWarns() async throws {
        let slot = try await installSlot(
            byModel: [slotModelID: "typical"], drafterTargetPrefix: nil)
        #expect(slot.acceptance == nil)
        #expect(slot.postureAcceptance == nil)
        let warnings = acceptanceWarnings(slot)
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains(slotModelID) == true)
        #expect(warnings.first?.contains("MTP is off") == true)
    }

    @Test("an unknown per-model value installs exact and warns once")
    func unknownPerModelValue() async throws {
        let slot = try await installSlot(
            byModel: [slotModelID: "tokenv3"], drafterTargetPrefix: true)
        #expect(slot.acceptance == .exact)
        #expect(slot.postureAcceptance == "exact")
        let warnings = acceptanceWarnings(slot)
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("\"tokenv3\"") == true)
    }
}
