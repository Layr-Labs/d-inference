import Foundation

/// A fixed tiny fixture matrix is deliberately separate from registered-model
/// execution admission and all earlier short-prompt checks.
func validateQwenLayerStageProfiledCheckOptions(_ options: Options) throws {
    guard options.mode == .qwenLayerStageProfiledCheck, options.synthetic,
          options.syntheticProfile == "tiny", options.syntheticDType == "float32", options.seed == 7,
          options.modelDirectory == nil, options.expectedArtifactAggregateSHA256 == nil,
          !options.localCorrectness, options.tokensFile == nil, options.teacherTokensFile == nil,
          options.logitsFile == nil, options.transport == .jaccl, options.partition == .ffn,
          options.executionPath == .cbv2Contiguous, options.attentionOutputPrecision == .native,
          options.ffnOutputPrecision == .native, options.ffnBranchPrecision == .native,
          !options.hasRoutingDiagnostic, !options.gemmaDiagnostic, options.gemmaBoundaryFile == nil,
          options.epoch == nil, options.stagePrefillPolicy == nil, options.stageLogitsDType == nil,
          options.soloReferenceFile == nil, options.soloReferenceSHA256 == nil,
          options.soloBaselineEvidenceSHA256 == nil,
          options.promptCount == 8192, options.chunkSize == 512, options.decodeCount == 1,
          options.repeats == 1, options.warmups == 0, (1...180).contains(options.timeoutSeconds) else {
        throw ProbeError("qwen-layer-stage-profiled-check requires the fixed tiny long-prefill matrix, native CBv2, 8192/512/1, one run, zero warmups, seed7, timeout<=180 and no external inputs or other diagnostics")
    }
}

func checkQwenLayerStageProfiledCheckAdmission() throws {
    let basic = ["--mode", "qwen-layer-stage-profiled-check", "--synthetic",
        "--execution-path", "cbv2-contiguous", "--prompt-tokens", "8192", "--chunk-size", "512",
        "--decode-tokens", "1", "--repeats", "1", "--warmups", "0", "--timeout-seconds", "180"]
    _ = try Options(arguments: basic)
    var rejected = 0
    func reject(_ args: [String]) throws {
        do { _ = try Options(arguments: args) } catch { rejected += 1; return }
        throw ProbeError("Profiled fixture CLI accepted a changed workload or unsupported mode")
    }
    for (flag, value) in [("--prompt-tokens", "8193"), ("--prompt-tokens", "1025"),
        ("--chunk-size", "513"), ("--chunk-size", "32"), ("--decode-tokens", "2"),
        ("--repeats", "2"), ("--warmups", "1"), ("--timeout-seconds", "181"),
        ("--execution-path", "ordinary")] {
        var args = basic; args[args.firstIndex(of: flag)! + 1] = value; try reject(args)
    }
    for extra in [["--model-dir", "unused"], ["--tokens-file", "unused"],
        ["--teacher-tokens-file", "unused"], ["--logits-file", "unused"],
        ["--artifact-aggregate-sha256", String(repeating: "a", count: 64)], ["--local-correctness"],
        ["--seed", "8"], ["--synthetic-dtype", "bfloat16"], ["--synthetic-profile", "qwen9-heads"],
        ["--transport", "loopback-test"], ["--partition", "full"],
        ["--attention-output-precision", "float32"], ["--ffn-output-precision", "float32"],
        ["--ffn-branch-precision", "float32"], ["--routing-file", "unused"],
        ["--routing-replay-file", "unused"], ["--gemma-diagnostic"], ["--gemma-boundary-file", "unused"],
        ["--epoch", String(repeating: "a", count: 32)],
        ["--stage-prefill-policy", "serial_v1"], ["--stage-logits-dtype", "bfloat16"],
        ["--solo-reference-file", "unused"], ["--solo-reference-sha256", String(repeating: "a", count: 64)],
        ["--solo-baseline-evidence-sha256", String(repeating: "a", count: 64)]] {
        try reject(basic + extra)
    }
    try reject(basic.filter { $0 != "--synthetic" } + ["--model-dir", "unused"])
    for mode in ["qwen-layer-stage-check", "qwen-layer-stage-compare", "qwen-layer-stage-prefill-check",
        "qwen-layer-stage-rank-check", "qwen-layer-stage-lookahead-check", "qwen-layer-stage-prefill-rank-check",
        "qwen-layer-stage-solo-prefill-check"] {
        var args = basic; args[1] = mode; try reject(args)
    }
    struct Result: Encodable {
        let kind = "qwen_layer_stage_profiled_check_admission", cpuOnly = true
        let acceptedFixtures = 1
        let rejectedFixtures: Int
    }
    try emitJSON(Result(rejectedFixtures: rejected))
}
