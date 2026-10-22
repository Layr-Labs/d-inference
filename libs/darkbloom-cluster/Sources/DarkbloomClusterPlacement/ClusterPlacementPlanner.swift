import DarkbloomClusterProtocol
import Foundation

public struct ClusterPlacementDevice: Sendable {
    /// The label the setup uses for this member. Not a host name.
    public let label: String
    public let profile: ClusterDeviceProfile
    public let speed: ClusterDeviceSpeed
    public init(label: String, profile: ClusterDeviceProfile, speed: ClusterDeviceSpeed) {
        self.label = label; self.profile = profile; self.speed = speed
    }
}

/// What is typed on purpose: the request the ranking optimises and how.
public struct ClusterPlacementPolicy: Sendable {
    public enum Regime: String, Codable, Sendable { case sustained, rested }
    /// The reference request. Nil means the model profile's largest.
    public var promptTokens: Int?
    public var outputTokens: Int?
    /// Which of a device's two measured rates the ranking uses. Rested is the
    /// default until the running pair can refine a plan from its own stage
    /// times: a device's settled rate alone understates what it sustains
    /// inside a placement (by 15 to 22 % for one Mac of the pair this was
    /// measured on), and a plan made from it moves the cut too far.
    public var regime: Regime = .rested
    /// Nil means every mode and schedule the layout lists.
    public var modes: [ClusterGenerationMode]?
    public var schedules: [ClusterPrefillSchedule]?
    /// A Mac alone is reported "as fast" when its predicted request time is
    /// within this share of the chosen placement's.
    public var tieTolerance = 0.03
    /// The runtime executes two ranges.
    public var maximumRanges = 2
    public var maximumCandidates = 200_000
    public var alternatives = 5
    /// When set, only placements whose first range (rank 0, the leader) is
    /// this device are considered: the installed path starts a session from
    /// rank 0's Mac, so a Mac that cannot reach the other one cannot lead.
    /// Each Mac alone is still evaluated, and nothing else changes.
    public var leader: String?
    /// A request longer than the layout's planned one (its maximum prompt
    /// plus output), up to this context: the family's own largest, which
    /// its ranks admit at load when memory allows. Nil plans within the
    /// layout's limits only. Set together with `requestChargeEveryRankBytes`.
    public var largestContextTokens: Int?
    /// What the family's request gate charges every rank at the requested
    /// context (`ClusterModelLayout.requestChargeEveryRankBytes` is at the
    /// layout's planned request). Nil uses the layout's.
    public var requestChargeEveryRankBytes: Int?
    /// The placement shapes the model's qualification records allow, when
    /// they restrict shapes (the shapes a cross-cable check diverged at on
    /// those chips): called with a candidate's chip names in rank order
    /// (`ClusterDeviceProfile.chip`), its cuts and its mode. A candidate it
    /// refuses is never chosen, ranked or offered as an alternative; the
    /// structural and any-boundary bests still say what memory alone would
    /// allow. Nil, the default, admits every shape.
    public var admitsShape: (@Sendable (_ chips: [String], _ cuts: [Int], _ mode: ClusterGenerationMode) -> Bool)?
    /// A tensor-parallel placement is chosen only when it is predicted at
    /// least this share faster than the best placement in any other mode of
    /// the same tier: its prediction rests on two more measured inputs (the
    /// shard probe and the keyed reduction), so a near tie keeps the mode that
    /// has run. Equal or slower is never chosen.
    public var tensorParallelMargin = 0.05
    /// Sharded deployments only, by default (owner, 2026-10-13): the hand-off
    /// modes (`ClusterGenerationMode.isHandOff`: phase split, phase split +
    /// MTP, the pipeline-prefill/tensor-decode hybrid) are considered only
    /// when this is true, the one explicit opt-in (the provider sets it from
    /// `DARKBLOOM_CLUSTER_HANDOFF_MODES=1`). Naming a hand-off mode in `modes`
    /// does not opt in. Under the opt-in a plan is the earlier planner's,
    /// byte for byte (no `shards` table).
    public var handOffModes = false
    /// DEVELOPER ONLY, never set on a user's path (`ClusterForcedMode`; the
    /// provider sets it from `DARKBLOOM_CLUSTER_FORCE_MODE` in a debug build):
    /// only this mode family is placed and its fastest placement is chosen,
    /// whatever the other families are predicted to do. Memory, the model's
    /// mode list and `admitsShape` still apply; a forced family with no
    /// placement is refused with the reason. Nil, the default: the planner chooses.
    public var forcedMode: ClusterForcedMode?
    /// The decode speed-up the model's passing qualification records of a
    /// pipeline's speculative rounds (`pipeline_mtp_v1`) measured over the
    /// plain pipeline of their placement
    /// (`ClusterPairQualificationRecord.measuredPipelineSpeculativeSpeedup`;
    /// the smallest when several do). It credits the rounds wherever the
    /// decoding rank has no served measurement of its own
    /// (`ClusterSpeedRates.pipelineSpeculativeFactor`, which always wins):
    /// owner rule, on by default where lossless and measured faster. Nil, the
    /// default, credits nothing, and the plain pipeline ranks first.
    public var recordedPipelineSpeculativeFactor: Double?
    public init() {}
}

public struct ClusterPlacementRank: Codable, Equatable, Sendable {
    public let rank: Int
    public let device: String
    public let firstLayer: Int
    public let endLayer: Int
    /// Weights this rank holds once loaded.
    public let weightsBytes: Int
    /// The largest amount the load gate asks for during this rank's load.
    public let loadNeedBytes: Int
    /// What the request gate asks for with the weights resident.
    public let requestNeedBytes: Int
    /// Admissible memory this rank needs before it starts loading.
    public let needBytes: Int
    public let admissibleNowBytes: Int
    public let fit: ClusterPlacementFit
    /// False when weights, request state and the attention transient exceed
    /// what that Mac keeps resident (its wired limit, else the GPU's
    /// recommended working set).
    public let withinGPUWorkingSet: Bool
    /// One prefill frame's attention transient at the reference request,
    /// included in `requestNeedBytes`. Nil in a result written before it was priced.
    public let transientBytes: Int?
    /// `ClusterDeviceProfile.hardwareFits`: the hardware can hold this range.
    /// Nil in a result written before it was recorded (read as `fit.possible`).
    public var hardwareFits: Bool? = nil
}

public struct ClusterPlacementPrediction: Codable, Equatable, Sendable {
    public let regime: ClusterPlacementPolicy.Regime
    /// False when a device had no rate for this regime and its other rate was used.
    public let regimeMeasuredOnEveryDevice: Bool
    public let firstTokenSeconds: Double
    public let prefillTokensPerSecond: Double
    public let decodeTokensPerSecond: Double
    public let requestSeconds: Double
}

public struct ClusterPlacementCandidate: Codable, Equatable, Sendable {
    /// Stage boundaries between ranges: one for a pair, the cut.
    public let cuts: [Int]
    public let mode: ClusterGenerationMode
    public let prefillSchedule: ClusterPrefillSchedule
    public let ranks: [ClusterPlacementRank]
    public let sustained: ClusterPlacementPrediction
    public let rested: ClusterPlacementPrediction
    /// Worst device answer: 0 fits now, 1 the kernel would give the memory
    /// but the gate counts less, 2 applications must release memory, 3 only
    /// a restart would do, 4 never.
    public let tier: Int
    /// Every rank's hardware can hold its range, or its load gate admits it
    /// now: the at-rest ceiling assumes the kernel's file-cache minimum, which
    /// can sit below what a Mac admits now, and a split that loads now is never
    /// impossible (owner, 2026-10-19). `tier` reports what the Macs' memory
    /// allows right now (the load gate still decides).
    public var possible: Bool { ranks.allSatisfy { $0.fit.tier == 0 || ($0.hardwareFits ?? $0.fit.possible) } }
    public let withinGPUWorkingSet: Bool
    /// Smallest share of admissible memory left over on any rank; negative
    /// when a rank does not fit now.
    public let smallestHeadroomShare: Double
    /// The first cut; 0 for tensor parallel, which cuts no layer range.
    public var cut: Int { cuts.first ?? 0 }
    /// Tensor parallel with unequal shares: each rank's share weight (rank
    /// order); nil for equal shards and every other mode.
    public var tensorShares: [Int]? = nil
    /// Tensor parallel with unequal shares (`ClusterTensorParallelFamilyPlan.shareUnits`):
    /// each rank's share of every layer, in rank order. Nil for equal shares
    /// and for every other mode (omitted then, so a plan reads as before).
    public var shares: [Double]? = nil
    public func prediction(_ regime: ClusterPlacementPolicy.Regime) -> ClusterPlacementPrediction {
        regime == .sustained ? sustained : rested
    }
    /// A phase split's decoding member (the last rank, which holds every
    /// layer) serving a request alone, as the per-request router prices it
    /// (`ClusterRequestRouter`). Nil under a pipeline: no member holds every layer.
    public var aloneRoute: ClusterPlacementAloneRoute? = nil
    /// The request's time on the route the router would take: the placement
    /// as placed, or its decoding member alone when that is predicted faster.
    /// The ranking uses this, so a placement whose fast member can serve alone
    /// is never ranked as if every request had to cross the link.
    public func routedSeconds(_ regime: ClusterPlacementPolicy.Regime) -> Double {
        min(prediction(regime).requestSeconds, aloneRoute?.prediction(regime).requestSeconds ?? .infinity)
    }
    /// True when the decoding member alone is predicted faster for the planned request.
    public func routesAlone(_ regime: ClusterPlacementPolicy.Regime) -> Bool {
        (aloneRoute?.prediction(regime).requestSeconds ?? .infinity) < prediction(regime).requestSeconds
    }
}

/// The decoding member of a phase split serving the whole request by itself:
/// every layer on that Mac, serial prefill, decode as the placement's mode
/// decodes there (with the model's head when the mode runs it). No link.
public struct ClusterPlacementAloneRoute: Codable, Equatable, Sendable {
    public let device: String
    public let sustained: ClusterPlacementPrediction
    public let rested: ClusterPlacementPrediction
    public func prediction(_ regime: ClusterPlacementPolicy.Regime) -> ClusterPlacementPrediction {
        regime == .sustained ? sustained : rested
    }
}

/// One Mac holding the whole model, for comparison with a placement.
public struct ClusterPlacementAlone: Codable, Equatable, Sendable {
    public let device: String
    public let needBytes: Int
    public let fit: ClusterPlacementFit
    public let withinGPUWorkingSet: Bool
    public let sustained: ClusterPlacementPrediction
    public let rested: ClusterPlacementPrediction
    public func prediction(_ regime: ClusterPlacementPolicy.Regime) -> ClusterPlacementPrediction {
        regime == .sustained ? sustained : rested
    }
}

public struct ClusterPlacementRefusal: Codable, Equatable, Sendable {
    public struct Device: Codable, Equatable, Sendable {
        public let device: String
        public let physicalMemoryBytes: Int
        public let admissibleNowBytes: Int
        public let withApplicationsClosedBytes: Int
        /// The most it could hold from the start of the model, whatever is
        /// freed on it: a layer count (0 when not even one) and those bytes.
        public let mostLayersAsFirst: Int
        public let mostBytesAsFirst: Int
        /// The same from the end of the model.
        public let mostLayersAsLast: Int
        public let mostBytesAsLast: Int
    }
    public let devices: [Device]
    /// The admitted placement that comes closest; its ranks say which Mac is
    /// short and by how much.
    public let closest: ClusterPlacementCandidate?
    public let modelLoadedBytes: Int
    /// For a pair, in the better order: the layers neither Mac could hold
    /// whatever is freed, and their bytes. Nil for more than two devices.
    public let uncoveredLayers: Int?
    public let uncoveredBytes: Int?
    /// True when a cut the family's plan could make, but this runtime does
    /// not admit, would fit. Then the cut list is what refuses, not memory.
    public let fitsAtAStructuralCut: Bool
    /// True when some layer boundary would fit, admitted by the plan or not.
    public let fitsAtSomeLayerBoundary: Bool
}

/// How good the speed inputs were, the weakest device deciding.
public struct ClusterPlacementBasis: Codable, Equatable, Sendable {
    public let source: ClusterDeviceSpeed.Source
    /// False when the predicted times are meaningful only relative to each other.
    public let absolute: Bool
    public let linkCostsMeasured: Bool
}

public struct ClusterPlacementResult: Codable, Equatable, Sendable {
    public let runtimeModelID: String
    public let promptTokens: Int
    public let outputTokens: Int
    public let regime: ClusterPlacementPolicy.Regime
    public let basis: ClusterPlacementBasis
    /// The chosen division between devices; nil when none is possible. The
    /// model is then either held by one Mac alone (`alone`) or refused.
    public let chosen: ClusterPlacementCandidate?
    public let alternatives: [ClusterPlacementCandidate]
    /// The chosen placement had the other regime been optimised.
    public let chosenForOtherRegime: ClusterPlacementCandidate?
    /// The best over every cut the family's plan could make, and over every
    /// layer boundary: what the admitted list and the plan's rule each cost.
    public let bestStructural: ClusterPlacementCandidate?
    public let bestAnyBoundary: ClusterPlacementCandidate?
    public let alone: [ClusterPlacementAlone]
    /// Devices that hold the whole model at least as readily as the chosen
    /// placement fits and are predicted as fast for this request, within the
    /// tie tolerance. A prompt of one chunk cannot overlap across ranks, so a
    /// short request is often here.
    public let aloneAsFast: [String]
    public let refusal: ClusterPlacementRefusal?
    /// The member the chosen placement's router sends the planned request to,
    /// alone: the phase split's decoding member, which holds every layer, when
    /// it is predicted faster than the pair for that request. Nil when the
    /// pair serves it (or no member holds every layer).
    public var routedAlone: String? = nil
    public let candidatesConsidered: Int
    /// Placements that would be possible but whose shape the policy's
    /// `admitsShape` refused (a shape that diverged on these chips). Nil when
    /// the policy restricts no shape.
    public let unqualifiedPossible: Int?
    /// What tensor parallel was predicted to do here, chosen or not, and why.
    /// Nil when the layout has no tensor-parallel facts (omitted then, so a
    /// plan of such a layout is byte for byte what it was).
    public var tensorParallel: ClusterTensorParallelAssessment? = nil
    /// Every sharded deployment candidate (tensor parallel, pipeline, its
    /// compact decode variant, tensor parallel x pipeline), its prediction and
    /// why it was or was not chosen. Nil under the hand-off opt-in, whose plan
    /// is the earlier planner's byte for byte.
    public var shards: ClusterShardAssessment? = nil
}

/// Decides how a model is divided between devices from what the devices
/// detected and what the artifact is made of. Pure: no clock, no system call,
/// no table of machines. It admits nothing; the load gate decides at load.
public enum ClusterPlacementPlanner {
    enum CutScope { case admitted, structural, anyBoundary }

    public static func plan(devices: [ClusterPlacementDevice], layout: ClusterModelLayout,
                            policy: ClusterPlacementPolicy = .init(),
                            link: ClusterLinkCosts = .unmeasured) throws -> ClusterPlacementResult {
        try layout.validate()
        guard devices.count >= 2, Set(devices.map(\.label)).count == devices.count,
              devices.allSatisfy({ !$0.label.isEmpty && $0.label.utf8.count <= 64 }) else {
            throw ClusterPlacementError("Placement needs two or more devices with distinct labels")
        }
        for device in devices { try device.profile.validate() }
        // Tensor parallel against a pipeline compares seconds of compute with
        // seconds of link: speeds that are only ratios become each Mac's own
        // index estimate when that choice is open (`ClusterHardwarePrior`).
        let devices = ClusterHardwarePrior.absolute(devices, layout: layout, link: link)
        let prompt = policy.promptTokens ?? layout.maximumPromptTokens
        let outputs = policy.outputTokens ?? layout.maximumOutputTokens
        if let largest = policy.largestContextTokens {
            // A requested context beyond the layout's planned request, within
            // the family's own largest; the family's charge at it comes with it.
            guard policy.requestChargeEveryRankBytes != nil, largest <= ClusterWorkerLimits.contextTokens,
                  prompt >= 1, outputs >= 1, prompt + outputs <= largest,
                  prompt <= ClusterWorkerLimits.promptTokens, outputs <= ClusterWorkerLimits.outputTokens else {
                throw ClusterPlacementError("The requested context is outside the model's largest context")
            }
        } else {
            guard (1...layout.maximumPromptTokens).contains(prompt), (1...layout.maximumOutputTokens).contains(outputs) else {
                throw ClusterPlacementError("The reference request is outside the model profile's limits")
            }
        }
        let allowed = layout.generationModes.filter { policy.modes?.contains($0) ?? true }
        var modes = allowed.filter { policy.handOffModes || !$0.isHandOff }
        let schedules = layout.prefillSchedules.filter { policy.schedules?.contains($0) ?? true }
        if modes.isEmpty, !allowed.isEmpty {
            throw ClusterPlacementError("The policy allows only modes that hand the request state off (phase split or the hybrid), "
                + "and hand-off modes are off by default: a cluster shards the model (tensor parallel or pipeline)")
        }
        guard !modes.isEmpty, !schedules.isEmpty else {
            throw ClusterPlacementError("The policy allows no generation mode or prefill schedule this model lists")
        }
        var link = link
        if let forced = policy.forcedMode {
            // A developer setting (`ClusterForcedMode`): only the forced family is placed. Its stage adapter must exist.
            modes = modes.filter(forced.admits)
            guard !modes.isEmpty else {
                throw ClusterPlacementError("Developer setting: \(forced.words) forced, but \(layout.runtimeModelID) has no \(forced.words) mode "
                    + "in this build (no stage adapter runs it)")
            }
            if forced == .tensorParallel {
                guard let tp = layout.tensorParallel, tp.family.ranks.contains(min(policy.maximumRanges, devices.count)) else {
                    throw ClusterPlacementError("Developer setting: tensor parallel forced, but \(layout.runtimeModelID) has no tensor parallel mode "
                        + "for \(min(policy.maximumRanges, devices.count)) Macs (no stage adapter runs it)")
                }
                // Nothing measured the link yet: an assumed keyed reduction, labelled as such, so the mode can be placed.
                link = link.assumingForcedReduction()
            }
        }
        let context = Context(devices: devices, layout: layout, prompt: prompt, outputs: outputs,
            modes: modes, schedules: schedules, link: link, policy: policy)
        let admitted = try context.candidates(.admitted)
        // Shapes that diverged on these chips are left out here, before any
        // ranking: they are never chosen, ranked or offered as alternatives.
        let qualified = policy.admitsShape.map { admits in
            admitted.filter { candidate in
                admits(candidate.ranks.map { rank in devices.first { $0.label == rank.device }?.profile.chip ?? "" },
                       candidate.cuts, candidate.mode)
            }
        } ?? admitted
        let ranked = context.holdingTensorParallelToItsMargin(
            context.ordered(qualified.filter(\.possible), regime: policy.regime), regime: policy.regime)
        if let forced = policy.forcedMode, ranked.isEmpty {
            throw ClusterPlacementError("Developer setting: \(forced.words) forced, but no \(forced.words) placement of \(layout.runtimeModelID) "
                + (admitted.contains(where: \.possible)
                    ? "passes this model's qualification records on these chips"
                    : "fits these Macs' memory"))
        }
        let other: ClusterPlacementPolicy.Regime = policy.regime == .sustained ? .rested : .sustained
        let structural = context.ordered(try context.candidates(.structural).filter(\.possible), regime: policy.regime).first
        let anyBoundary = context.ordered(try context.candidates(.anyBoundary).filter(\.possible), regime: policy.regime).first
        let basis = ClusterPlacementBasis(source: devices.map(\.speed.source).max() ?? .assumedEqual,
            absolute: devices.allSatisfy(\.speed.absolute), linkCostsMeasured: link.measured)
        let alone = devices.map(context.alone)
        // A Mac that holds the whole model is a placement too: the model is
        // refused only when no division and no single Mac can hold it.
        var refusal: ClusterPlacementRefusal?
        // Memory refuses only when no admitted placement is possible at all;
        // a possible placement the qualification left out is reported as that.
        if !admitted.contains(where: \.possible), !alone.contains(where: \.fit.possible) {
            let extents = devices.map { (first: context.extent($0, first: true), last: context.extent($0, first: false)) }
            var uncovered: (layers: Int, bytes: Int)?
            if devices.count == 2 {
                for (a, b) in [(0, 1), (1, 0)] {
                    // `a` holds layers up to its limit, `b` from its own; what lies between has no home.
                    let from = extents[a].first, to = layout.layerCount - extents[b].last
                    let gap = to > from ? layout.layers[from..<to].reduce(0) { $0 + $1.weights.loadedBytes } : 0
                    if uncovered == nil || gap < uncovered!.bytes { uncovered = (max(0, to - from), gap) }
                }
            }
            refusal = .init(devices: zip(devices, extents).map { device, extent in
                ClusterPlacementRefusal.Device(device: device.label, physicalMemoryBytes: device.profile.physicalMemoryBytes,
                    admissibleNowBytes: device.profile.memory.admissibleNowBytes,
                    withApplicationsClosedBytes: device.profile.memory.withApplicationsClosedBytes,
                    mostLayersAsFirst: extent.first,
                    mostBytesAsFirst: extent.first > 0 ? layout.range(0..<extent.first).loadedBytes : 0,
                    mostLayersAsLast: extent.last,
                    mostBytesAsLast: extent.last > 0 ? layout.range((layout.layerCount - extent.last)..<layout.layerCount).loadedBytes : 0)
            }, closest: admitted.min { context.shortBytes($0) < context.shortBytes($1) },
                modelLoadedBytes: layout.wholeModelLoadedBytes, uncoveredLayers: uncovered?.layers, uncoveredBytes: uncovered?.bytes,
                fitsAtAStructuralCut: structural != nil, fitsAtSomeLayerBoundary: anyBoundary != nil)
        }
        var aloneAsFast: [String] = []
        if let chosen = ranked.first {
            let limit = chosen.routedSeconds(policy.regime) * (1 + policy.tieTolerance)
            aloneAsFast = alone.filter { $0.fit.tier <= chosen.tier && $0.prediction(policy.regime).requestSeconds <= limit }.map(\.device)
        }
        var result = ClusterPlacementResult(runtimeModelID: layout.runtimeModelID, promptTokens: prompt, outputTokens: outputs,
            regime: policy.regime, basis: basis, chosen: ranked.first,
            alternatives: Array(ranked.dropFirst().prefix(policy.alternatives)),
            chosenForOtherRegime: context.ordered(qualified.filter(\.possible), regime: other).first,
            bestStructural: structural, bestAnyBoundary: anyBoundary,
            alone: alone, aloneAsFast: aloneAsFast, refusal: refusal,
            routedAlone: ranked.first.flatMap { $0.routesAlone(policy.regime) ? $0.aloneRoute?.device : nil },
            candidatesConsidered: admitted.count,
            unqualifiedPossible: policy.admitsShape == nil ? nil
                : admitted.filter(\.possible).count - qualified.filter(\.possible).count)
        if layout.tensorParallel != nil {
            result.tensorParallel = try assessTensorParallel(devices: devices, layout: layout, policy: policy, link: link,
                prompt: prompt, outputs: outputs, schedules: schedules, ranked: ranked, alone: alone)
        }
        if !policy.handOffModes {
            result.shards = try assessShards(context: context, admitted: admitted, qualified: qualified, ranked: ranked,
                tensorParallel: result.tensorParallel)
        }
        return result
    }

    /// The tensor-parallel modes evaluated whether or not the runtime lists
    /// them, against what was chosen: the planner's answer to "would tensor
    /// parallel be faster here, and if so what stops it".
    static func assessTensorParallel(devices: [ClusterPlacementDevice], layout: ClusterModelLayout,
                                     policy: ClusterPlacementPolicy, link: ClusterLinkCosts, prompt: Int, outputs: Int,
                                     schedules: [ClusterPrefillSchedule], ranked: [ClusterPlacementCandidate],
                                     alone: [ClusterPlacementAlone]) throws -> ClusterTensorParallelAssessment? {
        guard let tp = layout.tensorParallel else { return nil }
        let regime = policy.regime
        let steps = tp.reductionsPerStep(layerCount: layout.layerCount)
        let speeds = devices.map { device in
            ClusterTensorParallelAssessment.Device(device: device.label,
                split: ClusterDecodeSplit(rates: device.speed.sustained.flatMap { regime == .sustained ? $0 : nil } ?? device.speed.rested,
                    hardwareWeightSeconds: device.speed.absolute ? ClusterHardwarePrior.weightSeconds(profile: device.profile, layout: layout) : nil,
                    hardwareDividedFraction: ClusterHardwarePrior.dividedDecodeFraction(layout)))
        }
        let bestOther = ranked.first { !$0.mode.usesTensorParallelDecode }?.prediction(regime).requestSeconds
        let bestAlone = alone.filter(\.fit.possible).map { $0.prediction(regime).requestSeconds }.min()
        func unavailable(_ verdict: ClusterTensorParallelAssessment.Verdict, _ reason: String) -> ClusterTensorParallelAssessment {
            .init(verdict: verdict, reason: reason, tensorParallel: nil, hybrid: nil,
                bestOtherSeconds: bestOther, bestAloneSeconds: bestAlone, devices: speeds,
                reductionsPerStep: steps, reductionSecondsPerStep: nil, reductionKeyed: link.reduction?.keyed)
        }
        // Capability and geometry are metadata checks: an unavailable runtime
        // must not ask for a link measurement or predict a hypothetical speedup.
        let implemented = layout.generationModes.filter {
            $0.usesTensorParallelDecode && (policy.handOffModes || !$0.isHandOff)
        }
        guard !implemented.isEmpty else {
            return unavailable(.notExecutedByRuntime, "this runtime does not execute tensor parallel for this model; using pipeline candidates")
        }
        let modes = implemented.filter { mode in
            (policy.modes?.contains(mode) ?? true) && (policy.forcedMode?.admits(mode) ?? true)
        }
        guard !modes.isEmpty else {
            return unavailable(.notQualified, "the placement policy excludes the model's tensor-parallel modes; using pipeline candidates")
        }
        let most = min(policy.maximumRanges, devices.count)
        guard tp.family.ranks.contains(where: { $0 <= most }) else {
            return unavailable(.notExecutedByRuntime, "this model's tensor-parallel plan supports rank counts "
                + "\(tp.family.ranks.map(String.init).joined(separator: ", ")), but this placement allows at most \(most) members; using pipeline candidates")
        }
        guard let reduction = link.reduction else {
            return unavailable(.reductionNotMeasured,
                "the model and rank count support tensor parallel, but no reduction over the keyed link has been measured; using pipeline candidates")
        }
        // The hybrid hands the request state off, so it is assessed only under the hand-off opt-in.
        let context = Context(devices: devices, layout: layout, prompt: prompt, outputs: outputs,
            modes: modes,
            schedules: schedules, link: link, policy: policy, tensorParallelForAssessment: true)
        let possible = try context.candidates(.admitted).filter(\.possible)
        let best = context.ordered(possible.filter { $0.mode == .tensorParallel }, regime: regime).first
        let hybrid = context.ordered(possible.filter { $0.mode == .pipelinePrefillTensorDecode }, regime: regime).first
        let perStep = Double(steps) * reduction.seconds(bytes: tp.family.partialBytesPerToken)
        func make(_ verdict: ClusterTensorParallelAssessment.Verdict, _ reason: String) -> ClusterTensorParallelAssessment {
            .init(verdict: verdict, reason: reason, tensorParallel: best, hybrid: hybrid, bestOtherSeconds: bestOther,
                  bestAloneSeconds: bestAlone, devices: speeds, reductionsPerStep: steps, reductionSecondsPerStep: perStep,
                  reductionKeyed: reduction.keyed)
        }
        if let chosen = ranked.first, chosen.mode.usesTensorParallelDecode {
            return make(.chosen, "predicted faster than every other mode by at least the margin")
        }
        guard let fastest = [best, hybrid].compactMap({ $0 }).min(by: {
            $0.prediction(regime).requestSeconds < $1.prediction(regime).requestSeconds }) else {
            return make(.doesNotFit, "no tensor-parallel placement fits these Macs")
        }
        let time = fastest.prediction(regime).requestSeconds
        let unmeasured = speeds.filter { !$0.split.measured && $0.split.fromHardware == nil }.map(\.device)
        let prior = speeds.filter { $0.split.fromHardware == true }.map(\.device)
        let note = (unmeasured.isEmpty ? "" : "; no shard probe on \(unmeasured.joined(separator: ", ")), so its step is assumed not to shrink")
            + (prior.isEmpty ? "" : "; no shard probe on \(prior.joined(separator: ", ")), so its share's step is predicted from its measured device index")
        if let bestOther, time >= bestOther * (1 - policy.tensorParallelMargin) {
            return make(.predictedSlower, String(format: "predicted %.2f s against %.2f s for the chosen placement", time, bestOther) + note)
        }
        guard reduction.keyed else {
            return make(.reductionNotMeasured, String(format: "predicted %.2f s, but the reduction was measured as a native all-sum; "
                + "the product reduces over the keyed data plane, and only that measurement can choose the mode", time) + note)
        }
        return make(.notQualified, String(format: "predicted %.2f s, but the policy admits no %@ shape on these Macs (a cross-cable check diverged at each)",
            time, fastest.mode.rawValue) + note)
    }

    /// One explicit placement, evaluated as the planner evaluates its own
    /// candidates: `devices` in rank order, `cuts` ascending. Nothing is
    /// checked against the layout's cut lists, so a caller can ask about any
    /// layer boundary.
    public static func evaluate(devices: [ClusterPlacementDevice], cuts: [Int], mode: ClusterGenerationMode,
                                prefillSchedule: ClusterPrefillSchedule, layout: ClusterModelLayout,
                                policy: ClusterPlacementPolicy = .init(),
                                link: ClusterLinkCosts = .unmeasured, tensorShares: [Int]? = nil) throws -> ClusterPlacementCandidate {
        try layout.validate()
        guard cuts.count == mode.layerCutCount(ranks: devices.count), devices.count >= 2 || cuts.isEmpty,
              cuts == Array(Set(cuts)).sorted(), cuts.allSatisfy({ (1..<layout.layerCount).contains($0) }) else {
            throw ClusterPlacementError("A placement is one device per range and ascending cuts inside the model")
        }
        if mode.usesTensorParallelDecode {
            guard let tp = layout.tensorParallel, tp.family.ranks.contains(devices.count), link.reduction != nil else {
                throw ClusterPlacementError("A tensor-parallel placement needs the layout's tensor-parallel facts for this many ranks and a measured reduction")
            }
        }
        let context = Context(devices: devices, layout: layout, prompt: policy.promptTokens ?? layout.maximumPromptTokens,
            outputs: policy.outputTokens ?? layout.maximumOutputTokens, modes: [mode], schedules: [prefillSchedule],
            link: link, policy: policy, tensorParallelForAssessment: true)
        if let tensorShares {
            guard mode == .tensorParallel, tensorShares.count == devices.count,
                  Set(tensorShares).count == 1 || (layout.tensorParallel?.family.shareOptions ?? []).contains(tensorShares) else {
                throw ClusterPlacementError("Tensor-parallel shares must be one the family's plan accepts, one weight per rank")
            }
        }
        return context.evaluate(order: Array(devices.indices), cuts: cuts, mode: mode, schedule: prefillSchedule, weights: tensorShares)
    }

    /// One Mac running the whole model by itself for the policy's request,
    /// as the planner predicts it: serial prefill of every layer on that Mac,
    /// then decode with the model's head when `speculativeHead` is true and
    /// the Mac is credited one (`ClusterSpeculativeCredit`), plain otherwise.
    /// No link is crossed. The route a phase split's decoding rank takes when
    /// it serves a request alone (`ClusterRequestRouter`).
    public static func evaluateAlone(device: ClusterPlacementDevice, layout: ClusterModelLayout,
                                     speculativeHead: Bool, policy: ClusterPlacementPolicy = .init())
        -> ClusterPlacementPrediction {
        let context = Context(devices: [device], layout: layout, prompt: policy.promptTokens ?? layout.maximumPromptTokens,
            outputs: policy.outputTokens ?? layout.maximumOutputTokens, modes: [.pipeline], schedules: [.serial],
            link: .unmeasured, policy: policy)
        let mode: ClusterGenerationMode = speculativeHead && layout.generationModes.contains(.phaseSplitMTP) ? .phaseSplitMTP : .pipeline
        return context.prediction(policy.regime, order: [device], ranges: [layout.range(0..<layout.layerCount)],
            mode: mode, schedule: .serial)
    }

    struct Context {
        let devices: [ClusterPlacementDevice]
        let layout: ClusterModelLayout
        let prompt: Int, outputs: Int
        let modes: [ClusterGenerationMode], schedules: [ClusterPrefillSchedule]
        let link: ClusterLinkCosts
        let policy: ClusterPlacementPolicy
        /// True for the assessment and an explicit evaluation: a tensor-parallel
        /// mode is evaluated on any measured reduction. For choosing, the
        /// reduction must have been measured on the keyed data plane.
        var tensorParallelForAssessment = false

        // Performance still uses prompt/outputs; LOAD admission uses the
        // adapter's reservation scope even after short served requests.
        var memoryPrompt: Int { layout.reservesFullRequestScope == true ? layout.maximumPromptTokens : prompt }
        var memoryContext: Int { layout.reservesFullRequestScope == true ? layout.maximumContextTokens : prompt + outputs }


        /// Whether a mode can be placed on `ranges` ranks here at all.
        func placeable(_ mode: ClusterGenerationMode, ranges: Int) -> Bool {
            guard mode.usesTensorParallelDecode else { return true }
            guard let tp = layout.tensorParallel, tp.family.ranks.contains(ranges), let reduction = link.reduction else { return false }
            return reduction.keyed || tensorParallelForAssessment
        }

        func cuts(_ scope: CutScope) -> [Int] {
            switch scope {
            case .admitted: layout.admittedCuts
            case .structural: layout.structuralCuts
            case .anyBoundary: Array(1..<layout.layerCount)
            }
        }

        /// Every ordered choice of `count` devices, led by the policy's leader when it names one.
        func orders(_ count: Int) -> [[Int]] {
            func extend(_ prefix: [Int]) -> [[Int]] {
                if prefix.count == count { return [prefix] }
                return devices.indices.filter { !prefix.contains($0) }.flatMap { extend(prefix + [$0]) }
            }
            guard let leader = policy.leader else { return extend([]) }
            return extend([]).filter { devices[$0[0]].label == leader }
        }

        /// Every ascending choice of `count` cuts.
        func cutSets(_ available: [Int], _ count: Int) -> [[Int]] {
            func extend(_ prefix: [Int], from start: Int) -> [[Int]] {
                if prefix.count == count { return [prefix] }
                guard start < available.count else { return [] }
                return (start..<available.count).flatMap { extend(prefix + [available[$0]], from: $0 + 1) }
            }
            return extend([], from: 0)
        }

        func candidates(_ scope: CutScope) throws -> [ClusterPlacementCandidate] {
            let available = cuts(scope)
            var result: [ClusterPlacementCandidate] = []
            let most = min(policy.maximumRanges, devices.count)
            guard most >= 2 else { return [] }
            // A lookahead prefill is never slower than a serial one of the same placement.
            let schedule = schedules.contains(.oneChunkLookahead) ? ClusterPrefillSchedule.oneChunkLookahead : schedules[0]
            for ranges in 2...most {
                let tensor = scope == .admitted && modes.contains(.tensorParallel) && placeable(.tensorParallel, ranges: ranges)
                let layerModes = modes.filter { !($0.usesTensorParallelPrefill) && placeable($0, ranges: ranges) }
                let pipeline = !layerModes.isEmpty && available.count >= ranges - 1
                guard tensor || pipeline else { continue }
                let sets = pipeline ? cutSets(available, ranges - 1) : []
                let permutations = orders(ranges)
                let shares = tensor ? (layout.tensorParallel?.family.shareOptions ?? []).filter {
                    $0.count == ranges && Set($0).count > 1
                } : []
                let perOrder = sets.count * layerModes.count + (tensor ? 1 + shares.count : 0)
                guard perOrder * permutations.count + result.count <= policy.maximumCandidates else {
                    throw ClusterPlacementError("Placing \(ranges) ranges over \(available.count) cuts on \(devices.count) devices "
                        + "is more than \(policy.maximumCandidates) candidates; a bottleneck partition is needed instead of enumeration")
                }
                for order in permutations {
                    // TP has no layer cuts. Enumerate it independently, including
                    // when this model has no admitted or structural pipeline cut.
                    if tensor {
                        result.append(bestTensorShares(order: order, schedule: schedule))
                        for weights in shares {
                            result.append(evaluate(order: order, cuts: [], mode: .tensorParallel, schedule: schedule, weights: weights))
                        }
                    }
                    for set in sets {
                        for mode in layerModes {
                            result.append(evaluate(order: order, cuts: set, mode: mode, schedule: schedule))
                        }
                    }
                }
            }
            return result
        }

        func rates(_ device: ClusterPlacementDevice, _ regime: ClusterPlacementPolicy.Regime) -> (ClusterSpeedRates, Bool) {
            switch regime {
            case .rested: return (device.speed.rested, true)
            case .sustained: return (device.speed.sustained ?? device.speed.rested, device.speed.sustained != nil)
            }
        }

        /// One rank's need, by the load gate's and the request gate's own asks
        /// with the constants that device's gate reported.
        func requirement(rank: Int, of count: Int, device: ClusterPlacementDevice, own: ClusterModelLayout.Range,
                  earlier: [ClusterModelLayout.Range], mode: ClusterGenerationMode,
                  schedule: ClusterPrefillSchedule) -> ClusterPlacementRank {
            let memory = device.profile.memory, last = rank == count - 1
            // Under a phase split the last rank also loads every earlier range,
            // after its own, so that it can decode alone.
            let loads = [own] + (mode.isPhaseSplit && last ? earlier : [])
            var held = 0, loadNeed = 0, largest = 0
            for part in loads {
                let rounded = part.loadedBytes + part.tensorCount * memory.pageSizeBytes
                let ask = max(memory.minimumAdmissibleBytes,
                    rounded + 2 * part.largestTensorBytes + memory.loadScratchBytes + memory.loadingHeadroomBytes)
                loadNeed = max(loadNeed, held + ask)
                held += rounded; largest = max(largest, part.largestTensorBytes)
            }
            // The decoding rank of a speculative mode also holds the model's
            // head (and under a pipeline the embedding copy it drafts with),
            // loaded after its stages (each tensor in whole pages).
            if last {
                let holding = layout.speculativeHolding(mode: mode, pageSizeBytes: memory.pageSizeBytes)
                held += holding.bytes
                largest = max(largest, holding.largestTensorBytes)
            }
            let context = memoryContext
            let ownState = loads.reduce(0) { $0 + $1.stateBytes(tokens: context) }
            // One prefill frame's attention transient at the full context, on
            // the rank's largest layer: layers run one after another.
            let transient = loads.map { $0.transientBytes(chunk: min(layout.maximumChunkTokens, memoryPrompt), context: context) }.max() ?? 0
            // A requested context beyond the layout's planned request brings its own
            // charge (`policy.requestChargeEveryRankBytes`); otherwise the layout's at this context.
            let state = max(policy.requestChargeEveryRankBytes ?? layout.requestChargeEveryRankBytes(context: context), ownState)
            let work = loads.reduce(0) { $0 + $1.requestWorkBytes }
            var extra = 0
            // A producer keeps the next chunk's residual beside the current one.
            if schedule == .oneChunkLookahead, !last, memoryPrompt > layout.maximumChunkTokens {
                extra += 2 * layout.maximumChunkTokens * layout.boundaryBytesPerToken
            }
            // The state that changes owner exists on both sides while it moves.
            if mode.isPhaseSplit {
                let moving = last ? earlier.reduce(0) { $0 + $1.stateBytes(tokens: memoryPrompt) } : own.stateBytes(tokens: memoryPrompt)
                extra += 2 * moving
            }
            let requestNeed = max(memory.minimumAdmissibleBytes, state + work + extra + transient + (layout.allowanceEveryRankBytes ?? 0) + memory.loadingHeadroomBytes)
            let need = max(loadNeed, held + requestNeed)
            return .init(rank: rank, device: device.label, firstLayer: own.layers.lowerBound, endLayer: own.layers.upperBound,
                weightsBytes: held, loadNeedBytes: loadNeed, requestNeedBytes: requestNeed, needBytes: need,
                admissibleNowBytes: memory.admissibleNowBytes,
                fit: device.profile.fit(needBytes: need, weightsBytes: held, largestTensorBytes: largest),
                withinGPUWorkingSet: held + state + work + extra + transient <= device.profile.residentCapacityBytes,
                transientBytes: transient,
                hardwareFits: device.profile.hardwareFits(needBytes: need, weightsBytes: held, largestTensorBytes: largest))
        }

        /// The load gate's largest ask while loading `parts` in turn (each
        /// tensor in whole pages), and what is then held.
        func loadNeed(_ parts: [(loaded: Int, tensors: Int, largest: Int)], memory: ClusterDeviceMemory) -> (need: Int, held: Int, largest: Int) {
            var held = 0, need = 0, largest = 0
            for part in parts where part.loaded > 0 {
                let rounded = part.loaded + part.tensors * memory.pageSizeBytes
                let ask = max(memory.minimumAdmissibleBytes,
                    rounded + 2 * part.largest + memory.loadScratchBytes + memory.loadingHeadroomBytes)
                need = max(need, held + ask)
                held += rounded; largest = max(largest, part.largest)
            }
            return (need, held, largest)
        }

        /// The tensor-parallel candidate of this order at its best shares: equal,
        /// or, when the family's plan hands out `shareUnits` groups and two ranks
        /// run it, every split in whole groups, the best by the planner's own order.
        func bestTensorShares(order: [Int], schedule: ClusterPrefillSchedule) -> ClusterPlacementCandidate {
            let equal = evaluate(order: order, cuts: [], mode: .tensorParallel, schedule: schedule)
            guard order.count == 2, let units = layout.tensorParallel?.family.shareUnits else { return equal }
            let splits = (1..<units).map { k -> ClusterPlacementCandidate in
                let first = Double(k) / Double(units)
                return evaluate(order: order, cuts: [], mode: .tensorParallel, schedule: schedule, shares: [first, 1 - first])
            }
            return ordered(splits, regime: policy.regime).first ?? equal
        }

        /// One rank of a tensor-parallel mode. `tensorParallel`: the share of
        /// every layer, the ingress and the egress (`ClusterTensorParallelLayout`).
        /// `pipelinePrefillTensorDecode`: its own pipeline range whole, then
        /// the share of every other layer and of the ingress or egress it
        /// lacks, for the decode after the hand-off. Request state: the share
        /// of its heads (its own range whole too for the hybrid), never less
        /// than the family's every-rank charge.
        func tensorRequirement(rank: Int, of count: Int, device: ClusterPlacementDevice, own: ClusterModelLayout.Range,
                               mode: ClusterGenerationMode, schedule: ClusterPrefillSchedule,
                               fraction: Double? = nil) -> ClusterPlacementRank {
            let tp = layout.tensorParallel!, memory = device.profile.memory, count = max(1, count)
            func shareOf(divided: Int, replicated: Int) -> Int {
                fraction.map { tp.shareBytes(divided: divided, replicated: replicated, fraction: $0) }
                    ?? tp.shareBytes(divided: divided, replicated: replicated, ranks: count)
            }
            let whole = layout.range(0..<layout.layerCount)
            let pipelined = !mode.usesTensorParallelPrefill
            var shard = 0, tensors = 0, largest = 0
            for (index, layer) in layout.layers.enumerated() where !(pipelined && own.layers.contains(index)) {
                shard += shareOf(divided: tp.layerDividedBytes[index], replicated: tp.layerReplicatedBytes[index])
                tensors += layer.weights.tensorCount; largest = max(largest, layer.weights.largestTensorBytes)
            }
            if !(pipelined && own.layers.lowerBound == 0) {
                shard += shareOf(divided: tp.ingressDividedBytes, replicated: tp.ingressReplicatedBytes)
                tensors += layout.ingress.tensorCount; largest = max(largest, layout.ingress.largestTensorBytes)
            }
            if !(pipelined && own.layers.upperBound == layout.layerCount) {
                shard += shareOf(divided: tp.egressDividedBytes, replicated: tp.egressReplicatedBytes)
                tensors += layout.egress.tensorCount; largest = max(largest, layout.egress.largestTensorBytes)
            }
            let parts = (pipelined ? [(own.loadedBytes, own.tensorCount, own.largestTensorBytes)] : []) + [(shard, tensors, largest)]
            let load = loadNeed(parts.map { (loaded: $0.0, tensors: $0.1, largest: $0.2) }, memory: memory)
            let divides = tp.family.stateDividesByHeads
            func share(_ bytes: Int) -> Int {
                guard divides else { return bytes }
                return fraction.map { Int((Double(bytes) * min(1, $0 * 1.01)).rounded(.up)) } ?? (bytes + count - 1) / count
            }
            let context = memoryContext, chunk = min(layout.maximumChunkTokens, memoryPrompt)
            let ownState = pipelined
                ? own.stateBytes(tokens: context) + share(whole.stateBytes(tokens: context) - own.stateBytes(tokens: context))
                : share(whole.stateBytes(tokens: context))
            let transient = pipelined
                ? max(own.transientBytes(chunk: chunk, context: context), share(whole.transientBytes(chunk: chunk, context: context)))
                : share(whole.transientBytes(chunk: chunk, context: context))
            let state = max(policy.requestChargeEveryRankBytes ?? layout.requestChargeEveryRankBytes(context: context), ownState)
            let work = pipelined ? own.requestWorkBytes + share(whole.requestWorkBytes - own.requestWorkBytes) : share(whole.requestWorkBytes)
            var extra = 0
            if pipelined {
                // The share it sends exists until it has gone.
                extra += share(own.stateBytes(tokens: memoryPrompt))
                if schedule == .oneChunkLookahead, rank != count - 1, memoryPrompt > layout.maximumChunkTokens {
                    extra += 2 * layout.maximumChunkTokens * layout.boundaryBytesPerToken
                }
            }
            let requestNeed = max(memory.minimumAdmissibleBytes, state + work + extra + transient + (layout.allowanceEveryRankBytes ?? 0) + memory.loadingHeadroomBytes)
            let need = max(load.need, load.held + requestNeed)
            return .init(rank: rank, device: device.label,
                firstLayer: pipelined ? own.layers.lowerBound : 0, endLayer: pipelined ? own.layers.upperBound : layout.layerCount,
                weightsBytes: load.held, loadNeedBytes: load.need, requestNeedBytes: requestNeed, needBytes: need,
                admissibleNowBytes: memory.admissibleNowBytes,
                fit: device.profile.fit(needBytes: need, weightsBytes: load.held, largestTensorBytes: load.largest),
                withinGPUWorkingSet: load.held + state + work + extra + transient <= device.profile.residentCapacityBytes,
                transientBytes: transient,
                hardwareFits: device.profile.hardwareFits(needBytes: need, weightsBytes: load.held,
                    largestTensorBytes: load.largest))
        }

        /// `policy.tensorParallelMargin`: a tensor-parallel candidate stays
        /// ahead of the best candidate of another mode in its group only when
        /// it is predicted at least the margin faster; otherwise it goes
        /// right after that candidate.
        func holdingTensorParallelToItsMargin(_ ordered: [ClusterPlacementCandidate],
                                              regime: ClusterPlacementPolicy.Regime) -> [ClusterPlacementCandidate] {
            func group(_ c: ClusterPlacementCandidate) -> Int { hardwareGroup(c) }
            guard let otherIndex = ordered.firstIndex(where: { !$0.mode.usesTensorParallelDecode }) else { return ordered }
            let other = ordered[otherIndex]
            let limit = other.prediction(regime).requestSeconds * (1 - policy.tensorParallelMargin)
            var held: [ClusterPlacementCandidate] = [], kept: [ClusterPlacementCandidate] = []
            for candidate in ordered[..<otherIndex] {
                if candidate.mode.usesTensorParallelDecode, group(candidate) == group(other),
                   candidate.prediction(regime).requestSeconds > limit {
                    held.append(candidate)
                } else {
                    kept.append(candidate)
                }
            }
            return kept + [other] + held + ordered[(otherIndex + 1)...]
        }

        func prediction(_ regime: ClusterPlacementPolicy.Regime, order: [ClusterPlacementDevice],
                        ranges: [ClusterModelLayout.Range], mode: ClusterGenerationMode,
                        schedule: ClusterPrefillSchedule, shares: [Double]? = nil) -> ClusterPlacementPrediction {
            // Each rank's share of a tensor-parallel layer (equal unless weighted).
            let share = shares ?? Array(repeating: 1 / Double(max(1, order.count)), count: order.count)
            let total = layout.layers.reduce(0.0) { $0 + $1.cost }
            var measured = true, prefill: [Double] = [], decode: [Double] = []
            for (device, range) in zip(order, ranges) {
                let (rate, known) = rates(device, regime)
                measured = measured && known
                prefill.append(range.cost / total / rate.prefillTokensPerSecond)
                decode.append(range.cost / total / rate.decodeTokensPerSecond)
            }
            let chunk = min(layout.maximumChunkTokens, prompt)
            let chunks = (prompt + chunk - 1) / chunk
            let sum = prefill.reduce(0, +), slowest = prefill.max() ?? 0
            let tp = mode.usesTensorParallelDecode ? layout.tensorParallel : nil
            let reduction = tp == nil ? nil : link.reduction
            var first: Double
            if mode.usesTensorParallelPrefill, let tp, let reduction {
                // Every rank runs every chunk on its share of every layer; the
                // slowest share sets the pace, and each layer's partials are
                // summed once per chunk (a whole chunk's rows at a time).
                // A shard probe measures an equal share (1 / ranks); a rank holding
                // `share` takes that probe's time scaled by share * ranks. Without
                // a probe no gain is assumed (the whole model's rate).
                var perToken = 0.0
                for (index, device) in order.enumerated() {
                    let rate = rates(device, regime).0
                    // A measured probe at this share wins over scaling the half's.
                    let probed = rate.shareRate(near: share[index])?.prefillTokensPerSecond.map { 1 / $0 }
                    // Without a probe, a Mac whose split comes from its hardware computes its share of
                    // every layer (prefill is compute-bound); otherwise no gain is assumed.
                    let prior = split(device, regime).fromHardware == true ? share[index] / rate.prefillTokensPerSecond : nil
                    perToken = max(perToken, probed ?? rate.tensorShardPrefillTokensPerSecond.map { share[index] * Double(order.count) / $0 }
                        ?? prior ?? 1 / rate.prefillTokensPerSecond)
                }
                first = Double(prompt) * perToken
                    + Double(chunks * tp.family.reductionsPerLayer * layout.layerCount)
                        * reduction.seconds(bytes: chunk * tp.family.partialBytesPerToken)
                    + Double(tp.family.reductionsPerStep) * reduction.seconds(bytes: 16)
            } else {
                // Serial: each chunk passes through every range in turn. Lookahead:
                // the slowest range sets the pace and one chunk passes through the rest.
                first = schedule == .oneChunkLookahead
                    ? Double(prompt) * slowest + Double(chunk) * (sum - slowest)
                    : Double(prompt) * sum
                first += Double(chunks * (ranges.count - 1)) * link.perChunkSeconds
            }
            var step: Double, handoff = 0.0
            if let tp, let reduction {
                // Each rank steps its share (`ClusterDecodeSplit`: the floor
                // whole, the weights divided); the slower share sets the pace,
                // and every reduction of the step crosses the link.
                var slowest = 0.0
                for (index, device) in order.enumerated() {
                    slowest = max(slowest, split(device, regime).shareStepSeconds(fraction: share[index]))
                }
                step = slowest + Double(tp.reductionsPerStep(layerCount: layout.layerCount))
                    * reduction.seconds(bytes: tp.family.partialBytesPerToken)
                if !mode.usesTensorParallelPrefill {
                    // After a pipeline prefill each rank sends the state of the
                    // heads it does not keep: (k - 1) / k of its range's.
                    let moving = Double(ranges.reduce(0) { $0 + $1.stateBytes(tokens: prompt) }) * Double(order.count - 1) / Double(order.count)
                    handoff = link.handoffSecondsPerByte * moving
                }
            } else if mode.isPhaseSplit, let lastDevice = order.last {
                // After the hand-off the last rank decodes alone, with the
                // model's head when the mode runs it (`ClusterSpeculativeCredit`).
                step = 1 / decodeRate(lastDevice, regime, speculative: mode.usesSpeculativeHead)
                handoff = link.handoffSecondsPerByte
                    * Double(ranges.dropLast().reduce(0) { $0 + $1.stateBytes(tokens: prompt) })
            } else {
                step = decode.reduce(0, +)
            }
            // One Mac alone crosses no link.
            if ranges.count > 1 { step += link.perDecodeStepSeconds[mode.rawValue] ?? 0 }
            // A pipeline's speculative rounds: the measured speed-up on the
            // decoding rank, nothing without one (`ClusterSpeculativeCredit.pipelineFactor`).
            if mode.usesSpeculativeHead, !mode.isPhaseSplit, let lastDevice = order.last,
               let factor = ClusterSpeculativeCredit.pipelineFactor(rates(lastDevice, regime).0,
                   recorded: policy.recordedPipelineSpeculativeFactor) {
                step /= factor
            }
            return .init(regime: regime, regimeMeasuredOnEveryDevice: measured, firstTokenSeconds: first,
                prefillTokensPerSecond: Double(prompt) / first, decodeTokensPerSecond: 1 / step,
                requestSeconds: first + handoff + Double(max(0, outputs - 1)) * step)
        }

        /// One device's decode split in this regime: its shard probes, else its
        /// measured hardware (`ClusterHardwarePrior`, only on absolute rates),
        /// else no gain.
        func split(_ device: ClusterPlacementDevice, _ regime: ClusterPlacementPolicy.Regime) -> ClusterDecodeSplit {
            ClusterDecodeSplit(rates: rates(device, regime).0, hardwareWeightSeconds: device.speed.absolute
                ? ClusterHardwarePrior.weightSeconds(profile: device.profile, layout: layout) : nil,
                hardwareDividedFraction: ClusterHardwarePrior.dividedDecodeFraction(layout))
        }

        /// A device's whole-model decode rate in this regime: plain, or with
        /// the model's head at the rate `ClusterSpeculativeCredit` gives it
        /// (the plain rate where nothing credits the head there).
        func decodeRate(_ device: ClusterPlacementDevice, _ regime: ClusterPlacementPolicy.Regime, speculative: Bool) -> Double {
            let plain = rates(device, regime).0
            guard speculative, let value = ClusterSpeculativeCredit.rate(plain, device: device, layout: layout) else {
                return plain.decodeTokensPerSecond
            }
            return value.tokensPerSecond
        }

        /// 0 for a mode that runs the model's head on a decoding Mac that
        /// prefers it, 1 for a mode without the head, 2 for the head on a Mac
        /// that prefers plain decode (`ClusterSpeculativeCredit.prefersHead`).
        func headRank(_ c: ClusterPlacementCandidate, _ regime: ClusterPlacementPolicy.Regime) -> Int {
            guard c.mode.usesSpeculativeHead else { return 1 }
            guard let decoder = devices.first(where: { $0.label == c.ranks.last?.device }) else { return 2 }
            if !c.mode.isPhaseSplit {
                return (ClusterSpeculativeCredit.pipelineFactor(rates(decoder, regime).0,
                    recorded: policy.recordedPipelineSpeculativeFactor) ?? 0) > 1 ? 0 : 2
            }
            return ClusterSpeculativeCredit.prefersHead(rates(decoder, regime).0, device: decoder, layout: layout) ? 0 : 2
        }

        func evaluate(order: [Int], cuts: [Int], mode: ClusterGenerationMode,
                      schedule: ClusterPrefillSchedule, shares: [Double]? = nil, weights: [Int]? = nil) -> ClusterPlacementCandidate {
            // Integer weights (the family's share options, bound in the launch
            // terms) or fractions (whole `shareUnits` groups); nil: equal.
            let weighted = mode == .tensorParallel ? weights.flatMap { Set($0).count > 1 && $0.count == order.count ? $0 : nil } : nil
            let unequal = mode == .tensorParallel ? shares.flatMap { $0.count == order.count && Set($0).count > 1 ? $0 : nil } : nil
            let fractions: [Double]? = weighted.map { w in w.map { Double($0) / Double(w.reduce(0, +)) } } ?? unequal
            let bounds = [0] + cuts + [layout.layerCount]
            // Under tensor parallel every rank runs every layer (on its share).
            let ranges = mode.usesTensorParallelPrefill
                ? order.map { _ in layout.range(0..<layout.layerCount) }
                : (0..<order.count).map { layout.range(bounds[$0]..<bounds[$0 + 1]) }
            let chosen = order.map { devices[$0] }
            let ranks = ranges.indices.map { index in
                mode.usesTensorParallelDecode && layout.tensorParallel != nil
                    ? tensorRequirement(rank: index, of: ranges.count, device: chosen[index], own: ranges[index],
                        mode: mode, schedule: schedule, fraction: fractions?[index])
                    : requirement(rank: index, of: ranges.count, device: chosen[index], own: ranges[index],
                        earlier: Array(ranges[..<index]), mode: mode, schedule: schedule)
            }
            let headroom = ranks.map { Double($0.admissibleNowBytes - $0.needBytes) / Double(max(1, $0.needBytes)) }.min() ?? 0
            // Under a phase split the last rank holds every layer, so it can
            // serve a request alone, as the router lets it (`ClusterRequestRouter`).
            var route: ClusterPlacementAloneRoute?
            if mode.isPhaseSplit, let decoder = chosen.last {
                let whole = layout.range(0..<layout.layerCount)
                let aloneMode: ClusterGenerationMode = mode.usesSpeculativeHead ? .phaseSplitMTP : .pipeline
                route = .init(device: decoder.label,
                    sustained: prediction(.sustained, order: [decoder], ranges: [whole], mode: aloneMode, schedule: .serial),
                    rested: prediction(.rested, order: [decoder], ranges: [whole], mode: aloneMode, schedule: .serial))
            }
            return .init(cuts: cuts, mode: mode, prefillSchedule: schedule, ranks: ranks,
                sustained: prediction(.sustained, order: chosen, ranges: ranges, mode: mode, schedule: schedule, shares: fractions),
                rested: prediction(.rested, order: chosen, ranges: ranges, mode: mode, schedule: schedule, shares: fractions),
                tier: ranks.map(\.fit.tier).max() ?? 4, withinGPUWorkingSet: ranks.allSatisfy(\.withinGPUWorkingSet),
                smallestHeadroomShare: headroom, tensorShares: weighted, shares: fractions, aloneRoute: route)
        }

        /// How many layers a device could hold from the start of the model
        /// (`first`) or from its end, whatever is freed on it; 0 for none. A
        /// range's need only grows with its length, so the first failure ends it.
        func extent(_ device: ClusterPlacementDevice, first: Bool) -> Int {
            let schedule = schedules.contains(.oneChunkLookahead) ? ClusterPrefillSchedule.oneChunkLookahead : schedules[0]
            var most = 0
            for count in 1..<layout.layerCount {
                let range = first ? layout.range(0..<count) : layout.range((layout.layerCount - count)..<layout.layerCount)
                let need = requirement(rank: first ? 0 : 1, of: 2, device: device, own: range, earlier: [],
                                       mode: .pipeline, schedule: schedule)
                guard need.fit.possible else { break }
                most = count
            }
            return most
        }

        func shortBytes(_ candidate: ClusterPlacementCandidate) -> Int {
            candidate.ranks.reduce(0) { total, rank in
                if case .never(let short) = rank.fit { return total + short }
                return total
            }
        }

        /// The hardware holds every range, then inside the GPU working set,
        /// then the load gate admits every rank now. Speed ranks within a
        /// group: a faster split that needs applications closed first is chosen
        /// only when no split starts on the Macs as they are, so the pair starts
        /// at the fastest split that loads instead of refusing (owner, 2026-10-19).
        func hardwareGroup(_ c: ClusterPlacementCandidate) -> Int {
            (c.possible ? 0 : 4) + (c.withinGPUWorkingSet ? 0 : 2) + (c.tier == 0 ? 0 : 1)
        }

        /// The share of its own hardware capacity (what it keeps resident for
        /// the GPU and admits at rest, never what is free now) the tightest
        /// rank keeps beyond its need. Larger is more even.
        func capacityBalance(_ c: ClusterPlacementCandidate) -> Double {
            c.ranks.map { rank -> Double in
                guard let profile = devices.first(where: { $0.label == rank.device })?.profile else { return -.infinity }
                let capacity = Double(max(1, min(profile.residentCapacityBytes, profile.atRestAdmissibleBytes)))
                return (capacity - Double(rank.needBytes)) / capacity
            }.min() ?? -.infinity
        }

        /// Best first: the hardware group; then predicted request time on the
        /// route the router would take (`routedSeconds`: a phase split's
        /// decoding member alone when it is faster). Equal times are broken
        /// first by the model's speculative head (`headRank`: on a decoding
        /// Mac that prefers it, then no head, then the head on a Mac that
        /// prefers plain decode), then by the most even use of each Mac's
        /// hardware capacity (`capacityBalance`), then by the lower cut, the
        /// devices' labels in rank order and the mode's place in the layout.
        /// Times equal up to rounding are equal: on identical Macs every
        /// pipeline cut predicts the same time, and the earliest cut the
        /// second Mac's free memory held used to win that tie (5/40 of 45
        /// layers on two M5 Ultras, 2026-10-19). Nothing depends on the order
        /// the devices were given in, so the result is the same whichever Mac
        /// asks with the same samples.
        func ordered(_ candidates: [ClusterPlacementCandidate], regime: ClusterPlacementPolicy.Regime) -> [ClusterPlacementCandidate] {
            // The route the router would take for this request (`routedSeconds`).
            func time(_ c: ClusterPlacementCandidate) -> Double { c.routedSeconds(regime) }
            // Exactly equal (infinite times included), or apart by rounding only:
            // a real speed difference is never traded for balance.
            func sameTime(_ x: Double, _ y: Double) -> Bool { x == y || abs(x - y) <= 1e-9 * max(abs(x), abs(y)) }
            let byTime = candidates.sorted { a, b in
                if hardwareGroup(a) != hardwareGroup(b) { return hardwareGroup(a) < hardwareGroup(b) }
                return time(a) < time(b)
            }
            // Split each hardware group into runs of equal time, then order each run.
            // A run is measured from its fastest member, so near-equal times cannot
            // chain it across a real difference.
            var runs: [[ClusterPlacementCandidate]] = []
            for candidate in byTime {
                if let anchor = runs.last?.first, hardwareGroup(anchor) == hardwareGroup(candidate),
                   sameTime(time(anchor), time(candidate)) {
                    runs[runs.count - 1].append(candidate)
                } else {
                    runs.append([candidate])
                }
            }
            return runs.flatMap { run in
                run.sorted { a, b in
                    let ha = headRank(a, regime), hb = headRank(b, regime)
                    if ha != hb { return ha < hb }
                    let ba = capacityBalance(a), bb = capacityBalance(b)
                    if ba != bb { return ba > bb }
                    if a.cuts != b.cuts { return a.cuts.lexicographicallyPrecedes(b.cuts) }
                    let la = a.ranks.map(\.device), lb = b.ranks.map(\.device)
                    if la != lb { return la.lexicographicallyPrecedes(lb) }
                    return (modes.firstIndex(of: a.mode) ?? 0) < (modes.firstIndex(of: b.mode) ?? 0)
                }
            }
        }

        /// One Mac holding the whole model, with the model's head where that
        /// Mac prefers it, as the product runs it on one Mac. A phase
        /// split of one range is that Mac decoding alone: it holds the head
        /// and moves no state.
        func alone(_ device: ClusterPlacementDevice) -> ClusterPlacementAlone {
            let whole = layout.range(0..<layout.layerCount)
            let mode: ClusterGenerationMode = ClusterSpeculativeCredit.prefersHead(rates(device, policy.regime).0,
                device: device, layout: layout) ? .phaseSplitMTP : .pipeline
            let rank = requirement(rank: 0, of: 1, device: device, own: whole, earlier: [], mode: mode, schedule: .serial)
            return .init(device: device.label, needBytes: rank.needBytes, fit: rank.fit,
                withinGPUWorkingSet: rank.withinGPUWorkingSet,
                sustained: prediction(.sustained, order: [device], ranges: [whole], mode: mode, schedule: .serial),
                rested: prediction(.rested, order: [device], ranges: [whole], mode: mode, schedule: .serial))
        }
    }
}
