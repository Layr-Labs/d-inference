import DarkbloomClusterProtocol
import Foundation

/// One sharded deployment the planner considered for these members and this
/// model: what it is (cut or shares, every member's bytes), what it was
/// predicted to do, and why it was or was not chosen.
public struct ClusterShardOption: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// Every member holds a share of every layer (`tensor_parallel_v1`).
        case tensorParallel
        /// Layers split by cut (`pipeline_v1`).
        case pipeline
        /// The same pipeline with compact decode framing (`pipeline_compact_decode_v1`).
        case pipelineCompactDecode
        /// The same pipeline with decode as speculative rounds: the last member
        /// holds the model's head (`pipeline_mtp_v1`). Credited only from what
        /// this placement served with and without the rounds.
        case pipelineSpeculative
        /// Three or more members: tensor-parallel groups as stages of a
        /// pipeline. Predicted only: no runtime executes it yet.
        case tensorPipeline

        public var label: String {
            switch self {
            case .tensorParallel: "tensor parallel"
            case .pipeline: "pipeline"
            case .pipelineCompactDecode: "pipeline with compact decode"
            case .pipelineSpeculative: "pipeline with speculative rounds"
            case .tensorPipeline: "tensor parallel x pipeline"
            }
        }
    }

    public enum Verdict: String, Codable, Sendable {
        case chosen
        /// Predicted slower than the chosen deployment, or fitting less readily.
        case slower
        /// No runtime of this build executes it for this model.
        case notExecutedByRuntime
        /// The model's adapter has no tensor-parallel plan: it gets a pipeline.
        case adapterHasNoTensorParallel
        /// A qualification check failed at this shape, so the records keep it out.
        case failedQualification
        case doesNotFit
        /// Tensor parallel x pipeline needs three or more members.
        case needsMoreMembers
        /// No reduction over the link was measured on the keyed data plane.
        case reductionNotMeasured
    }

    public struct Member: Codable, Equatable, Sendable {
        public let device: String
        /// The layers it runs, `[firstLayer, endLayer)`.
        public let firstLayer: Int
        public let endLayer: Int
        /// Its share of every layer it runs, under tensor parallel; nil for a pipeline range.
        public let share: Double?
        public let weightsBytes: Int
        public let needBytes: Int
        /// 0 fits now ... 4 never (`ClusterPlacementFit.tier`).
        public let tier: Int
    }

    public let kind: Kind
    public let verdict: Verdict
    public let reason: String
    /// The generation mode it runs as; nil for tensor parallel x pipeline (no mode yet).
    public let mode: ClusterGenerationMode?
    public let cuts: [Int]
    /// Each member's share of every layer, in member order (tensor parallel).
    public let shares: [Double]?
    /// The members of each pipeline stage, in order (tensor parallel x pipeline).
    public let stages: [[String]]?
    public let members: [Member]
    public let prediction: ClusterPlacementPrediction?
}

/// The planner's sharded deployment candidates for one plan: the default
/// (owner, 2026-10-13) is a sharded deployment only, tensor parallel or
/// pipeline, chosen from the detected hardware, the measured link and the
/// model's own configuration. The hand-off modes are off unless opted in.
public struct ClusterShardAssessment: Codable, Equatable, Sendable {
    public let chosen: ClusterShardOption.Kind?
    /// Whether the hand-off modes were considered (never, in a result that carries this).
    public let handOffModes: Bool
    public let options: [ClusterShardOption]
    public let note: String
}

extension ClusterPlacementPlanner {
    static func shardKind(_ mode: ClusterGenerationMode) -> ClusterShardOption.Kind? {
        switch mode {
        case .pipeline: .pipeline
        case .pipelineCompactDecode: .pipelineCompactDecode
        case .pipelineMTP: .pipelineSpeculative
        case .tensorParallel: .tensorParallel
        case .phaseSplit, .phaseSplitMTP, .pipelinePrefillTensorDecode: nil
        }
    }

    static func members(_ c: ClusterPlacementCandidate, layerCount: Int) -> [ClusterShardOption.Member] {
        c.ranks.enumerated().map { index, r in
            .init(device: r.device, firstLayer: r.firstLayer, endLayer: r.endLayer,
                  share: c.mode.usesTensorParallelPrefill ? (c.shares?[index] ?? 1 / Double(c.ranks.count)) : nil,
                  weightsBytes: r.weightsBytes, needBytes: r.needBytes, tier: r.fit.tier)
        }
    }

    static func option(_ kind: ClusterShardOption.Kind, _ verdict: ClusterShardOption.Verdict, _ reason: String,
                       _ c: ClusterPlacementCandidate?, regime: ClusterPlacementPolicy.Regime, layerCount: Int) -> ClusterShardOption {
        .init(kind: kind, verdict: verdict, reason: reason, mode: c?.mode, cuts: c?.cuts ?? [],
              shares: c.flatMap { $0.mode.usesTensorParallelPrefill ? ($0.shares ?? Array(repeating: 1 / Double($0.ranks.count), count: $0.ranks.count)) : nil },
              stages: nil, members: c.map { members($0, layerCount: layerCount) } ?? [], prediction: c?.prediction(regime))
    }

    static func versus(_ c: ClusterPlacementCandidate, _ chosen: ClusterPlacementCandidate?, regime: ClusterPlacementPolicy.Regime) -> String {
        guard let chosen else { return "nothing was chosen" }
        let t = c.prediction(regime).requestSeconds, best = chosen.prediction(regime).requestSeconds
        if c.tier > chosen.tier { return "fits less readily than the chosen deployment (it needs memory freed first)" }
        // Times are seconds when every Mac's speed is measured, relative units otherwise.
        if c.mode.usesTensorParallelDecode, !chosen.mode.usesTensorParallelDecode, t < best {
            return String(format: "predicted request time %.4g against %.4g, inside the margin tensor parallel must win by", t, best)
        }
        if abs(t - best) <= best * 1e-9 {
            return "predicted the same request time as the chosen deployment; a tie keeps the mode the layout lists first"
        }
        return String(format: "predicted request time %.4g against %.4g for the chosen deployment", t, best)
    }

    static func assessShards(context: Context, admitted: [ClusterPlacementCandidate], qualified: [ClusterPlacementCandidate],
                             ranked: [ClusterPlacementCandidate], tensorParallel: ClusterTensorParallelAssessment?) throws -> ClusterShardAssessment {
        let layout = context.layout, policy = context.policy, regime = policy.regime, layers = layout.layerCount
        let chosen = ranked.first
        var options: [ClusterShardOption] = []
        for mode in [ClusterGenerationMode.pipeline, .pipelineCompactDecode, .pipelineMTP] {
            let kind = shardKind(mode)!
            guard layout.generationModes.contains(mode), context.modes.contains(mode) else {
                options.append(option(kind, .notExecutedByRuntime, "this runtime does not execute \(mode.rawValue) for this model", nil,
                    regime: regime, layerCount: layers))
                continue
            }
            if let best = ranked.first(where: { $0.mode == mode }) {
                options.append(best == chosen
                    ? option(kind, .chosen, "the fastest sharded deployment that fits, cut from each Mac's memory and speed", best, regime: regime, layerCount: layers)
                    : option(kind, .slower, versus(best, chosen, regime: regime), best, regime: regime, layerCount: layers))
            } else if let refused = context.ordered(admitted.filter { $0.mode == mode && $0.possible }, regime: regime).first {
                options.append(option(kind, .failedQualification, "a cross-cable check diverged at its shape on these Macs (each rank's chip, "
                    + "the cut, the mode), so it is never planned here", refused, regime: regime, layerCount: layers))
            } else {
                options.append(option(kind, .doesNotFit, "no cut of this model fits these Macs in this mode",
                    admitted.filter { $0.mode == mode }.min { context.shortBytes($0) < context.shortBytes($1) }, regime: regime, layerCount: layers))
            }
        }
        options.append(tensorParallelOption(context: context, ranked: ranked, assessment: tensorParallel))
        options.append(tensorPipelineOption(context: context))
        let order: [ClusterShardOption.Kind] = [.tensorParallel, .pipeline, .pipelineCompactDecode, .pipelineSpeculative, .tensorPipeline]
        options.sort { order.firstIndex(of: $0.kind)! < order.firstIndex(of: $1.kind)! }
        return .init(chosen: chosen.flatMap { shardKind($0.mode) }, handOffModes: false, options: options,
            note: "Phase split, phase split + MTP, the pipeline-prefill/tensor-decode hybrid and the per-request alone route are kept "
                + "but off by default (sharded deployments only); only the explicit hand-off opt-in considers them.")
    }

    static func tensorParallelOption(context: Context, ranked: [ClusterPlacementCandidate],
                                     assessment: ClusterTensorParallelAssessment?) -> ClusterShardOption {
        let layout = context.layout, regime = context.policy.regime, layers = layout.layerCount
        guard layout.tensorParallel != nil else {
            return option(.tensorParallel, .adapterHasNoTensorParallel, "this model's layout carries no tensor-parallel facts (its adapter "
                + "has no plan dividing its layers by heads and channels in this build), so it is sharded as a pipeline", nil,
                regime: regime, layerCount: layers)
        }
        if let best = ranked.first(where: { $0.mode == .tensorParallel }) {
            if best == ranked.first {
                return option(.tensorParallel, .chosen, "predicted faster than every pipeline by at least the margin"
                    + (best.shares != nil ? ", at the shares that balance the two Macs' steps" : ""), best, regime: regime, layerCount: layers)
            }
            return option(.tensorParallel, .slower, versus(best, ranked.first, regime: regime), best, regime: regime, layerCount: layers)
        }
        guard let assessment else {
            return option(.tensorParallel, .reductionNotMeasured, "not assessed", nil, regime: regime, layerCount: layers)
        }
        let verdict: ClusterShardOption.Verdict
        switch assessment.verdict {
        case .chosen: verdict = .chosen
        case .predictedSlower: verdict = .slower
        case .notExecutedByRuntime: verdict = .notExecutedByRuntime
        case .notQualified: verdict = .failedQualification
        case .doesNotFit: verdict = .doesNotFit
        case .reductionNotMeasured: verdict = .reductionNotMeasured
        }
        return option(.tensorParallel, verdict, assessment.reason, assessment.tensorParallel, regime: regime, layerCount: layers)
    }

    /// Three or more members: every ordered grouping of all members into
    /// pipeline stages of one member or of a rank count the family's plan
    /// divides by (at least one such group), at every admitted cut set;
    /// the best by hardware fit, then predicted request time. Model-free: no runtime
    /// executes it, so it is reported and never chosen.
    static func tensorPipelineOption(context: Context) -> ClusterShardOption {
        let layout = context.layout, devices = context.devices
        func refuse(_ verdict: ClusterShardOption.Verdict, _ reason: String) -> ClusterShardOption {
            .init(kind: .tensorPipeline, verdict: verdict, reason: reason, mode: nil, cuts: [], shares: nil, stages: nil, members: [], prediction: nil)
        }
        guard let tp = layout.tensorParallel else {
            return refuse(.adapterHasNoTensorParallel, "this model's adapter has no tensor-parallel plan, so no stage can be tensor parallel")
        }
        guard devices.count >= 3 else {
            return refuse(.needsMoreMembers, "it needs three or more members (a tensor-parallel group of two as one stage and at least one more stage)")
        }
        guard let reduction = context.link.reduction else {
            return refuse(.reductionNotMeasured, "no reduction over the link has been measured, so no tensor-parallel stage can be predicted")
        }
        guard devices.count <= 6 else { return refuse(.notExecutedByRuntime, "more than six members are not enumerated") }
        let sizes = [1] + tp.family.ranks
        // Compositions of the member count into stage sizes, at least two stages, at least one tensor-parallel group.
        func compositions(_ left: Int) -> [[Int]] {
            if left == 0 { return [[]] }
            return sizes.filter { $0 <= left }.flatMap { size in compositions(left - size).map { [size] + $0 } }
        }
        let shapes = compositions(devices.count).filter { $0.count >= 2 && $0.contains { $0 >= 2 } }
        func permutations(_ items: [Int]) -> [[Int]] {
            items.count <= 1 ? [items] : items.indices.flatMap { i -> [[Int]] in
                var rest = items; let head = rest.remove(at: i)
                return permutations(rest).map { [head] + $0 }
            }
        }
        let orders = permutations(Array(devices.indices))
        // Chosen by hardware and predicted time; `tier` only reports live memory.
        var best: (option: ClusterShardOption, group: Int, time: Double)?
        for shape in shapes {
            var seen = Set<[[Int]]>()
            let cutSets = context.cutSets(layout.admittedCuts, shape.count - 1)
            for order in orders {
                var stages: [[Int]] = [], at = 0
                for size in shape { stages.append(Array(order[at..<(at + size)]).sorted()); at += size }
                guard seen.insert(stages).inserted else { continue }
                for cuts in cutSets {
                    let evaluated = evaluateTensorPipeline(context: context, stages: stages, cuts: cuts, reduction: reduction)
                    let time = evaluated.prediction.requestSeconds
                    let group = evaluated.hardwareFits ? 0 : 4
                    if best == nil || group < best!.group || (group == best!.group && time < best!.time) {
                        best = (.init(kind: .tensorPipeline, verdict: .notExecutedByRuntime, reason: "", mode: nil, cuts: cuts, shares: nil,
                            stages: stages.map { $0.map { devices[$0].label } }, members: evaluated.members, prediction: evaluated.prediction),
                            group, time)
                    }
                }
            }
        }
        guard let best else { return refuse(.doesNotFit, "no grouping of these members into stages has an admitted cut") }
        let o = best.option
        guard best.group < 4 else {
            return .init(kind: o.kind, verdict: .doesNotFit, reason: "no grouping of these members fits", mode: nil, cuts: o.cuts,
                shares: nil, stages: o.stages, members: o.members, prediction: o.prediction)
        }
        let reason = String(format: "predicted %.2f s for the request; no runtime executes tensor-parallel stages in a pipeline yet, "
            + "so it is reported and never chosen", best.time)
        return .init(kind: o.kind, verdict: .notExecutedByRuntime, reason: reason, mode: nil, cuts: o.cuts, shares: nil,
            stages: o.stages, members: o.members, prediction: o.prediction)
    }

    /// One tensor parallel x pipeline candidate: each stage's members hold an
    /// equal share of the stage's layers (one member: the range whole); a
    /// stage steps at its slowest share of its layers plus its reductions, and
    /// the pipeline's step is the stages' sum (prefill: the slowest stage sets
    /// the pace, one chunk passes through the rest).
    static func evaluateTensorPipeline(context: Context, stages: [[Int]], cuts: [Int], reduction: ClusterReductionCost)
        -> (members: [ClusterShardOption.Member], tier: Int, hardwareFits: Bool, prediction: ClusterPlacementPrediction) {
        let layout = context.layout, tp = layout.tensorParallel!, regime = context.policy.regime
        let bounds = [0] + cuts + [layout.layerCount]
        let total = layout.layers.reduce(0.0) { $0 + $1.cost }
        let context_ = context.memoryContext, memoryChunk = min(layout.maximumChunkTokens, context.memoryPrompt)
        let chunk = min(layout.maximumChunkTokens, context.prompt)
        var members: [ClusterShardOption.Member] = [], tier = 0, hardwareFits = true, decode: [Double] = [], prefill: [Double] = [], measured = true
        for (index, stage) in stages.enumerated() {
            let range = layout.range(bounds[index]..<bounds[index + 1])
            let k = stage.count, share = range.cost / total
            let reductions = k > 1 ? tp.family.reductionsPerLayer * range.layers.count
                + (range.layers.upperBound == layout.layerCount ? tp.family.reductionsPerStep : 0) : 0
            var stageDecode = 0.0, stagePrefill = 0.0
            for member in stage {
                let device = context.devices[member], memory = device.profile.memory
                let (rates, known) = context.rates(device, regime)
                measured = measured && known
                var weights = 0, tensors = 0, largest = 0
                if k == 1 {
                    weights = range.loadedBytes; tensors = range.tensorCount; largest = range.largestTensorBytes
                } else {
                    for layer in range.layers {
                        weights += tp.shareBytes(divided: tp.layerDividedBytes[layer], replicated: tp.layerReplicatedBytes[layer], ranks: k)
                        tensors += layout.layers[layer].weights.tensorCount
                        largest = max(largest, layout.layers[layer].weights.largestTensorBytes)
                    }
                    if range.layers.lowerBound == 0 {
                        weights += tp.shareBytes(divided: tp.ingressDividedBytes, replicated: tp.ingressReplicatedBytes, ranks: k)
                        tensors += layout.ingress.tensorCount; largest = max(largest, layout.ingress.largestTensorBytes)
                    }
                    if range.layers.upperBound == layout.layerCount {
                        weights += tp.shareBytes(divided: tp.egressDividedBytes, replicated: tp.egressReplicatedBytes, ranks: k)
                        tensors += layout.egress.tensorCount; largest = max(largest, layout.egress.largestTensorBytes)
                    }
                }
                let load = context.loadNeed([(loaded: weights, tensors: tensors, largest: largest)], memory: memory)
                func part(_ bytes: Int) -> Int { k > 1 && tp.family.stateDividesByHeads ? (bytes + k - 1) / k : bytes }
                let state = max(context.policy.requestChargeEveryRankBytes ?? layout.requestChargeEveryRankBytes(context: context_),
                                part(range.stateBytes(tokens: context_)))
                let request = max(memory.minimumAdmissibleBytes, state + part(range.requestWorkBytes)
                    + part(range.transientBytes(chunk: memoryChunk, context: context_)) + (layout.allowanceEveryRankBytes ?? 0)
                    + memory.loadingHeadroomBytes)
                let need = max(load.need, load.held + request)
                let fit = device.profile.fit(needBytes: need, weightsBytes: load.held, largestTensorBytes: load.largest)
                tier = max(tier, fit.tier)
                hardwareFits = hardwareFits
                    && device.profile.hardwareFits(needBytes: need, weightsBytes: load.held, largestTensorBytes: load.largest)
                members.append(.init(device: device.label, firstLayer: range.layers.lowerBound, endLayer: range.layers.upperBound,
                    share: k > 1 ? 1 / Double(k) : nil, weightsBytes: load.held, needBytes: need, tier: fit.tier))
                let split = ClusterDecodeSplit(rates: rates)
                stageDecode = max(stageDecode, share * (k > 1 ? split.shareStepSeconds(ranks: k) : split.wholeStepSeconds))
                let shard = k > 1 ? (rates.tensorShardPrefillTokensPerSecond ?? rates.prefillTokensPerSecond) : rates.prefillTokensPerSecond
                stagePrefill = max(stagePrefill, share / shard)
            }
            decode.append(stageDecode + Double(reductions) * reduction.seconds(bytes: tp.family.partialBytesPerToken))
            prefill.append(stagePrefill + (k > 1 ? Double(tp.family.reductionsPerLayer * range.layers.count)
                * reduction.seconds(bytes: chunk * tp.family.partialBytesPerToken) / Double(chunk) : 0))
        }
        let chunks = (context.prompt + chunk - 1) / chunk
        let slowest = prefill.max() ?? 0, sum = prefill.reduce(0, +)
        let first = Double(context.prompt) * slowest + Double(chunk) * (sum - slowest)
            + Double(chunks * (stages.count - 1)) * context.link.perChunkSeconds
        let step = decode.reduce(0, +) + (context.link.perDecodeStepSeconds[ClusterGenerationMode.pipeline.rawValue] ?? 0)
        return (members, tier, hardwareFits, .init(regime: regime, regimeMeasuredOnEveryDevice: measured, firstTokenSeconds: first,
            prefillTokensPerSecond: Double(context.prompt) / first, decodeTokensPerSecond: 1 / step,
            requestSeconds: first + Double(max(0, context.outputs - 1)) * step))
    }
}
