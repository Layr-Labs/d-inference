import Foundation

/// No weights or caller-supplied geometry: this mode exercises a fixed bounded
/// transfer matrix. The fresh cohort epoch is also the request UUID on the wire.
func validateStagePointToPointOptions(_ options: Options) throws {
    guard options.mode == .stageP2PCheck, options.synthetic,
        options.transport == .loopbackTest, options.modelDirectory == nil,
        options.syntheticProfile == "tiny", options.syntheticDType == "float32", options.seed == 7,
        options.partition == .ffn, options.executionPath == .ordinary,
        options.attentionOutputPrecision == .native, options.ffnOutputPrecision == .native,
        options.ffnBranchPrecision == .native, !options.localCorrectness,
        options.expectedArtifactAggregateSHA256 == nil, options.tokensFile == nil,
        options.teacherTokensFile == nil, options.logitsFile == nil,
        !options.hasRoutingDiagnostic, !options.gemmaDiagnostic, options.gemmaBoundaryFile == nil,
        options.promptCount == 128, options.chunkSize == 128, options.decodeCount == 16,
        options.repeats == 3, options.warmups == 1, (1...60).contains(options.timeoutSeconds),
        let epoch = options.epoch, epoch.count == 32,
        epoch.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
        throw ProbeError("stage-p2p-check requires --synthetic, explicit loopback-test, a fresh --epoch HEX32, timeout<=60 and no model inputs, arithmetic overrides or benchmark options")
    }
}

func checkStagePointToPointAdmission() throws {
    let basic = ["--mode", "stage-p2p-check", "--synthetic", "--transport", "loopback-test",
        "--epoch", String(repeating: "a", count: 32), "--timeout-seconds", "60"]
    _ = try Options(arguments: basic)
    var rejected = 0
    func reject(_ arguments: [String]) throws {
        do { _ = try Options(arguments: arguments) } catch { rejected += 1; return }
        throw ProbeError("Point-to-point admission accepted incompatible inputs")
    }
    for extra in [["--transport", "jaccl"], ["--timeout-seconds", "61"], ["--epoch", "bad"],
        ["--model-dir", "unused"], ["--tokens-file", "unused"], ["--teacher-tokens-file", "unused"],
        ["--logits-file", "unused"], ["--local-correctness"], ["--seed", "8"],
        ["--synthetic-dtype", "bfloat16"], ["--synthetic-profile", "qwen9-heads"],
        ["--partition", "full"], ["--execution-path", "cbv2-contiguous"],
        ["--prompt-tokens", "65"], ["--chunk-size", "32"], ["--decode-tokens", "4"],
        ["--repeats", "1"], ["--warmups", "0"], ["--attention-output-precision", "float32"],
        ["--ffn-output-precision", "float32"], ["--ffn-branch-precision", "float32"],
        ["--routing-file", "unused"], ["--routing-replay-file", "unused"],
        ["--gemma-diagnostic"], ["--gemma-boundary-file", "unused"],
        ["--artifact-aggregate-sha256", String(repeating: "a", count: 64)]] {
        try reject(basic + extra)
    }
    try reject(Array(basic.prefix(5)) + Array(basic.suffix(2)))
    try reject(basic.filter { $0 != "--synthetic" } + ["--model-dir", "unused"])
    struct Result: Encodable {
        let kind = "stage_p2p_check_admission"
        let cpuOnly = true
        let rejectedFixtures: Int
    }
    try emitJSON(Result(rejectedFixtures: rejected))
}
