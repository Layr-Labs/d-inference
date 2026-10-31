import DarkbloomClusterProtocol
import Foundation

/// A model adapter's exact simultaneous peaks and current device bounds.
/// A quote is an observation, never an admission or calibrated capability.
public struct ClusterPlacementResourceQuote: Sendable {
    public let nativeBytes: Int, hostBytes: Int
    public let nativeAvailableBytes: Int, hostAvailableBytes: Int, combinedAvailableBytes: Int
    public init(nativeBytes: Int, hostBytes: Int, nativeAvailableBytes: Int,
                hostAvailableBytes: Int, combinedAvailableBytes: Int) {
        self.nativeBytes = nativeBytes; self.hostBytes = hostBytes
        self.nativeAvailableBytes = nativeAvailableBytes; self.hostAvailableBytes = hostAvailableBytes
        self.combinedAvailableBytes = combinedAvailableBytes
    }
    var fits: Bool {
        let sum = nativeBytes.addingReportingOverflow(hostBytes)
        return nativeBytes > 0 && hostBytes >= 0 && !sum.overflow
            && nativeBytes <= nativeAvailableBytes && hostBytes <= hostAvailableBytes
            && sum.partialValue <= combinedAvailableBytes
    }
}

public struct ClusterPlacementQuotedShape: Sendable {
    public let cuts: [Int]
    public let mode: ClusterGenerationMode
    public let schedule: ClusterPrefillSchedule
    public let ranks: [ClusterPlacementResourceQuote]
    public let tensorShares: [Int]?
    public init(cuts: [Int], mode: ClusterGenerationMode, schedule: ClusterPrefillSchedule,
                ranks: [ClusterPlacementResourceQuote], tensorShares: [Int]? = nil) {
        self.cuts = cuts; self.mode = mode; self.schedule = schedule; self.ranks = ranks
        self.tensorShares = tensorShares
    }
}

extension ClusterPlacementPlanner {
    /// Shared model-independent route for exact adapter quotes. Supported modes
    /// and structural cuts come from the adapter, costs from the existing speed
    /// estimator/planner. All fit, working-set, headroom, request-time, speculative
    /// and TP-margin ordering stays in Context, the same path plan() uses.
    /// This API does NOT add structural cuts to a public admitted-cut catalog.
    public static func rankQuoted(devices: [ClusterPlacementDevice], layout: ClusterModelLayout,
                                  shapes: [ClusterPlacementQuotedShape], policy: ClusterPlacementPolicy = .init(),
                                  link: ClusterLinkCosts = .unmeasured) throws -> [ClusterPlacementCandidate] {
        try layout.validate()
        guard devices.count >= 2, devices.count <= policy.maximumRanges,
              devices.allSatisfy({ !$0.label.isEmpty && $0.label.utf8.count <= 64 }),
              Set(devices.map(\.label)).count == devices.count,
              shapes.count <= policy.maximumCandidates else { throw ClusterPlacementError("Invalid quoted placement size/devices") }
        for device in devices { try device.profile.validate() }
        if let leader = policy.leader, devices.first?.label != leader { return [] }
        let prompt = policy.promptTokens ?? layout.maximumPromptTokens
        let output = policy.outputTokens ?? layout.maximumOutputTokens
        guard (1...layout.maximumPromptTokens).contains(prompt), (1...layout.maximumOutputTokens).contains(output) else {
            throw ClusterPlacementError("Quoted placement request exceeds adapter scope")
        }
        let devices = ClusterHardwarePrior.absolute(devices, layout: layout, link: link)
        let modes = layout.generationModes.filter {
            (policy.modes?.contains($0) ?? true) && (policy.handOffModes || !$0.isHandOff)
                && (policy.forcedMode?.admits($0) ?? true)
        }
        let schedules = layout.prefillSchedules.filter { policy.schedules?.contains($0) ?? true }
        let context = Context(devices: devices, layout: layout, prompt: prompt, outputs: output,
            modes: modes, schedules: schedules, link: link, policy: policy)
        let candidates = try shapes.compactMap { shape -> ClusterPlacementCandidate? in
            guard modes.contains(shape.mode), schedules.contains(shape.schedule),
                  shape.ranks.count == devices.count, shape.cuts.allSatisfy(layout.structuralCuts.contains),
                  shape.ranks.allSatisfy(\.fits),
                  policy.admitsShape?(devices.map { $0.profile.chip }, shape.cuts, shape.mode) ?? true else { return nil }
            // A real supported TP adapter needs real reduction costs before it
            // competes. No synthetic TP implementation or zero-cost link credit.
            if shape.mode.usesTensorParallelDecode {
                guard layout.tensorParallel != nil, link.reduction?.keyed == true else { return nil }
            }
            let prediction = try evaluate(devices: devices, cuts: shape.cuts, mode: shape.mode,
                prefillSchedule: shape.schedule, layout: layout, policy: policy, link: link,
                tensorShares: shape.tensorShares)
            guard [prediction.rested.requestSeconds, prediction.sustained.requestSeconds].allSatisfy({ $0.isFinite && $0 > 0 }) else {
                throw ClusterPlacementError("Nonfinite quoted placement prediction")
            }
            let ranks = zip(prediction.ranks, shape.ranks).map { original, quote in
                let total = quote.nativeBytes + quote.hostBytes // fits checked overflow above.
                return ClusterPlacementRank(rank: original.rank, device: original.device,
                    firstLayer: original.firstLayer, endLayer: original.endLayer, weightsBytes: original.weightsBytes,
                    loadNeedBytes: total, requestNeedBytes: total, needBytes: total,
                    admissibleNowBytes: quote.combinedAvailableBytes, fit: .now,
                    withinGPUWorkingSet: quote.nativeBytes <= devices[original.rank].profile.residentCapacityBytes,
                    transientBytes: original.transientBytes,
                    hardwareFits: devices[original.rank].profile.hardwareFits(needBytes: total,
                        weightsBytes: original.weightsBytes, largestTensorBytes: 0))
            }
            let headroom = ranks.map { Double($0.admissibleNowBytes - $0.needBytes) / Double(max(1, $0.needBytes)) }.min() ?? 0
            return ClusterPlacementCandidate(cuts: prediction.cuts, mode: prediction.mode,
                prefillSchedule: prediction.prefillSchedule, ranks: ranks,
                sustained: prediction.sustained, rested: prediction.rested, tier: 0,
                withinGPUWorkingSet: ranks.allSatisfy(\.withinGPUWorkingSet), smallestHeadroomShare: headroom,
                tensorShares: prediction.tensorShares, shares: prediction.shares, aloneRoute: prediction.aloneRoute)
        }
        return context.holdingTensorParallelToItsMargin(
            context.ordered(candidates, regime: policy.regime), regime: policy.regime)
    }
}
