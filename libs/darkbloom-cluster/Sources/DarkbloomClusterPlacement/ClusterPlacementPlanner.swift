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
    /// Which of a device's two measured rates the ranking uses. Serving is
    /// steady state, so the default is the settled one.
    public var regime: Regime = .sustained
    /// Nil means every mode and schedule the layout lists.
    public var modes: [ClusterGenerationMode]?
    public var schedules: [ClusterPrefillSchedule]?
    /// A Mac alone is reported "as fast" when its predicted request time is
    /// within this share of the chosen placement's.
    public var tieTolerance = 0.03
    /// A placement whose tightest rank keeps less than this share of its need
    /// in reserve is ranked after every placement that keeps more, inside its
    /// tier: memory that moves a little between planning and loading would
    /// refuse it.
    public var comfortableHeadroomShare = 0.10
    /// The runtime executes two ranges.
    public var maximumRanges = 2
    public var maximumCandidates = 200_000
    public var alternatives = 5
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
    /// False when weights and request state exceed what the GPU says an
    /// application may keep resident on that Mac.
    public let withinGPUWorkingSet: Bool
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
    /// Worst device answer: 0 fits now, 1 after file cache is released,
    /// 2 after other programs release memory.
    public let tier: Int
    public let withinGPUWorkingSet: Bool
    /// Smallest share of admissible memory left over on any rank; negative
    /// when a rank does not fit now.
    public let smallestHeadroomShare: Double
    public var cut: Int { cuts[0] }
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
        public let afterFileCacheReleaseBytes: Int
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
    /// The chosen placement, or nil when the model is refused.
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
    public let candidatesConsidered: Int
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
        let prompt = policy.promptTokens ?? layout.maximumPromptTokens
        let outputs = policy.outputTokens ?? layout.maximumOutputTokens
        guard (1...layout.maximumPromptTokens).contains(prompt), (1...layout.maximumOutputTokens).contains(outputs) else {
            throw ClusterPlacementError("The reference request is outside the model profile's limits")
        }
        let modes = layout.generationModes.filter { policy.modes?.contains($0) ?? true }
        let schedules = layout.prefillSchedules.filter { policy.schedules?.contains($0) ?? true }
        guard !modes.isEmpty, !schedules.isEmpty else {
            throw ClusterPlacementError("The policy allows no generation mode or prefill schedule this model lists")
        }
        let context = Context(devices: devices, layout: layout, prompt: prompt, outputs: outputs,
            modes: modes, schedules: schedules, link: link, policy: policy)
        let admitted = try context.candidates(.admitted)
        let ranked = context.ordered(admitted.filter { $0.tier < 3 }, regime: policy.regime)
        let other: ClusterPlacementPolicy.Regime = policy.regime == .sustained ? .rested : .sustained
        let structural = context.ordered(try context.candidates(.structural).filter { $0.tier < 3 }, regime: policy.regime).first
        let anyBoundary = context.ordered(try context.candidates(.anyBoundary).filter { $0.tier < 3 }, regime: policy.regime).first
        let basis = ClusterPlacementBasis(source: devices.map(\.speed.source).max() ?? .assumedEqual,
            absolute: devices.allSatisfy(\.speed.absolute), linkCostsMeasured: link.measured)
        var refusal: ClusterPlacementRefusal?
        if ranked.isEmpty {
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
                    afterFileCacheReleaseBytes: device.profile.memory.afterFileCacheReleaseBytes,
                    mostLayersAsFirst: extent.first,
                    mostBytesAsFirst: extent.first > 0 ? layout.range(0..<extent.first).loadedBytes : 0,
                    mostLayersAsLast: extent.last,
                    mostBytesAsLast: extent.last > 0 ? layout.range((layout.layerCount - extent.last)..<layout.layerCount).loadedBytes : 0)
            }, closest: admitted.min { context.shortBytes($0) < context.shortBytes($1) },
                modelLoadedBytes: layout.wholeModelLoadedBytes, uncoveredLayers: uncovered?.layers, uncoveredBytes: uncovered?.bytes,
                fitsAtAStructuralCut: structural != nil, fitsAtSomeLayerBoundary: anyBoundary != nil)
        }
        let alone = devices.map(context.alone)
        var aloneAsFast: [String] = []
        if let chosen = ranked.first {
            let limit = chosen.prediction(policy.regime).requestSeconds * (1 + policy.tieTolerance)
            aloneAsFast = alone.filter { $0.fit.tier <= chosen.tier && $0.prediction(policy.regime).requestSeconds <= limit }.map(\.device)
        }
        return .init(runtimeModelID: layout.runtimeModelID, promptTokens: prompt, outputTokens: outputs,
            regime: policy.regime, basis: basis, chosen: ranked.first,
            alternatives: Array(ranked.dropFirst().prefix(policy.alternatives)),
            chosenForOtherRegime: context.ordered(admitted.filter { $0.tier < 3 }, regime: other).first,
            bestStructural: structural, bestAnyBoundary: anyBoundary,
            alone: alone, aloneAsFast: aloneAsFast, refusal: refusal, candidatesConsidered: admitted.count)
    }

    /// One explicit placement, evaluated as the planner evaluates its own
    /// candidates: `devices` in rank order, `cuts` ascending. Nothing is
    /// checked against the layout's cut lists, so a caller can ask about any
    /// layer boundary.
    public static func evaluate(devices: [ClusterPlacementDevice], cuts: [Int], mode: ClusterGenerationMode,
                                prefillSchedule: ClusterPrefillSchedule, layout: ClusterModelLayout,
                                policy: ClusterPlacementPolicy = .init(),
                                link: ClusterLinkCosts = .unmeasured) throws -> ClusterPlacementCandidate {
        try layout.validate()
        guard devices.count == cuts.count + 1, cuts == Array(Set(cuts)).sorted(),
              cuts.allSatisfy({ (1..<layout.layerCount).contains($0) }) else {
            throw ClusterPlacementError("A placement is one device per range and ascending cuts inside the model")
        }
        let context = Context(devices: devices, layout: layout, prompt: policy.promptTokens ?? layout.maximumPromptTokens,
            outputs: policy.outputTokens ?? layout.maximumOutputTokens, modes: [mode], schedules: [prefillSchedule],
            link: link, policy: policy)
        return context.evaluate(order: Array(devices.indices), cuts: cuts, mode: mode, schedule: prefillSchedule)
    }

    struct Context {
        let devices: [ClusterPlacementDevice]
        let layout: ClusterModelLayout
        let prompt: Int, outputs: Int
        let modes: [ClusterGenerationMode], schedules: [ClusterPrefillSchedule]
        let link: ClusterLinkCosts
        let policy: ClusterPlacementPolicy

        func cuts(_ scope: CutScope) -> [Int] {
            switch scope {
            case .admitted: layout.admittedCuts
            case .structural: layout.structuralCuts
            case .anyBoundary: Array(1..<layout.layerCount)
            }
        }

        /// Every ordered choice of `count` devices.
        func orders(_ count: Int) -> [[Int]] {
            func extend(_ prefix: [Int]) -> [[Int]] {
                if prefix.count == count { return [prefix] }
                return devices.indices.filter { !prefix.contains($0) }.flatMap { extend(prefix + [$0]) }
            }
            return extend([])
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
            for ranges in 2...most where available.count >= ranges - 1 {
                let sets = cutSets(available, ranges - 1), permutations = orders(ranges)
                guard sets.count * permutations.count * modes.count + result.count <= policy.maximumCandidates else {
                    throw ClusterPlacementError("Placing \(ranges) ranges over \(available.count) cuts on \(devices.count) devices "
                        + "is more than \(policy.maximumCandidates) candidates; a bottleneck partition is needed instead of enumeration")
                }
                for order in permutations {
                    for set in sets {
                        for mode in modes {
                            // A lookahead prefill is never slower than a serial one of the same placement.
                            let schedule = schedules.contains(.oneChunkLookahead) ? ClusterPrefillSchedule.oneChunkLookahead : schedules[0]
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
            let loads = [own] + (mode == .phaseSplit && last ? earlier : [])
            var held = 0, loadNeed = 0, largest = 0
            for part in loads {
                let rounded = part.loadedBytes + part.tensorCount * memory.pageSizeBytes
                let ask = max(memory.minimumAdmissibleBytes,
                    rounded + 2 * part.largestTensorBytes + memory.loadScratchBytes + memory.loadingHeadroomBytes)
                loadNeed = max(loadNeed, held + ask)
                held += rounded; largest = max(largest, part.largestTensorBytes)
            }
            let context = prompt + outputs
            let ownState = loads.reduce(0) { $0 + $1.stateBytes(tokens: context) }
            let state = max(layout.requestChargeEveryRankBytes, ownState)
            let work = loads.reduce(0) { $0 + $1.requestWorkBytes }
            var extra = 0
            // A producer keeps the next chunk's residual beside the current one.
            if schedule == .oneChunkLookahead, !last, prompt > layout.maximumChunkTokens {
                extra += 2 * layout.maximumChunkTokens * layout.boundaryBytesPerToken
            }
            // The state that changes owner exists on both sides while it moves.
            if mode == .phaseSplit {
                let moving = last ? earlier.reduce(0) { $0 + $1.stateBytes(tokens: prompt) } : own.stateBytes(tokens: prompt)
                extra += 2 * moving
            }
            let requestNeed = max(memory.minimumAdmissibleBytes, state + work + extra + memory.loadingHeadroomBytes)
            let need = max(loadNeed, held + requestNeed)
            return .init(rank: rank, device: device.label, firstLayer: own.layers.lowerBound, endLayer: own.layers.upperBound,
                weightsBytes: held, loadNeedBytes: loadNeed, requestNeedBytes: requestNeed, needBytes: need,
                admissibleNowBytes: memory.admissibleNowBytes,
                fit: device.profile.fit(needBytes: need, weightsBytes: held, largestTensorBytes: largest),
                withinGPUWorkingSet: held + state + work + extra <= device.profile.gpuRecommendedWorkingSetBytes)
        }

        func prediction(_ regime: ClusterPlacementPolicy.Regime, order: [ClusterPlacementDevice],
                        ranges: [ClusterModelLayout.Range], mode: ClusterGenerationMode,
                        schedule: ClusterPrefillSchedule) -> ClusterPlacementPrediction {
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
            // Serial: each chunk passes through every range in turn. Lookahead:
            // the slowest range sets the pace and one chunk passes through the rest.
            var first = schedule == .oneChunkLookahead
                ? Double(prompt) * slowest + Double(chunk) * (sum - slowest)
                : Double(prompt) * sum
            first += Double(chunks * (ranges.count - 1)) * link.perChunkSeconds
            var step: Double, handoff = 0.0
            if mode == .phaseSplit, let lastDevice = order.last {
                // After the hand-off the last rank decodes alone.
                step = 1 / rates(lastDevice, regime).0.decodeTokensPerSecond
                handoff = link.handoffSecondsPerByte
                    * Double(ranges.dropLast().reduce(0) { $0 + $1.stateBytes(tokens: prompt) })
            } else {
                step = decode.reduce(0, +)
            }
            step += link.perDecodeStepSeconds[mode.rawValue] ?? 0
            return .init(regime: regime, regimeMeasuredOnEveryDevice: measured, firstTokenSeconds: first,
                prefillTokensPerSecond: Double(prompt) / first, decodeTokensPerSecond: 1 / step,
                requestSeconds: first + handoff + Double(max(0, outputs - 1)) * step)
        }

        func evaluate(order: [Int], cuts: [Int], mode: ClusterGenerationMode,
                      schedule: ClusterPrefillSchedule) -> ClusterPlacementCandidate {
            let bounds = [0] + cuts + [layout.layerCount]
            let ranges = (0..<order.count).map { layout.range(bounds[$0]..<bounds[$0 + 1]) }
            let chosen = order.map { devices[$0] }
            let ranks = ranges.indices.map { index in
                requirement(rank: index, of: ranges.count, device: chosen[index], own: ranges[index],
                     earlier: Array(ranges[..<index]), mode: mode, schedule: schedule)
            }
            let headroom = ranks.map { Double($0.admissibleNowBytes - $0.needBytes) / Double(max(1, $0.needBytes)) }.min() ?? 0
            return .init(cuts: cuts, mode: mode, prefillSchedule: schedule, ranks: ranks,
                sustained: prediction(.sustained, order: chosen, ranges: ranges, mode: mode, schedule: schedule),
                rested: prediction(.rested, order: chosen, ranges: ranges, mode: mode, schedule: schedule),
                tier: ranks.map(\.fit.tier).max() ?? 3, withinGPUWorkingSet: ranks.allSatisfy(\.withinGPUWorkingSet),
                smallestHeadroomShare: headroom)
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

        /// Best first: tier; then inside the GPU working set; then, among
        /// placements that fit now, those with comfortable headroom; then
        /// predicted request time. Equal times are broken by the larger
        /// smallest headroom, the lower cut, the devices' labels in rank order
        /// and the mode's place in the layout. Nothing depends on the order
        /// the devices were given in, so the result is the same whichever
        /// Mac asks.
        func ordered(_ candidates: [ClusterPlacementCandidate], regime: ClusterPlacementPolicy.Regime) -> [ClusterPlacementCandidate] {
            func group(_ c: ClusterPlacementCandidate) -> Int {
                let tight = c.tier == 0 && c.smallestHeadroomShare < policy.comfortableHeadroomShare
                return c.tier * 4 + (c.withinGPUWorkingSet ? 0 : 2) + (tight ? 1 : 0)
            }
            func time(_ c: ClusterPlacementCandidate) -> Double { c.prediction(regime).requestSeconds }
            return candidates.sorted { a, b in
                if group(a) != group(b) { return group(a) < group(b) }
                if time(a) != time(b) { return time(a) < time(b) }
                if a.smallestHeadroomShare != b.smallestHeadroomShare { return a.smallestHeadroomShare > b.smallestHeadroomShare }
                if a.cuts != b.cuts { return a.cuts.lexicographicallyPrecedes(b.cuts) }
                let la = a.ranks.map(\.device), lb = b.ranks.map(\.device)
                if la != lb { return la.lexicographicallyPrecedes(lb) }
                return (modes.firstIndex(of: a.mode) ?? 0) < (modes.firstIndex(of: b.mode) ?? 0)
            }
        }

        func alone(_ device: ClusterPlacementDevice) -> ClusterPlacementAlone {
            let whole = layout.range(0..<layout.layerCount)
            let rank = requirement(rank: 0, of: 1, device: device, own: whole, earlier: [], mode: .pipeline, schedule: .serial)
            return .init(device: device.label, needBytes: rank.needBytes, fit: rank.fit,
                withinGPUWorkingSet: rank.withinGPUWorkingSet,
                sustained: prediction(.sustained, order: [device], ranges: [whole], mode: .pipeline, schedule: .serial),
                rested: prediction(.rested, order: [device], ranges: [whole], mode: .pipeline, schedule: .serial))
        }
    }
}
