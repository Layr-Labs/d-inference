// Copyright © 2026 Eigen Labs.
//
// Local endpoint decisions (`POST /v1/decisions`): acquire the slot once,
// read its decision block, run every question through a single-model engine
// view over that slot, and release the reservation on every exit.

import Foundation

enum DecisionLocalServing {
    static func respond(
        to request: DecisionRequest,
        acquire: @Sendable (String) async throws -> MultiModelBatchSchedulerEngine.AcquiredModel,
        modelTypeProvider: (@Sendable (String) async -> String?)?
    ) async throws -> DecisionRunner.Outcome {
        // Refuse a known non-decision model before loading or reserving it.
        if let knownType = await modelTypeProvider?(request.model) {
            try DecisionServingGate.validate(modelType: knownType, servesDecision: true)
        }
        let acquired = try await acquire(request.model)
        let release = acquired.releaseToken
        do {
            let configuration = try await DecisionRunner.configuration(
                modelType: acquired.modelType, container: acquired.container)
            let entry = MultiModelBatchSchedulerEngine.ModelRegistryEntry(
                tokenizer: acquired.tokenizer, modelType: acquired.modelType,
                container: acquired.container, diffusionContainer: acquired.diffusionContainer,
                isVLM: acquired.isVLM, engineV2Bridge: acquired.engineV2Bridge,
                visionGate: acquired.visionGate)
            let model = request.model
            // The acquisition above holds the slot for the whole request;
            // each question's engine view pins nothing further.
            let runner = DecisionRunner(configuration: configuration) { submission in
                MultiModelBatchSchedulerEngine(
                    registryProvider: { [model: entry] },
                    engineV2Logprobs: submission.logprobs,
                    decisionInputTokenLimit: submission.inputTokenLimit)
            }
            let outcome = try await runner.run(request)
            await release.fire()
            return outcome
        } catch {
            await release.fire()
            throw error
        }
    }
}
