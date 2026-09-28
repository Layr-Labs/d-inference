import Foundation

/// Pure options and synthetic plan metadata. No files, model, Collective,
/// process environment read, or native request are created by these checks.
func checkQwenLongPrefillStageCutAdmission() throws {
    let common = ["--model-dir", "unused", "--tokens-file", "unused",
        "--artifact-aggregate-sha256", String(repeating: "a", count: 64),
        "--long-prompt-sha256", String(repeating: "b", count: 64),
        "--execution-path", "cbv2-contiguous", "--prompt-tokens", "8192",
        "--chunk-size", "512", "--decode-tokens", "1", "--repeats", "1",
        "--warmups", "0", "--timeout-seconds", "300"]
    let modes: [Options.Mode] = [.qwenLongPrefillReference, .qwenLongPrefillPairCheck, .qwenLongPrefillRankCheck]
    func arguments(_ mode: Options.Mode) -> [String] {
        let rank = mode == .qwenLongPrefillRankCheck ? ["--transport", "loopback-test",
            "--epoch", String(repeating: "c", count: 32), "--stage-prefill-policy", "serial_v1",
            "--stage-logits-dtype", "bfloat16"] : []
        return ["--mode", mode.rawValue] + common + rank
    }
    var accepted = 0, rejected = 0
    func accept(_ mode: Options.Mode, cut: Int?) throws {
        let extra = cut.map { ["--stage-cut", String($0)] } ?? []
        let result = try Options(arguments: arguments(mode) + extra)
        guard result.mode == mode, result.stageCut == cut, result.promptCount == 8192,
              result.chunkSize == 512, result.decodeCount == 1, result.teacherTokensFile == nil else {
            throw ProbeError("Long cut CLI changed mode, selected cut or the fixed request")
        }
        accepted += 1
    }
    func reject(_ label: String, message: String? = nil, _ body: () throws -> Void) throws {
        do { try body() } catch {
            if let message, !String(describing: error).contains(message) {
                throw ProbeError("Long cut rejected \(label) for an unrelated reason: \(error)")
            }
            rejected += 1; return
        }
        throw ProbeError("Long cut admitted " + label)
    }
    for mode in modes {
        try accept(mode, cut: nil); try accept(mode, cut: 12)
        for cut in [Int.min, -1, 0, 1, 5, 29, 32, 128, Int.max] {
            try reject("invalid cut \(cut) for " + mode.rawValue) {
                _ = try Options(arguments: arguments(mode) + ["--stage-cut", String(cut)])
            }
        }
        for extra in [["--prompt-tokens", "65"], ["--chunk-size", "32"],
                      ["--decode-tokens", "2"], ["--timeout-seconds", "301"]] {
            try reject("changed registered request " + mode.rawValue) {
                _ = try Options(arguments: arguments(mode) + ["--stage-cut", "12"] + extra)
            }
        }
    }
    for cut in [4, 8, 16, 20, 24, 28] { try accept(.qwenLongPrefillReference, cut: cut) }
    try accept(.qwenLongPrefillSoloCheck, cut: nil)
    let reference = arguments(.qwenLongPrefillReference)
    for extra in [["--stage-cut", "12.0"], ["--stage-cut", "true"], ["--stage-cut"],
                  ["--stage-cut", "12", "--stage-cut", "16"]] {
        try reject("malformed cut option") { _ = try Options(arguments: reference + extra) }
    }
    let foreign: [Options.Mode] = [.baseline, .ffnTP, .worker, .workerTP, .qwenLayerStageCheck,
        .qwenLayerStageProfiledCheck, .qwenLayerStageLookaheadCheck, .qwenLayerStagePrefillCheck,
        .qwenLayerStagePrefillRankCheck, .qwenLayerStageSoloPrefillCheck, .qwenLongPrefillSoloCheck]
    for mode in foreign {
        try reject("original foreign mode " + mode.rawValue, message: "--stage-cut requires") {
            _ = try Options(arguments: reference + ["--stage-cut", "12", "--mode", mode.rawValue])
        }
    }
    var solo = try Options(arguments: arguments(.qwenLongPrefillSoloCheck)); solo.stageCut = 12
    try reject("direct solo reference clone", message: "Long solo does not admit --stage-cut") {
        _ = try QwenLongPrefillSoloCLI.referenceOptions(solo)
    }
    // These direct preflight calls must reject before trying either unused path.
    // This fixture receipt is source metadata, not an actual process admission.
    let arithmetic = try QwenLongPrefillArithmeticEnvironment.admit(QwenLongPrefillArithmeticEnvironment.requiredValues)
    for mode in modes {
        var changed = try Options(arguments: arguments(mode)); changed.stageCut = 32
        try reject("mutated preflight before IO " + mode.rawValue, message: "Registered long stage cut must be") {
            switch mode {
            case .qwenLongPrefillReference: _ = try QwenLongPrefillReferenceCLI.preflight(changed, arithmetic: arithmetic)
            case .qwenLongPrefillPairCheck: _ = try QwenLongPrefillPairCLI.preflight(changed, arithmetic: arithmetic)
            case .qwenLongPrefillRankCheck: _ = try QwenLongPrefillRankAdmission.preflight(changed, arithmetic: arithmetic)
            default: throw ProbeError("Unexpected fixture mode")
            }
        }
    }
    let options = try Options(arguments: reference)
    let plan = try checkQwenLongPrefillStageCutPlans(configuration: syntheticConfiguration(options: options))
    guard accepted == 13, rejected == 58, plan.accepted == 8, plan.rejected == 14 else {
        throw ProbeError("Long cut pure fixture coverage changed")
    }
    struct Record: Encodable {
        let kind = "qwen_long_prefill_stage_cut_admission_check", cpuOnly = true
        let acceptedFixtures: Int, rejectedFixtures: Int, acceptedPlanFixtures: Int, rejectedPlanFixtures: Int
        let nilBindsHistoricalHalfPlan = true, invalidCutsRejectedBeforeIO = true
        let fixedRequestProfileAndExactStateOwnershipPreserved = true, longSoloCutRejected = true
        let registeredArtifactPreflightExercised = false, collectiveOrModelConstructed = false
        let numericalOrPerformanceQualificationEstablished = false
    }
    try emitJSON(Record(acceptedFixtures: accepted, rejectedFixtures: rejected,
        acceptedPlanFixtures: plan.accepted, rejectedPlanFixtures: plan.rejected))
}
