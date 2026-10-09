import DarkbloomClusterProtocol
import Foundation

/// A plan or a refusal in plain words: what was detected, what the model is
/// made of, what was chosen and why, and what the choice rests on. Every
/// figure that is not a measurement says so on its own line.
public enum ClusterPlacementExplanation {
    static let gib = 1_073_741_824.0

    /// Two decimals of GiB. A need is rounded up and a holding down, so a
    /// printed pair never makes a refusal look like a fit.
    static func gibText(_ bytes: Int, roundUp: Bool = false) -> String {
        let hundredths = Double(bytes) * 100 / gib
        let value = (roundUp ? hundredths.rounded(.up) : hundredths.rounded(.down)) / 100
        return String(format: "%.2f GiB", value)
    }

    static func number(_ value: Double, _ digits: Int) -> String { String(format: "%.\(digits)f", value) }
    static func seconds(_ value: Double) -> String { String(format: value < 10 ? "%.2f s" : "%.1f s", value) }
    static func rate(_ value: Double) -> String { String(format: value < 100 ? "%.1f" : "%.0f", value) }

    public static func describe(_ fit: ClusterPlacementFit) -> String {
        switch fit {
        case .now:
            return "fits now"
        case .gateCountsLess(let bytes):
            return "does not pass the load gate now, by \(gibText(bytes, roundUp: true)). This Mac's free pages and the file cache above the kernel's "
                + "own minimum would cover it without an application losing memory; the gate counts less of that cache than there is, "
                + "so its rule refuses here, not the Mac's memory. Nothing has to close"
        case .afterApplicationsRelease(let bytes):
            return "does not fit now: applications would have to release \(gibText(bytes, roundUp: true)) first. "
                + "The file cache the kernel keeps as its minimum does not count; it is not memory that closing or waiting frees"
        case .afterRestart(let bytes):
            return "does not fit as this Mac is: with every application closed it would still be \(gibText(bytes, roundUp: true)) short, "
                + "because the kernel keeps its minimum of file cache. Only a restart empties that"
        case .never(let bytes):
            return "cannot fit on this Mac whatever is freed: short by \(gibText(bytes, roundUp: true))"
        }
    }

    public static func device(_ label: String, _ profile: ClusterDeviceProfile) -> [String] {
        let m = profile.memory
        var lines = ["\(label): \(profile.chip), \(profile.performanceCores) performance and \(profile.efficiencyCores) efficiency cores"
            + (profile.gpuCores.map { ", \($0) GPU cores" } ?? "") + ", macOS \(profile.osVersion) (\(profile.osBuild)), "
            + "\(gibText(profile.physicalMemoryBytes)) of memory."]
        // Three parts with three remedies, so they are never added up.
        lines.append("  Memory as sampled at \(m.sampledUTC): \(gibText(m.actualFreeBytes)) free; \(gibText(m.anonymousBytes)) held by applications "
            + "(closing them frees it); \(gibText(m.fileBackedBytes)) of file cache, of which the kernel keeps \(gibText(min(m.fileBackedBytes, m.fileCacheReserveBytes))) "
            + "as its minimum (not reclaimable short of a restart) and would give up \(gibText(m.fileCacheAboveReserveBytes)); "
            + "\(gibText(m.wiredBytes + m.compressorBytes)) wired or compressed.")
        if m.judged {
            lines.append("  The load gate would admit \(gibText(m.admissibleNowBytes)) now: the free pages plus \(gibText(m.countedFileCacheBytes)) "
                + "of that cache (rule \(m.gatePolicy)). With every application closed: \(gibText(m.withApplicationsClosedBytes)).")
        } else {
            lines.append("  The load gate would not judge this Mac's memory now: \(m.unjudgedReason ?? "no reason given").")
        }
        lines.append("  Its GPU says an application may keep \(gibText(profile.gpuRecommendedWorkingSetBytes)) resident.")
        if !profile.power.admitsExecution {
            lines.append("  A request would be refused here now: external power \(profile.power.onExternalPower ? "yes" : "no"), "
                + "low power mode \(profile.power.lowPowerMode ? "on" : "off"), thermal state \(profile.power.thermalState).")
        }
        return lines
    }

    public static func layout(_ layout: ClusterModelLayout) -> [String] {
        let weights = layout.layers.reduce(0) { $0 + $1.weights.loadedBytes }
        func cuts(_ values: [Int]) -> String {
            guard let first = values.first, let last = values.last else { return "none" }
            return values.count <= 6 ? values.map(String.init).joined(separator: ", ") : "\(first) to \(last) (\(values.count) positions)"
        }
        var lines = ["\(layout.runtimeModelID): \(layout.layerCount) layers holding \(gibText(weights)), "
            + "\(gibText(layout.ingress.loadedBytes)) only the first range holds and \(gibText(layout.egress.loadedBytes)) only the last; "
            + "\(gibText(layout.wholeModelLoadedBytes)) in all. \(gibText(layout.excluded.storedBytes)) of the artifact is loaded by no range."]
        lines.append("  This runtime admits a cut after layer count \(cuts(layout.admittedCuts))"
            + (layout.structuralCuts == layout.admittedCuts ? "." : "; its stage plan could cut at \(cuts(layout.structuralCuts))."))
        lines.append("  Modes: \(layout.generationModes.map(\.rawValue).joined(separator: ", ")). "
            + "Largest request: \(layout.maximumPromptTokens) prompt and \(layout.maximumOutputTokens) output tokens.")
        return lines
    }

    public static func speed(_ label: String, _ speed: ClusterDeviceSpeed) -> String {
        let unit = speed.absolute ? " tok/s" : " (relative)"
        var text = "\(label): prefill \(rate(speed.rested.prefillTokensPerSecond))\(unit) and decode "
            + "\(rate(speed.rested.decodeTokensPerSecond))\(unit) rested"
        if let sustained = speed.sustained {
            text += "; \(rate(sustained.prefillTokensPerSecond)) and \(rate(sustained.decodeTokensPerSecond)) sustained"
        } else {
            text += "; no sustained figure"
        }
        return text + ". " + (speed.source.isEstimate ? "ESTIMATE, " : "") + speed.explanation + "."
    }

    static func prediction(_ p: ClusterPlacementPrediction, _ basis: ClusterPlacementBasis, prompt: Int, outputs: Int) -> String {
        let label = p.regime == .sustained ? "Sustained" : "Rested"
        guard basis.absolute else {
            return "\(label): relative figures only, since no Mac has measured this model."
        }
        return "\(label)\(p.regimeMeasuredOnEveryDevice ? "" : " (a rested rate stood in where no sustained one exists)"): "
            + "first token after \(seconds(p.firstTokenSeconds)) (\(rate(p.prefillTokensPerSecond)) prompt tok/s), "
            + "decode \(rate(p.decodeTokensPerSecond)) tok/s, the request \(seconds(p.requestSeconds))."
    }

    public static func candidate(_ c: ClusterPlacementCandidate, basis: ClusterPlacementBasis, prompt: Int, outputs: Int) -> [String] {
        var lines: [String] = []
        for r in c.ranks {
            lines.append("Rank \(r.rank): \(r.device), layers \(r.firstLayer) to \(r.endLayer - 1) (\(r.endLayer - r.firstLayer)). "
                + "It holds \(gibText(r.weightsBytes)) of weights and needs \(gibText(r.needBytes, roundUp: true)) admissible "
                + "against \(gibText(r.admissibleNowBytes)): \(describe(r.fit))."
                + (r.withinGPUWorkingSet ? "" : " That is more than its GPU says an application may keep resident."))
        }
        let modeText: String
        switch c.mode {
        case .pipeline: modeText = "pipeline (every token passes through each rank in turn)"
        case .pipelineCompactDecode: modeText = "pipeline with compact decode framing"
        case .phaseSplit: modeText = "phase split (the ranks prefill together, then the last rank, which holds every layer, decodes alone)"
        }
        lines.append("Mode: \(modeText); prefill schedule \(c.prefillSchedule == .oneChunkLookahead ? "one chunk of lookahead" : "serial").")
        return lines
    }

    /// One line saying what each Mac holds while a session of this placement
    /// is up: which layers and how much, beside the Mac's own size, so that a
    /// small share on a large Mac is not read as nothing running there.
    public static func holdings(_ c: ClusterPlacementCandidate, devices: [ClusterPlacementDevice]) -> String {
        "While the session is up: " + c.ranks.map { r in
            let size = devices.first { $0.label == r.device }.map { " of its \(gibText($0.profile.physicalMemoryBytes))" } ?? ""
            let every = c.mode == .phaseSplit && r.rank == c.ranks.count - 1 && r.rank > 0
            return "\(r.device) holds layers \(r.firstLayer) to \(r.endLayer - 1)"
                + (every ? " and, to decode alone, every earlier layer too" : "") + ": \(gibText(r.weightsBytes)) of weights\(size)"
        }.joined(separator: "; ") + "."
    }

    public static func describe(_ result: ClusterPlacementResult, devices: [ClusterPlacementDevice],
                                layout: ClusterModelLayout, link: ClusterLinkCosts = .unmeasured) -> [String] {
        var lines = ["What each Mac detected"]
        for device in devices { lines += Self.device(device.label, device.profile).map { "  " + $0 } }
        lines.append("What the model is made of")
        lines += Self.layout(layout).map { "  " + $0 }
        lines.append("Speed of each Mac on this model, alone")
        for device in devices { lines.append("  " + speed(device.label, device.speed)) }
        let request = "\(result.promptTokens) prompt tokens and \(result.outputTokens) outputs"
        if let chosen = result.chosen {
            lines.append(chosen.tier == 0 ? "Chosen placement" : "Chosen placement (it does not fit now; see each rank)")
            lines += candidate(chosen, basis: result.basis, prompt: result.promptTokens, outputs: result.outputTokens).map { "  " + $0 }
            lines.append("  " + holdings(chosen, devices: devices))
            lines.append("  Predicted for \(request):")
            lines.append("    " + prediction(chosen.prediction(result.regime), result.basis, prompt: result.promptTokens, outputs: result.outputTokens))
            let other: ClusterPlacementPolicy.Regime = result.regime == .sustained ? .rested : .sustained
            lines.append("    " + prediction(chosen.prediction(other), result.basis, prompt: result.promptTokens, outputs: result.outputTokens))
            lines.append("Why")
            lines += reasons(result, chosen: chosen, devices: devices, layout: layout).map { "  " + $0 }
            lines.append("What this rests on")
            if result.basis.source.isEstimate {
                lines.append("  The speeds are ESTIMATES (weakest source: \(result.basis.source.rawValue)). A probe on each Mac replaces them.")
            } else {
                lines.append("  The speeds are measured on each Mac; the split of time between ranges assumes every layer of one kind costs the same.")
            }
            lines.append("  Link and framing costs: " + link.provenance + ".")
            lines.append("  This is a plan, not an admission. The load gate on each Mac decides when it loads, on what that Mac has then; "
                + "the plan and the gate use one rule, so a rank that fits here is refused there only if its memory has changed.")
        } else if let refusal = result.refusal {
            lines.append("Refused: no division of this model between these Macs is possible, and no Mac holds it alone")
            lines.append("  The model holds \(gibText(refusal.modelLoadedBytes)) when loaded, and each rank needs its load and request headroom on top of its share.")
            for d in refusal.devices {
                lines.append("  \(d.device): \(gibText(d.physicalMemoryBytes)) of memory, \(gibText(d.admissibleNowBytes)) admissible now, "
                    + "\(gibText(d.withApplicationsClosedBytes)) with every application closed. Whatever is freed on it, it could hold at most the first "
                    + "\(d.mostLayersAsFirst) layers (\(gibText(d.mostBytesAsFirst))) or the last \(d.mostLayersAsLast) (\(gibText(d.mostBytesAsLast))).")
            }
            if let layers = refusal.uncoveredLayers, let bytes = refusal.uncoveredBytes, layers > 0 {
                lines.append("  In the better order that leaves \(layers) layers (\(gibText(bytes, roundUp: true))) that neither Mac could hold.")
            }
            if let closest = refusal.closest {
                lines.append("  The closest admitted placement:")
                lines += candidate(closest, basis: result.basis, prompt: result.promptTokens, outputs: result.outputTokens).map { "    " + $0 }
            }
            if refusal.fitsAtAStructuralCut {
                lines.append("  A cut this runtime does not admit would fit. The cut list refuses this model, not the Macs' memory.")
            } else if refusal.fitsAtSomeLayerBoundary {
                lines.append("  A layer boundary the model's stage plan cannot cut at would fit. The plan's cut rule refuses this model, not the Macs' memory.")
            } else {
                lines.append("  Freeing memory on these Macs cannot change this: at every layer boundary and in every order, some share is more than its Mac can ever admit.")
            }
        } else {
            // No division is possible, and a Mac holds the model alone.
            lines.append("No division between these Macs is possible; one Mac holds the model alone")
            for a in result.alone where a.fit.possible {
                lines.append("  \(a.device) alone needs \(gibText(a.needBytes, roundUp: true)): \(describe(a.fit)). That is the ordinary single-Mac path, not a cluster session.")
            }
        }
        if !result.alternatives.isEmpty {
            lines.append("Next best")
            for a in result.alternatives {
                let p = a.prediction(result.regime)
                lines.append("  cut \(a.cuts.map(String.init).joined(separator: "/")), \(a.ranks.map(\.device).joined(separator: " then ")), \(a.mode.rawValue): "
                    + (result.basis.absolute ? "first token \(seconds(p.firstTokenSeconds)), decode \(rate(p.decodeTokensPerSecond)) tok/s, request \(seconds(p.requestSeconds))"
                        : "relative time \(number(p.requestSeconds, 3))")
                    + (a.tier == 0 ? "" : "; does not fit now"))
            }
        }
        lines.append("Each Mac alone, for comparison")
        for a in result.alone {
            let p = result.regime == .sustained ? a.sustained : a.rested
            lines.append("  \(a.device): needs \(gibText(a.needBytes, roundUp: true)): \(describe(a.fit))"
                + (result.basis.absolute && a.fit.possible ? "; first token \(seconds(p.firstTokenSeconds)), decode \(rate(p.decodeTokensPerSecond)) tok/s, request \(seconds(p.requestSeconds))." : "."))
        }
        if let chosen = result.chosen, !result.aloneAsFast.isEmpty, result.basis.absolute {
            lines.append("  For this request \(result.aloneAsFast.joined(separator: " and ")) alone is as fast as the placement "
                + "(\(seconds(chosen.prediction(result.regime).requestSeconds))): "
                + (result.promptTokens <= layout.maximumChunkTokens
                    ? "a prompt of one chunk passes through the ranks one after the other, so a second Mac adds nothing to it."
                    : "the second Mac gains less than the tie tolerance at this prompt length."))
        }
        return lines
    }

    static func reasons(_ result: ClusterPlacementResult, chosen: ClusterPlacementCandidate,
                        devices: [ClusterPlacementDevice], layout: ClusterModelLayout) -> [String] {
        var lines: [String] = []
        let regime = result.regime, p = chosen.prediction(regime)
        let share = chosen.ranks.map { Double($0.endLayer - $0.firstLayer) / Double(layout.layerCount) }
        if result.basis.source == .assumedEqual {
            lines.append("Nothing is known about either Mac's speed on this model, so the layers are divided to fit memory and, within that, evenly. "
                + "Speed did not inform this split.")
        } else if chosen.ranks.count == 2, let first = devices.first(where: { $0.label == chosen.ranks[0].device }),
                  let second = devices.first(where: { $0.label == chosen.ranks[1].device }) {
            let a = (regime == .sustained ? first.speed.sustained : nil) ?? first.speed.rested
            let b = (regime == .sustained ? second.speed.sustained : nil) ?? second.speed.rested
            let ta = share[0] / a.prefillTokensPerSecond * 1000, tb = share[1] / b.prefillTokensPerSecond * 1000
            lines.append("With lookahead the two ranks work on neighbouring chunks at once, so the slower share sets the pace. "
                + "\(chosen.ranks[0].device) takes \(number(share[0] * 100, 0))% of the layers (\(number(ta, 3)) ms per prompt token there) and "
                + "\(chosen.ranks[1].device) \(number(share[1] * 100, 0))% (\(number(tb, 3)) ms); "
                + "the cut is the admitted position where the whole request is predicted shortest.")
        }
        if chosen.mode == .phaseSplit {
            lines.append("The last rank holds every layer and decodes alone after the first token, because that is faster than passing each token through both.")
        }
        if let other = result.chosenForOtherRegime, other.cuts != chosen.cuts || other.ranks.map(\.device) != chosen.ranks.map(\.device) || other.mode != chosen.mode {
            let name = regime == .sustained ? "rested" : "sustained"
            lines.append("Optimising the \(name) rates instead would choose cut \(other.cuts.map(String.init).joined(separator: "/")), "
                + "\(other.ranks.map(\.device).joined(separator: " then ")), \(other.mode.rawValue).")
        }
        func gain(_ better: ClusterPlacementCandidate?) -> Double? {
            guard let better else { return nil }
            let t = better.prediction(regime).requestSeconds
            return t < p.requestSeconds ? (p.requestSeconds / t - 1) * 100 : nil
        }
        if layout.structuralCuts != layout.admittedCuts, let best = result.bestStructural, best.cuts != chosen.cuts, let g = gain(best), best.tier <= chosen.tier {
            lines.append("The runtime's cut list costs \(number(g, 1))% of the request: cut \(best.cuts.map(String.init).joined(separator: "/")), "
                + "which the stage plan could make and this runtime does not admit, is predicted that much faster.")
        }
        if let best = result.bestAnyBoundary, best.cuts != chosen.cuts, best.cuts != (result.bestStructural?.cuts ?? []),
           let g = gain(best), best.tier <= chosen.tier {
            lines.append("The stage plan's cut rule costs \(number(g, 1))% of the request: layer boundary \(best.cuts.map(String.init).joined(separator: "/")) "
                + "is predicted that much faster and is not a position the plan can cut at.")
        }
        if chosen.tier > 0 {
            lines.append("No admitted placement passes the load gate now; this is the best of those that could, with what each rank says is in the way.")
        }
        return lines
    }
}
