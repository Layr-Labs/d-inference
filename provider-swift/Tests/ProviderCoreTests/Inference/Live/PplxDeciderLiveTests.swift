// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore

/// Real-pack decision test: loads a converted pplx-decider pack through the
/// production slot factory and runs the model card's README examples through
/// the local decision path (`DecisionLocalServing` → `DecisionRunner` → the v2
/// engine). Opt-in: it loads a full 27B target (Metal, ~17 GiB).
@Suite("pplx-decider real-pack decisions", .serialized)
struct PplxDeciderLiveTests {
    private static let packPathVariable = "DARKBLOOM_LIVE_MLX_PPLX_DECIDER_PATH"

    private static var packDirectory: URL? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DARKBLOOM_LIVE_MLX_TESTS"] == "1",
            let path = environment[packPathVariable], !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static let readmeBody = #"""
        {"model": "pplx-decider-v1-27b",
         "state": "My Stripe integration keeps failing. I'm losing sales. Please help ASAP.",
         "questions": {
           "routing": {"type": "choice", "instructions": "Which team should handle this request?",
                       "criteria": {"billing": "Charges and refunds",
                                    "technical_support": "Integration errors",
                                    "sales": "Questions about buying a product"}},
           "urgency": {"type": "noul", "instructions": "Does this message express urgency?"}}}
        """#

    @Test(
        "README routing choice and urgency noul",
        .enabled(
            if: packDirectory != nil,
            "set DARKBLOOM_LIVE_MLX_TESTS=1 and DARKBLOOM_LIVE_MLX_PPLX_DECIDER_PATH=<converted pack directory>"))
    func readmeExamples() async throws {
        let directory = try #require(Self.packDirectory)
        _ = try #require(LiveInferenceFixtures.ensureMetallibColocated(), "mlx.metallib must sit beside the test binary")
        LiveInferenceFixtures.applyMemoryBudget(maxBytes: 96 * 1024 * 1024 * 1024)
        let modelID = EngineV2SupportedModels.pplxDeciderModelID
        let modelType = PplxDeciderConfiguration.modelType
        #expect(ProviderLoop.modelIsVLM(at: directory))

        let container = try await ModelContainerLoading.loadContainer(from: directory, modelID: modelID)
        let sizing = await SlotSizingSnapshot.build(
            container: container, modelPath: directory, fallbackDefaultMaxTokens: 512)
        let tokenizer = await container.perform { TokenizerHandle($0.tokenizer) }
        let preparation = SpecDecPreparation(
            artifact: nil, status: .disabled(.configDisabled, configured: false))
        let prepared = try await EngineV2SlotFactory.prepareProductionModel(
            modelId: modelID, isVLM: true, modelDirectory: directory,
            container: container, specDecPreparation: preparation)
        let grant = Int(min(
            UnifiedMemoryCap.kvBudgetBytes(
                physicalBytes: ProcessInfo.processInfo.physicalMemory,
                residentWeightBytes: UInt64(max(0, sizing.weightsBytes)),
                configReserveBytes: 0),
            UInt64(Int.max)))
        let bundle = try await EngineV2SlotFactory.makeProductionBundle(
            modelId: modelID, modelType: modelType, isVLM: true, modelDirectory: directory,
            container: container, tokenizer: tokenizer, sizing: sizing, kvBytesCapacity: grant,
            maxConcurrentRequests: 2, kvBudget: nil, specDecPreparation: preparation,
            preparedModel: prepared, environment: ["DARKBLOOM_PREFIX_CACHE": "0"])

        let bridge = bundle.bridge
        let request = try DecisionRequest.parse(Data(Self.readmeBody.utf8))
        let outcome: DecisionRunner.Outcome
        do {
            outcome = try await DecisionLocalServing.respond(
                to: request,
                acquire: { id in
                    .init(
                        tokenizer: tokenizer, releaseToken: .init(release: { _ in }, modelId: id),
                        modelType: modelType, container: container, isVLM: true,
                        engineV2Bridge: bridge)
                },
                modelTypeProvider: nil)
        } catch {
            await Self.retire(bundle)
            throw error
        }
        await Self.retire(bundle)

        let response = outcome.response
        print("pplx-decider README response: \(response.compactJSON)")
        #expect(response["object"] == .string("decision"))
        #expect(response["usage"]?["output_tokens"] == .integer("2"))
        #expect(outcome.inputTokens > 0)

        let routing = try #require(response["answers"]?["routing"])
        #expect(routing["type"] == .string("choice"))
        guard case .object(let distribution)? = routing["probabilities"] else {
            Issue.record("routing answer has no probabilities object")
            return
        }
        #expect(distribution.map(\.key) == ["billing", "technical_support", "sales"])
        let values = distribution.compactMap { member -> Double? in
            if case .float(let value) = member.value { return value }
            return nil
        }
        #expect(values.count == 3)
        #expect(values.allSatisfy { (0 ... 1).contains($0) })
        #expect(abs(values.reduce(0, +) - 1) < 1e-6)
        #expect(routing["choice"] == .string("technical_support"))

        let urgency = try #require(response["answers"]?["urgency"])
        #expect(urgency["type"] == .string("noul"))
        guard case .float(let noul)? = urgency["noul"] else {
            Issue.record("urgency answer has no noul probability")
            return
        }
        #expect((0 ... 1).contains(noul))
    }

    private static func retire(_ bundle: ProviderEngineBundle) async {
        await bundle.bridge.shutdown()
        bundle.releaseAssistant()
        MLX.Stream().synchronize()
        MLX.Memory.clearCache()
    }
}
