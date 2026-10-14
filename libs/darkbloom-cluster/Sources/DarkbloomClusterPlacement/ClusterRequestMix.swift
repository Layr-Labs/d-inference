import DarkbloomClusterProtocol
import Foundation

/// The request a pair's own served requests look like, for the planner's
/// choice between tensor parallel (it decodes faster) and a pipeline (its
/// first token comes sooner): the median prompt and the median answer of the
/// requests the pair served, within the model's planned request. A pair that
/// serves short prompts and long answers is planned decode-heavy, one that
/// serves long prompts prompt-heavy. Nil before `minimumSamples` requests: the
/// model's planned request stands.
public enum ClusterRequestMix {
    public static let minimumSamples = 3

    public static func reference(_ samples: [ClusterServedSample], layout: ClusterModelLayout)
        -> (promptTokens: Int, outputTokens: Int)? {
        let pair = samples.filter { $0.valid && $0.route == .pair }
        guard pair.count >= minimumSamples,
              let prompt = ClusterServedCalibration.median(pair.map { Double($0.promptTokens) }),
              let output = ClusterServedCalibration.median(pair.map { Double($0.outputTokens) }) else { return nil }
        return (min(layout.maximumPromptTokens, max(1, Int(prompt.rounded()))),
                min(layout.maximumOutputTokens, max(1, Int(output.rounded()))))
    }
}

extension ClusterPlacementExplanation {
    /// Why the chosen deployment shards the model the way it does, in one
    /// plain line for the setup screen: tensor parallel or a pipeline, against
    /// the other, for the request the plan was made for. Nil without a choice.
    public static func deploymentReason(_ result: ClusterPlacementResult) -> String? {
        guard let chosen = result.chosen else { return nil }
        let regime = result.regime
        let request = "a \(result.promptTokens)-token prompt and \(result.outputTokens)-token answer"
        let mine = chosen.prediction(regime)
        func against(_ a: ClusterPlacementPrediction, _ b: ClusterPlacementPrediction) -> String {
            "decode \(rate(a.decodeTokensPerSecond)) vs \(rate(b.decodeTokensPerSecond)) tok/s, first token "
                + "\(seconds(a.firstTokenSeconds)) vs \(seconds(b.firstTokenSeconds))"
        }
        let assessment = result.tensorParallel
        if chosen.mode.usesTensorParallelDecode {
            if let other = result.alternatives.first(where: { !$0.mode.usesTensorParallelDecode }) {
                let theirs = other.prediction(regime)
                let gain = max(0, (theirs.requestSeconds / mine.requestSeconds - 1) * 100)
                return "Tensor parallel: predicted \(Int(gain.rounded()))% faster than a pipeline for \(request) (\(against(mine, theirs)))."
            }
            if let other = assessment?.bestOtherSeconds {
                let gain = max(0, (other / mine.requestSeconds - 1) * 100)
                return "Tensor parallel: predicted \(Int(gain.rounded()))% faster than a pipeline for \(request) "
                    + "(\(seconds(mine.requestSeconds)) against \(seconds(other)))."
            }
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
            guard let tp = assessment.tensorParallel else { return "\(name): tensor parallel is predicted slower for \(request)." }
            let theirs = tp.prediction(regime)
            return "\(name): tensor parallel is predicted slower for \(request) (\(seconds(theirs.requestSeconds)) against "
                + "\(seconds(mine.requestSeconds)); \(against(theirs, mine)))."
        case .doesNotFit:
            return "\(name): tensor parallel does not fit in these Macs' memory."
        case .notExecutedByRuntime:
            return "\(name): tensor parallel is predicted faster, but this runtime does not run it for this model."
        case .notQualified:
            return "\(name): tensor parallel is predicted faster, but no qualification admits it on these Macs."
        }
    }
}
