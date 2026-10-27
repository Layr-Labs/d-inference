import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// What a person reads about tensor parallel before choosing a model: the
/// setup's model list says in a few words why a model that has it was split
/// otherwise (`ClusterPlacementExplanation.tensorParallelNote`), at the end
/// of the model's one line, and nothing for a model without it; the reason line says
/// why a pipeline was left out (`ClusterPlacementPolicy.modesReason`) instead
/// of claiming none fits (2026-10-24: Qwen3.8 27B read "no pipeline placement
/// fits these Macs"). Constructed Macs and links, recorded layouts: no model,
/// no GPU, no network.
func checkTensorParallelNotes(_ inputs: RetainedQwenInputs, golden: URL, _ checks: PlacementChecks) throws {
    typealias Note = ClusterPlacementExplanation.TensorParallelNote
    checks.require("TP note: every note is a few words (at most \(ClusterPlacementExplanation.tensorParallelNoteLimit) characters, plain text)",
        Note.allCases.allSatisfy { $0.rawValue.count <= ClusterPlacementExplanation.tensorParallelNoteLimit
            && $0.rawValue.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value < 127 } })
    let base = try ClusterPlacementLayouts.layout(configuration: inputs.twentySeven.configuration, tensors: inputs.twentySeven.stored)
    let tensorLayout = try executing(base, [.tensorParallel])
    let speed = modelled(floorMs: 2, bandwidthGBs: 400, weightBytes: tensorLayout.wholeModelLoadedBytes, prefill: 200)
    let devices = try [SyntheticMac.idle(64).device("first", speed: speed), SyntheticMac.idle(64).device("second", speed: speed)]
    var policy = ClusterPlacementPolicy()
    policy.promptTokens = 1024; policy.outputTokens = 128
    let request = policy
    func plan(_ link: ClusterLinkCosts = .unmeasured, layout: ClusterModelLayout? = nil,
              policy: ClusterPlacementPolicy? = nil) throws -> ClusterPlacementResult {
        try ClusterPlacementPlanner.plan(devices: devices, layout: layout ?? tensorLayout, policy: policy ?? request, link: link)
    }
    func note(_ result: ClusterPlacementResult) -> Note? { ClusterPlacementExplanation.tensorParallelNote(result) }

    let chosen = try plan(linkCosts(reductionMicroseconds: 10))
    checks.require("TP note: nothing when tensor parallel is the chosen split", chosen.chosen?.mode == .tensorParallel && note(chosen) == nil)
    // A dearer reduction at each step: chosen, then a near tie it must win by the margin, then slower; the note
    // follows the planner's own verdict and its comparison of the two at every step.
    var said: [Note] = [], agrees = true
    var micros = 10.0
    while micros <= 3_000, said.last != .slower {
        let result = try plan(linkCosts(reductionMicroseconds: micros))
        let tp = result.tensorParallel, mine = result.chosen
        let n = note(result)
        if mine?.mode == .tensorParallel { agrees = agrees && n == nil } else if let n {
            let best = tp?.tensorParallel?.prediction(result.regime).requestSeconds ?? .infinity
            let theirs = mine?.prediction(result.regime).requestSeconds ?? 0
            agrees = agrees && tp?.verdict == .predictedSlower && n == (best < theirs ? .aboutAsFast : .slower)
            if said.last != n { said.append(n) }
        } else { agrees = false }
        micros += 5
    }
    checks.require("TP note: as the reduction gets dearer, nothing (chosen), then about as fast (inside the margin), then slower here (\(said.map(\.rawValue)))",
        agrees && said == [.aboutAsFast, .slower])
    checks.require("TP note: an unmeasured link says so (the first load measures it)", note(try plan()) == .linkUnmeasured)
    checks.require("TP note: a link measured only in plaintext is not the keyed link the product uses",
        note(try plan(linkCosts(reductionMicroseconds: 45, keyed: false))) == .linkUnmeasured)
    checks.require("TP note: a runtime that does not execute tensor parallel for the model",
        note(try plan(linkCosts(reductionMicroseconds: 45), layout: try notExecuting(tensorLayout))) == .notForThisModel)
    var pipelineOnly = policy
    pipelineOnly.modes = [.pipeline]
    let excluded = try plan(linkCosts(reductionMicroseconds: 45), policy: pipelineOnly)
    checks.require("TP note: a policy that leaves tensor parallel out, without a reason given",
        note(excluded) == .excluded && excluded.modesReason == nil)
    pipelineOnly.modesReason = "concurrent requests are quoted for the pipeline only"
    let excludedWhy = try plan(linkCosts(reductionMicroseconds: 45), policy: pipelineOnly)
    checks.require("TP note: the policy's reason travels with the plan and its reason line",
        note(excludedWhy) == .excluded && excludedWhy.modesReason == pipelineOnly.modesReason
            && ClusterPlacementExplanation.deploymentReason(excludedWhy)
                == "Pipeline: the placement policy excludes the model's tensor-parallel modes (concurrent requests are quoted for the pipeline only); using pipeline candidates.")
    let doubled = ClusterPlacementExplanation.deploymentReason(excludedWhy) ?? ""
    checks.require("TP note: the policy's reason is said once", doubled.components(separatedBy: "concurrent requests").count == 2)
    // A model whose layout has no tensor-parallel plan: no row at all.
    let nemotron = try ClusterModelLayout.decode(Data(contentsOf: golden.appendingPathComponent("layouts/nvidia-nemotron-3.5-lightning-2026-09-30-r1.json")))
    let profiles = try ["mac-a", "mac-b"].map { try ClusterDeviceProfile.decode(Data(contentsOf: golden.appendingPathComponent("profile-\($0).json"))) }
    let recorded = zip(["mac-a", "mac-b"], profiles).map { ClusterPlacementDevice(label: $0, profile: $1, speed: .assumedEqual) }
    let plain = try ClusterPlacementPlanner.plan(devices: recorded, layout: nemotron, link: linkCosts(reductionMicroseconds: 45))
    checks.require("TP note: nothing for a model without tensor parallel (no noise in the list)",
        plain.chosen != nil && plain.tensorParallel == nil && note(plain) == nil)

    // Tensor parallel only (Qwen3.8 27B keeps images, video and logprobs only there), on a link where a pipeline
    // would be faster: the reason line says why no pipeline was planned, never that none fits.
    let slow = linkCosts(reductionMicroseconds: 3_000)
    var tensorOnly = policy
    tensorOnly.modes = [.tensorParallel]
    tensorOnly.modesReason = "Qwen3.8 27B keeps images, video and committed-token logprobs only in tensor parallel"
    let features = try plan(slow, policy: tensorOnly)
    checks.require("TP note: a pipeline left out for the model's features is said as such (\(ClusterPlacementExplanation.deploymentReason(features) ?? "-"))",
        features.chosen?.mode == .tensorParallel && note(features) == nil && features.modesReason == tensorOnly.modesReason
            && ClusterPlacementExplanation.deploymentReason(features)
                == "Tensor parallel: pipeline is left out (Qwen3.8 27B keeps images, video and committed-token logprobs only in tensor parallel).")
    let ordinary = try plan(slow)
    checks.require("TP note: the same Macs and link with the pipeline open choose it, and say why not tensor parallel",
        ordinary.chosen.map { !$0.mode.usesTensorParallelDecode } == true && note(ordinary) == .slower && ordinary.modesReason == nil)
    tensorOnly.modesReason = nil
    let unexplained = try plan(slow, policy: tensorOnly)
    checks.require("TP note: a pipeline left out without a reason is not said to not fit either",
        ClusterPlacementExplanation.deploymentReason(unexplained) == "Tensor parallel: this plan places no pipeline mode.")
}
