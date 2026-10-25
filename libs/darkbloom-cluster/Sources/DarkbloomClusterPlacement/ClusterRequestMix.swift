import DarkbloomClusterProtocol
import Foundation

/// The request a pair's own served requests look like, for the planner's
/// choice between tensor parallel (it decodes faster) and a pipeline (its
/// first token comes sooner): the median prompt and the median answer of the
/// requests the pair served, within the model's planned request. A pair that
/// serves short prompts and long answers is planned decode-heavy, one that
/// serves long prompts prompt-heavy. Nil before `minimumSamples` requests: the
/// model's planned request stands. The answer is at least
/// `minimumOutputTokens`: a pair probed with short readiness requests
/// (16-token answers, 2026-10-22) had a 10-token median answer, and at that
/// length the first token decided the served race, so a pipeline decoding
/// 39.6 tok/s was kept over tensor parallel decoding 114.8. Lengths are what
/// clients sent, not a speed: the planner reads them from every worker build's
/// records of the pair, while the speeds it takes are the current build's only
/// (`ClusterServedSpeedRecords.servedBy`).
public enum ClusterRequestMix {
    public static let minimumSamples = 3
    /// The shortest answer the reference request has.
    public static let minimumOutputTokens = 64

    public static func reference(_ samples: [ClusterServedSample], layout: ClusterModelLayout)
        -> (promptTokens: Int, outputTokens: Int)? {
        let pair = samples.filter { $0.valid && $0.route == .pair }
        guard pair.count >= minimumSamples,
              let prompt = ClusterServedCalibration.median(pair.map { Double($0.promptTokens) }),
              let output = ClusterServedCalibration.median(pair.map { Double($0.outputTokens) }) else { return nil }
        return (min(layout.maximumPromptTokens, max(1, Int(prompt.rounded()))),
                min(layout.maximumOutputTokens, max(minimumOutputTokens, Int(output.rounded()))))
    }
}

extension ClusterPlacementExplanation {
    /// Why the chosen deployment shards the model the way it does, in one
    /// plain line for the setup screen: tensor parallel or a pipeline, against
    /// the other, for the request the plan was made for. Nil without a choice.
    public static func deploymentReason(_ result: ClusterPlacementResult) -> String? {
        guard let chosen = result.chosen else { return nil }
        if let kept = result.keptModeReason {
            let name = chosen.mode.usesTensorParallelDecode ? "Tensor parallel" : chosen.mode.isHandOff ? "Hand-off (\(chosen.mode.rawValue))" : "Pipeline"
            return "\(name): \(kept)."
        }
        let regime = result.regime
        let request = "requests of \(result.promptTokens) prompt and \(result.outputTokens) answer tokens"
        let mine = chosen.prediction(regime)
        func against(_ a: ClusterPlacementPrediction, _ b: ClusterPlacementPrediction) -> String {
            "decode \(rate(a.decodeTokensPerSecond)) vs \(rate(b.decodeTokensPerSecond)) tok/s, first token "
                + "\(seconds(a.firstTokenSeconds)) vs \(seconds(b.firstTokenSeconds))"
        }
        let assessment = result.tensorParallel
        // Figures from the device index alone are a lower bound, far from what the pair serves (0.7 vs 1.6 tok/s
        // shown for a 27B that decoded 47 tok/s, 2026-10-16): the choice is said, the figures are not.
        let estimated = result.basis.source.isEstimate
        let note = " (an estimate: this model is not measured on these Macs yet)"
        if chosen.mode.usesTensorParallelDecode {
            // The best placement in another mode: among the alternatives, else the shard table's best pipeline.
            let pipelines = (result.shards?.options ?? []).filter { $0.kind == .pipeline || $0.kind == .pipelineCompactDecode }
                .compactMap(\.prediction).filter { $0.regime == regime }
            // Tensor parallel goes first wherever it fits (`ClusterPlacementPolicy.tensorParallelFirst`): a gain is said
            // only when the prediction shows one; otherwise the rule is the reason.
            let fits = "Tensor parallel: the model fits, so both Macs share every layer of every token."
            if let theirs = result.alternatives.first(where: { !$0.mode.usesTensorParallelDecode })?.prediction(regime)
                ?? pipelines.min(by: { $0.requestSeconds < $1.requestSeconds }) {
                if theirs.requestSeconds <= mine.requestSeconds { return fits }
                if estimated { return "Tensor parallel: predicted faster than a pipeline for \(request)\(note)." }
                let gain = (theirs.requestSeconds / mine.requestSeconds - 1) * 100
                return "Tensor parallel: predicted \(Int(gain.rounded()))% faster than a pipeline for \(request) (\(against(mine, theirs)))."
            }
            if let other = assessment?.bestOtherSeconds {
                if other <= mine.requestSeconds { return fits }
                if estimated { return "Tensor parallel: predicted faster than a pipeline for \(request)\(note)." }
                let gain = (other / mine.requestSeconds - 1) * 100
                return "Tensor parallel: predicted \(Int(gain.rounded()))% faster than a pipeline for \(request) "
                    + "(\(seconds(mine.requestSeconds)) against \(seconds(other)))."
            }
            // No pipeline was placed, and the reason is said as it is (2026-10-24: Qwen3.8 27B, whose images, video
            // and logprobs only tensor parallel keeps, read "no pipeline placement fits these Macs"): the policy left
            // it out (and says why), a cross-cable check diverged at every pipeline that fits, or none fits.
            if let excluded = result.modesReason { return "Tensor parallel: pipeline is left out (\(excluded))." }
            let verdicts = (result.shards?.options ?? []).filter { $0.kind != .tensorParallel && $0.kind != .tensorPipeline }.map(\.verdict)
            if verdicts.contains(.failedQualification) {
                return "Tensor parallel: every pipeline that fits these Macs diverged in a cross-cable check on these chips."
            }
            if !verdicts.isEmpty, !verdicts.contains(.doesNotFit) { return "Tensor parallel: this plan places no pipeline mode." }
            return "Tensor parallel: no pipeline placement fits these Macs."
        }
        let name = chosen.mode.isHandOff ? "Hand-off (\(chosen.mode.rawValue))" : "Pipeline"
        guard let assessment else { return "\(name): this model has no tensor-parallel plan." }
        switch assessment.verdict {
        case .chosen:
            return nil
        case .reductionNotMeasured:
            return assessment.reductionKeyed == nil
                ? "\(name): the link between the Macs has not been measured yet, so tensor parallel is not predicted; the first load measures it."
                : "\(name): the link was measured only without encryption, so tensor parallel is not predicted; the next load measures it encrypted."
        case .predictedSlower:
            guard let tp = assessment.tensorParallel, !estimated else {
                return "\(name): tensor parallel is predicted slower for \(request)\(estimated ? note : "")."
            }
            let theirs = tp.prediction(regime)
            return "\(name): tensor parallel is predicted slower for \(request) (\(seconds(theirs.requestSeconds)) against "
                + "\(seconds(mine.requestSeconds)); \(against(theirs, mine)))."
        case .doesNotFit:
            // A tensor-parallel placement that would load once memory is given back, ranked after one that loads now.
            if assessment.tensorParallel != nil || assessment.hybrid != nil {
                return "\(name): tensor parallel is \(assessment.reason)."
            }
            return "\(name): tensor parallel does not fit in these Macs' memory."
        case .notExecutedByRuntime:
            return "\(name): \(assessment.reason)."
        case .notQualified:
            return "\(name): \(assessment.reason)."
        }
    }

    /// What the setup's model list says under a model whose layout has a
    /// tensor-parallel plan when the planner split it otherwise: why not, in a
    /// few words (`tensorParallelNote`).
    public enum TensorParallelNote: String, CaseIterable, Sendable {
        /// Predicted slower than the chosen split.
        case slower = "tensor parallel: slower here"
        /// Predicted faster, but by less than the margin it must win by (`tensorParallelMargin`).
        case aboutAsFast = "tensor parallel: about as fast"
        /// It would fit once memory is given back; a split that loads now goes first.
        case doesNotFitNow = "tensor parallel: does not fit now"
        case doesNotFit = "tensor parallel: does not fit"
        /// No reduction measured over the keyed data plane yet: the pair's first load measures it.
        case linkUnmeasured = "tensor parallel: link unmeasured"
        /// A cross-cable check diverged at each tensor-parallel shape on these chips.
        case failedCheck = "tensor parallel: failed a check"
        /// Predicted faster, but the mode this pair keeps held it back (`keptModeReason`).
        case pipelineKept = "tensor parallel: pipeline kept"
        /// The placement policy leaves tensor parallel out (`modesReason` says why, when it says).
        case excluded = "tensor parallel: excluded here"
        /// This runtime does not execute tensor parallel for this model or rank count.
        case notForThisModel = "no tensor parallel for this model"
    }

    /// The longest `TensorParallelNote`: the setup's model list says it in a
    /// few words at the end of the model's one line (owner, 2026-10-15: one
    /// line per model) (`ClusterOnboardingModelChoice.tensorParallelNoteLimit`, the same).
    public static let tensorParallelNoteLimit = 33

    /// Why the chosen deployment is not tensor parallel, for the setup's model
    /// list, from the planner's own verdict (`ClusterTensorParallelAssessment`)
    /// and its best tensor-parallel placement against the chosen one. Nil when
    /// tensor parallel is chosen, when nothing is, and when the model has no
    /// tensor-parallel plan (nothing to say: no row for it).
    public static func tensorParallelNote(_ result: ClusterPlacementResult) -> TensorParallelNote? {
        guard let chosen = result.chosen, !chosen.mode.usesTensorParallelDecode, let assessment = result.tensorParallel else {
            return nil
        }
        let regime = result.regime
        let best = [assessment.tensorParallel, assessment.hybrid].compactMap { $0 }
            .min { $0.prediction(regime).requestSeconds < $1.prediction(regime).requestSeconds }
        switch assessment.verdict {
        case .chosen: return nil
        case .notExecutedByRuntime: return .notForThisModel
        case .reductionNotMeasured: return .linkUnmeasured
        case .doesNotFit: return best == nil ? .doesNotFit : .doesNotFitNow
        case .notQualified:
            // No placement to compare: the policy left the mode out. With one, a check diverged at each shape,
            // unless the mode this pair keeps held it back.
            guard best != nil else { return .excluded }
            return result.keptModeReason == nil ? .failedCheck : .pipelineKept
        case .predictedSlower:
            guard let best, best.prediction(regime).requestSeconds < chosen.prediction(regime).requestSeconds else { return .slower }
            return .aboutAsFast
        }
    }
}
