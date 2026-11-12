// Stopping a row whose answer repeats one block verbatim (`GenerationLoopGuard`).

import Foundation
import MLXLMCommon
import ProviderCoreFoundation
#if canImport(os)
import os
#endif

extension EngineV2Bridge {
    #if canImport(os)
    private static let loopGuardLogger = Logger(
        subsystem: BuildEnvironment.current.logSubsystem, category: "engine_v2_loop_guard")
    #endif

    /// Stop the row in the engine, as a cancel does, but not as the caller's
    /// cancel: the pump turns the engine's cancelled terminal into a `length`
    /// finish with the tokens produced, so no `tokens_after_cancel` is taken.
    /// `endsThought`: the loop was inside the reasoning channel and the
    /// scheduler continues the answer after the thought
    /// (`LoopExitThinkingContinuation`); the row itself ends the same way.
    func stopRepeatingRow(
        id: String, modelType: String?, detection: GenerationLoopDetector.Detection, endsThought: Bool = false
    ) {
        if let cbv2Id = idMap[id] {
            ownedEngine?.cancel(cbv2Id)
        }
        #if canImport(os)
        // One line per stop: the model, its type, the period, the span and the tokens so far.
        Self.loopGuardLogger.notice(
            "loop guard stopped \(id, privacy: .public): \(self.modelId, privacy: .public) (\(modelType ?? "?", privacy: .public)) period \(detection.period) span \(detection.span) at \(detection.generatedTokens)\(endsThought ? "; the thought ends and the answer continues" : "", privacy: .public)")
        #endif
        var event = TelemetryEvent(
            source: .provider,
            severity: .info,
            kind: .engineHealth,
            message: endsThought
                ? "engine_v2: loop guard ended a repeating thought; the answer continues"
                : "engine_v2: loop guard ended a repeating answer as length"
        ).withFields([
            "component": .string("engine"),
            "operation": .string("engine_v2_loop_guard"),
            "backend": .string("engine_v2"),
            "model": .string(modelId),
            "model_type": .string(modelType ?? ""),
            "period_tokens": .int(detection.period),
            "span_tokens": .int(detection.span),
            "generated_tokens": .int(detection.generatedTokens),
            "ends_thought": .bool(endsThought),
        ])
        event.requestId = id
        emit(event)
    }
}
