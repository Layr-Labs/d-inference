import CryptoKit
import Foundation
import DarkbloomClusterProtocol
import Testing
@testable import DarkbloomClusterRuntime

// Long context for the registered dense models: request limits derived from the
// protocol and the declared context, state ceilings computed from configuration
// geometry, the attention transient a prefill frame needs, and the host gate's
// largest admissible context. Registered metadata and constructed observations
// only: no model, no weights, no GPU.

@Suite("Long-context limits, ceilings and admission (registered metadata, no model)")
struct LongContextLimitsTests {
    private static let gib = QwenDenseStageLoadPolicy.gib
    private static let page = 16_384

    private static func specification(_ model: QwenRegisteredDenseModel) throws -> QwenDenseRegisteredSpecification {
        try #require(QwenDenseRegisteredSpecification.all.first { $0.model == model })
    }

    /// The owner's long-context sizes, plus the edges of the protocol.
    private static let sizes = [5120, 10_240, 20_480, 30_720]

    /// The models that declare their context: every registered resident row
    /// (dense 9B and 27B, the 35B A3B models, the Prism pack, Nemotron).
    private static let declaring = QwenRegisteredDenseModel.allCases.filter {
        QwenDenseRegisteredSpecification.declaredContextTokensByModel[$0] != nil
    }

    @Test func limitsFollowTheProtocolAndTheDeclaredContext() throws {
        #expect(Self.declaring == QwenRegisteredDenseModel.allCases)
        for model in Self.declaring {
            let spec = try Self.specification(model)
            #expect(spec.declaredContextTokens == 262_144)
            let limits = try QwenResidentContextLimits(specification: spec)
            #expect(limits.maximumContextTokens == ClusterWorkerLimits.contextTokens)
            #expect(limits.maximumPromptTokens == ClusterWorkerLimits.promptTokens)
            #expect(limits.maximumOutputTokens == ClusterWorkerLimits.outputTokens)
            #expect(limits.maximumChunkTokens == 512)
            let profile = try QwenResidentAdapterDefinition.profile(specification: spec)
            #expect(profile.maximumPromptTokens == limits.maximumPromptTokens)
            #expect(profile.maximumOutputTokens == limits.maximumOutputTokens)
            #expect(profile.maximumContextTokens == limits.maximumContextTokens)
            let full = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
                promptTokenIDs: Array(repeating: 1000, count: 32_768), chunkSize: 512,
                outputCount: 32_768, stopTokenIDs: [])
            #expect(full.maximumTokens == 65_536 && full.outputCount == 32_768)
            // Every long-context size with 128 outputs is a valid request on
            // this profile; one token more than the prompt cap is not.
            for prompt in Self.sizes {
                let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
                    promptTokenIDs: Array(repeating: 1000, count: prompt), chunkSize: 512, outputCount: 128, stopTokenIDs: [])
                #expect(request.maximumTokens == prompt + 128)
                #expect(request.prefillFrameCount == (prompt + 511) / 512)
            }
            #expect(throws: (any Error).self) {
                _ = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
                    promptTokenIDs: Array(repeating: 1000, count: 32_769), chunkSize: 512, outputCount: 1, stopTokenIDs: [])
            }
            #expect(throws: (any Error).self) {
                _ = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
                    promptTokenIDs: Array(repeating: 1000, count: 16), chunkSize: 16, outputCount: 32_769, stopTokenIDs: [])
            }
        }
    }

    @Test func adapterChunkChoiceDoesNotChangeOtherModelsOrTheContextLimit() throws {
        let ordinary = try QwenResidentContextLimits(declaredContextTokens: 262_144)
        let glm = try QwenResidentContextLimits(declaredContextTokens: 1_048_576, prefillChunkTokens: 2048)
        #expect(ordinary.maximumChunkTokens == 512 && glm.maximumChunkTokens == 2048)
        #expect(ordinary.maximumContextTokens == glm.maximumContextTokens)
        #expect(try QwenResidentContextLimits(declaredContextTokens: 128, prefillChunkTokens: 2048)
            .maximumChunkTokens == 127)
        for invalid in [0, -1, Int.max] {
            #expect(throws: QwenDenseProfileError.self) {
                _ = try QwenResidentContextLimits(declaredContextTokens: 32_768, prefillChunkTokens: invalid)
            }
        }
    }

    @Test func eachDeclaredContextRowIsWhatThePinnedConfigurationDeclares() throws {
        for model in Self.declaring {
            let spec = try Self.specification(model)
            let declared = try #require(spec.declaredContextTokens, "\(model) has no declared-context row")
            let data = try LongContextFixture.configuration(model)
            #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == spec.configurationSHA256)
            let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            // Nemotron's configuration is flat; the Qwen wrappers nest a text configuration.
            let text = root["text_config"] as? [String: Any] ?? root
            #expect(text["max_position_embeddings"] as? Int == declared)
        }
    }

    @Test func aModelWithoutADeclaredContextKeepsTheEarlierReservation() throws {
        // What a family's model gets until its row is added: the profile, the
        // state ceiling and the admission it had before this work.
        let reservation = QwenResidentContextLimits.reservation
        #expect(reservation.declaredContextTokens == nil)
        #expect(reservation.maximumPromptTokens == 8192 && reservation.maximumOutputTokens == 128)
        #expect(reservation.maximumContextTokens == 8320 && reservation.maximumChunkTokens == 512)
        #expect(try QwenResidentContextLimits.derived(declaredContextTokens: nil) == reservation)
        #expect(try QwenResidentContextLimits.derived(declaredContextTokens: 262_144)
            == (try QwenResidentContextLimits(declaredContextTokens: 262_144)))
        #expect(QwenResidentContextAdmission.minimumContextTokens(limits: reservation) == 513)
    }

    @Test func namedStateCeilingsAreComputedFromEachModelsGeometry() throws {
        // Models that declare their context; every other row keeps the reservation's ceiling.
        for model in QwenRegisteredDenseModel.allCases where QwenDenseRegisteredSpecification.declaredContextTokensByModel[model] != nil {
            let spec = try Self.specification(model)
            let ceilings = try QwenResidentResourceCeilings(model: model)
            let geometry = try spec.expectedGeometry()
            #expect(ceilings.limits == (try QwenResidentContextLimits(specification: spec)))
            #expect(ceilings.namedStateByteCeiling == (try QwenLongPrefillTensorBudget.estimate(geometry: geometry,
                maximumTokens: 65_536, chunkSize: 512).conservativeStateAndBoundaryBytes))
            let previous = try QwenLongPrefillTensorBudget.estimate(geometry: geometry,
                maximumTokens: 32_768, chunkSize: 512)
            #expect(ceilings.namedStateByteCeiling > previous.conservativeStateAndBoundaryBytes)
            // Every long-context request fits under its own model's ceiling.
            for prompt in Self.sizes {
                let state = try QwenLongPrefillTensorBudget.estimate(geometry: geometry, maximumTokens: prompt + 128, chunkSize: 512)
                #expect(state.conservativeStateAndBoundaryBytes <= ceilings.namedStateByteCeiling)
            }
            // The same formula still gives the pinned 8,193-token metadata value.
            #expect(try QwenLongPrefillTensorBudget.estimate(geometry: geometry, maximumTokens: 8193, chunkSize: 512)
                .conservativeStateAndBoundaryBytes == spec.namedStateBytes)
        }
        // State grows with the attention layers' KV: the 27B's 16 against the 9B's 8.
        let small = try QwenResidentResourceCeilings(model: .qwen35NineB)
        let large = try QwenResidentResourceCeilings(model: .qwen38TwentySevenB)
        #expect(small.namedStateByteCeiling > 2_456_551_456 && large.namedStateByteCeiling > 4_920_836_160)
        // The separate exact 8,192/512/1 receipt keeps its own bound.
        #expect(QwenRegistered9BLongPrefillAdmission.namedTensorByteCeiling == 768 * 1024 * 1024)
    }

    /// A consistent observation: `free` GiB of actual free pages, nothing else counted.
    private static func observation(freeGiB: Int, physicalGiB: Int) -> QwenDenseStageLoadOSObservation {
        let free = freeGiB * gib / page, inactive = 1_000, speculative = 500
        return .init(startedNanoseconds: 900, completedNanoseconds: 1_000,
            timestampUTC: "2026-10-09T00:00:00Z", physicalMemoryBytes: physicalGiB * gib, pageSizeBytes: page,
            kernelFreePages: free + speculative, freePages: free, inactivePages: inactive,
            speculativePages: speculative, actualFreeBytes: free * page,
            estimatedReclaimableBytes: (free + inactive + speculative) * page, pressureLevel: 1, swapUsedBytes: 0)
    }

    /// The gate's own decision on the named charge of a context: state plus
    /// the attention transient plus the loading headroom, as at load.
    private static func gateAdmits(_ os: QwenDenseStageLoadOSObservation, model: QwenRegisteredDenseModel,
                                   context: Int) throws -> Bool {
        let geometry = try specification(model).expectedGeometry()
        let state = try QwenLongPrefillTensorBudget.estimate(geometry: geometry, maximumTokens: context,
            chunkSize: min(512, context - 1)).conservativeStateAndBoundaryBytes
        let transient = try QwenResidentPrefillTransient.bytes(geometry: geometry, stageHasAttention: true,
            chunkTokens: min(512, context - 1), contextTokens: context)
        let required = state + transient + QwenDenseStageLoadPolicy.loadingHeadroomBytes
        return try QwenDenseStageLoadPolicy.decide(os, requiredBytes: required, purpose: "test context \(context)", now: 1_100).admitted
    }

    @Test func theGateAdmitsTheLongestContextThatFitsAndRefusesCleanlyBelowTheSmallest() throws {
        // Plenty of room: the whole derived context, on either Mac's size.
        for physical in [128, 256] {
            let roomy = Self.observation(freeGiB: 40, physicalGiB: physical)
            #expect(try QwenResidentContextAdmission.largest(minimum: 513, maximum: 65_536) {
                try Self.gateAdmits(roomy, model: .qwen38TwentySevenB, context: $0)
            } == 65_536)
        }
        // 10 GiB free: the 27B's full 32,768-token charge (4.58 GiB state,
        // 1.51 GiB transient, 4 GiB headroom: 10.09 GiB) does not fit, a
        // shorter one does. Nothing that fits is refused: the load keeps
        // serving the shorter contexts.
        let tight = Self.observation(freeGiB: 10, physicalGiB: 128)
        #expect(!(try Self.gateAdmits(tight, model: .qwen38TwentySevenB, context: 32_768)))
        let largest = try #require(try QwenResidentContextAdmission.largest(minimum: 513, maximum: 32_768) {
            try Self.gateAdmits(tight, model: .qwen38TwentySevenB, context: $0)
        })
        #expect(largest > 20_000 && largest < 32_768)
        #expect(try Self.gateAdmits(tight, model: .qwen38TwentySevenB, context: largest))
        #expect(!(try Self.gateAdmits(tight, model: .qwen38TwentySevenB, context: largest + 1)))
        // The 9B's smaller state fits the same Mac at its full context.
        #expect(try QwenResidentContextAdmission.largest(minimum: 513, maximum: 32_768) {
            try Self.gateAdmits(tight, model: .qwen35NineB, context: $0)
        } == 32_768)
        // Below the gate's 6 GiB floor nothing is admitted, and the search says so.
        let starved = Self.observation(freeGiB: 3, physicalGiB: 128)
        #expect(try QwenResidentContextAdmission.largest(minimum: 513, maximum: 32_768) {
            try Self.gateAdmits(starved, model: .qwen35NineB, context: $0)
        } == nil)
    }

    @Test func phaseSplitHandOffAtThirtyThousandTokensFitsTheModelsOwnCeiling() throws {
        for (model, cut) in [(QwenRegisteredDenseModel.qwen35NineB, 4), (.qwen38TwentySevenB, 16), (.qwen38TwentySevenB, 20)] {
            let spec = try Self.specification(model)
            let plan = try QwenLayerStagePlan(configuration: try LongContextFixture.configuration(model),
                ranges: [0..<cut, cut..<spec.layers], activeMTP: false)
            let shapes = try QwenPhaseSplitPlan.expectedShapes(stage: plan.stages[0], geometry: spec.expectedGeometry(),
                committedTokens: 30_720, activationDType: "bfloat16")
            let bytes = try QwenLongPrefillCheckedBytes.sum(shapes.map(\.byteCount))
            #expect(bytes <= (try QwenResidentResourceCeilings(model: model)).namedStateByteCeiling)
        }
    }
}

/// The registered configuration bytes, read from the worker's capability fixtures.
enum LongContextFixture {
    static func configuration(_ model: QwenRegisteredDenseModel) throws -> Data {
        let name = switch model {
        case .qwen35NineB: "qwen35-9b"
        case .qwen38TwentySevenB: "qwen38-27b"
        case .qwen35ThirtyFiveBA3B: "qwen35-35b-a3b"
        case .qwen36ThirtyFiveBA3B: "qwen36-35b-a3b"
        case .ternaryBonsai2TwentySevenB: "ternary-bonsai-2-27b"
        case .nemotron35Lightning: "nemotron35-lightning"
        }
        let libraries = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: libraries.appendingPathComponent(
            "darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures/registered-\(name).configuration.json"))
    }
}
