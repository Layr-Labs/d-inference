import Foundation

/// This diagnostic owns and deletes only its generated tiny checkpoints. No
/// external checkpoint, token file, transport or arithmetic override is admitted.
func validateQwenLayerStageCheckOptions(_ options: Options) throws {
    guard options.mode == .qwenLayerStageCheck, options.synthetic,
        options.syntheticProfile == "tiny", options.syntheticDType == "float32", options.seed == 7,
        options.modelDirectory == nil, !options.localCorrectness,
        options.expectedArtifactAggregateSHA256 == nil, options.tokensFile == nil,
        options.teacherTokensFile == nil, options.logitsFile == nil,
        options.transport == .jaccl, options.partition == .ffn,
        options.executionPath == .cbv2Contiguous, options.attentionOutputPrecision == .native,
        options.ffnOutputPrecision == .native, options.ffnBranchPrecision == .native,
        !options.hasRoutingDiagnostic, !options.gemmaDiagnostic, options.gemmaBoundaryFile == nil,
        options.epoch == nil, options.repeats == 1, options.warmups == 0,
        (1...180).contains(options.timeoutSeconds), (1...128).contains(options.promptCount),
        (1...32).contains(options.chunkSize), (1...4).contains(options.decodeCount) else {
        throw ProbeError("qwen-layer-stage-check requires the fixed seed-7 tiny fixture matrix, native CBv2, prompt<=128, chunk<=32, output<=4, one run, zero warmups, timeout<=180 and no external inputs or other diagnostics")
    }
}

func checkQwenLayerStageCheckAdmission() throws {
    let basic = ["--mode", "qwen-layer-stage-check", "--synthetic", "--execution-path", "cbv2-contiguous",
        "--prompt-tokens", "65", "--chunk-size", "32", "--decode-tokens", "4",
        "--repeats", "1", "--warmups", "0", "--timeout-seconds", "170"]
    _ = try Options(arguments: basic)
    var rejected = 0
    func reject(_ args: [String]) throws {
        do { _ = try Options(arguments: args) } catch { rejected += 1; return }
        throw ProbeError("Layer-stage check admission accepted incompatible or unbounded inputs")
    }
    for (flag, value) in [("--prompt-tokens", "129"), ("--chunk-size", "33"),
        ("--decode-tokens", "5"), ("--repeats", "2"), ("--warmups", "1"),
        ("--timeout-seconds", "181"), ("--execution-path", "ordinary")] {
        var args = basic; args[args.firstIndex(of: flag)! + 1] = value
        try reject(args)
    }
    for extra in [["--model-dir", "unused"], ["--tokens-file", "unused"],
        ["--teacher-tokens-file", "unused"], ["--logits-file", "unused"],
        ["--artifact-aggregate-sha256", String(repeating: "a", count: 64)], ["--local-correctness"],
        ["--seed", "8"], ["--synthetic-dtype", "bfloat16"], ["--synthetic-profile", "qwen9-heads"],
        ["--transport", "loopback-test"], ["--partition", "full"],
        ["--attention-output-precision", "float32"], ["--ffn-output-precision", "float32"],
        ["--ffn-branch-precision", "float32"], ["--routing-file", "unused"],
        ["--routing-replay-file", "unused"], ["--gemma-diagnostic"], ["--gemma-boundary-file", "unused"],
        ["--epoch", String(repeating: "a", count: 32)]] {
        try reject(basic + extra)
    }
    try reject(basic.filter { $0 != "--synthetic" } + ["--model-dir", "unused"])
    struct Result: Encodable {
        let kind = "qwen_layer_stage_check_admission"
        let cpuOnly = true
        let rejectedFixtures: Int
    }
    try emitJSON(Result(rejectedFixtures: rejected))
}
