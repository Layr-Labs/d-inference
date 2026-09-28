import Foundation
import MLX

/// Own setup and failure retirement for the tiny profiled checks. Partial
/// construction and post-commit observation errors preserve the primary error
/// and every cleanup error; no healthy closed owner is cancelled again.
func withQwenLayerStageProfiledFixtureOwners<T>(fixture: QwenLayerStageFixture,
    proof: QwenLayerStageLoaderCheck, request: QwenLayerStageProfiledPrefillRequestSpec,
    includeBaseline: Bool,
    body: (CBv2RequestSession?, QwenSequentialStagePair) throws -> T
) throws -> T {
    var baseline: CBv2RequestSession?
    var stages: [QwenLayerStageSession] = []
    do {
        if includeBaseline {
            baseline = try CBv2RequestSession(loaded: fixture.baseline,
                promptCount: request.promptCount, outputCount: 1)
        }
        for stage in proof.stages {
            stages.append(try QwenLayerStageSession(stage: stage, plan: fixture.plan, profiledRequest: request))
        }
        guard stages.count == 2 else { throw ProbeError("Profiled fixture requires exactly two stage owners") }
        let pair = try QwenSequentialStagePair(first: stages[0], second: stages[1])
        let result = try body(baseline, pair)
        guard baseline?.isClosed != false, stages.allSatisfy(\.isClosed) else {
            throw ProbeError("Profiled fixture returned before retiring every request owner")
        }
        return result
    } catch {
        let primary = error
        var cleanup: [String] = []
        if let baseline, !baseline.isClosed {
            do { try MLX.withError { fault in try baseline.cancel(); try fault.check() } }
            catch { cleanup.append("baseline: \(error)") }
            if !baseline.isClosed { cleanup.append("baseline remains open") }
        }
        for (index, stage) in stages.enumerated() where !stage.isClosed {
            do { try MLX.withError { fault in try stage.cancel(); try fault.check() } }
            catch { cleanup.append("stage \(index): \(error)") }
            if !stage.isClosed { cleanup.append("stage \(index) remains open") }
        }
        if !cleanup.isEmpty {
            throw ProbeError("Profiled fixture failed (\(primary)); cleanup: \(cleanup.joined(separator: "; "))")
        }
        throw primary
    }
}
