import Foundation

/// An explicit two-process loopback diagnostic. The long reference's complete
/// model/input/arithmetic bounds remain authoritative; orchestration is separate.
enum QwenLongPrefillRankAdmission {
    static func validateOptions(_ options: Options) throws {
        guard options.mode == .qwenLongPrefillRankCheck, options.transport == .loopbackTest,
              let epoch = options.epoch, options.stagePrefillPolicy != nil,
              options.stageLogitsDType == "bfloat16" else {
            throw ProbeError("Long rank check requires explicit loopback, epoch, scheduling policy and native BF16 logits")
        }
        _ = try QwenLayerStageRankAdmission.requestID(epoch: epoch)
        var reference = options
        reference.mode = .qwenLongPrefillReference
        reference.transport = .jaccl; reference.epoch = nil
        reference.stagePrefillPolicy = nil; reference.stageLogitsDType = nil
        try QwenLongPrefillReferenceCLI.validateOptions(reference)
    }

    static func preflight(_ options: Options,
        arithmetic: QwenLongPrefillArithmeticEnvironment.Receipt
    ) throws -> QwenRegistered9BLongPrefillReferenceAdmission {
        try validateOptions(options)
        let configuration = try BoundedProbeInput.data(
            options.modelDirectory!.appendingPathComponent("config.json"), maximumBytes: 1024 * 1024)
        let prompt = try BoundedProbeInput.data(options.tokensFile!, maximumBytes: 65_536)
        return try .init(configuration: configuration,
            expectedArtifactAggregateSHA256: options.expectedArtifactAggregateSHA256!,
            promptData: prompt, expectedPromptSHA256: options.longPromptSHA256!,
            request: .init(profile: .longPrefill8KV1,
                requestID: QwenLayerStageRankAdmission.requestID(epoch: options.epoch!), batchSize: 1,
                promptCount: 8192, chunkSize: 512, outputCount: 1), arithmetic: arithmetic, stageCut: options.stageCut)
    }
}

func checkQwenLongPrefillRankAdmission() throws {
    let basic = ["--mode", "qwen-long-prefill-rank-check", "--model-dir", "unused",
        "--artifact-aggregate-sha256", String(repeating: "a", count: 64),
        "--tokens-file", "unused", "--long-prompt-sha256", String(repeating: "b", count: 64),
        "--transport", "loopback-test", "--epoch", String(repeating: "c", count: 32),
        "--stage-logits-dtype", "bfloat16", "--execution-path", "cbv2-contiguous",
        "--prompt-tokens", "8192", "--chunk-size", "512", "--decode-tokens", "1",
        "--repeats", "1", "--warmups", "0", "--timeout-seconds", "300"]
    for policy in QwenLayerStagePrefillMeasurementFlow.SchedulingPolicy.allCases {
        _ = try Options(arguments: basic + ["--stage-prefill-policy", policy.rawValue])
    }
    let serial = basic + ["--stage-prefill-policy", "serial_v1"]
    var rejected = 0
    func reject(_ args: [String]) throws {
        do { _ = try Options(arguments: args) } catch { rejected += 1; return }
        throw ProbeError("Long rank CLI admitted changed workload or missing cohort identity")
    }
    for extra in [["--prompt-tokens", "65"], ["--chunk-size", "32"], ["--decode-tokens", "2"],
        ["--repeats", "2"], ["--warmups", "1"], ["--timeout-seconds", "301"],
        ["--transport", "jaccl"], ["--epoch", "bad"], ["--stage-prefill-policy", "unknown"],
        ["--stage-logits-dtype", "float32"], ["--stage-logits-dtype", "float16"],
        ["--long-prompt-sha256", "bad"], ["--teacher-tokens-file", "unused"],
        ["--solo-reference-file", "unused"], ["--local-correctness"], ["--synthetic"],
        ["--execution-path", "ordinary"], ["--mode", "qwen-layer-stage-prefill-rank-check"]] {
        try reject(serial + extra)
    }
    for flag in ["--stage-prefill-policy", "--stage-logits-dtype", "--long-prompt-sha256", "--epoch"] {
        var missing = serial; let index = missing.firstIndex(of: flag)!
        missing.removeSubrange(index...(index + 1)); try reject(missing)
    }
    struct Result: Encodable {
        let kind = "qwen_long_prefill_rank_cli_admission", cpuOnly = true
        let acceptedFixtures = 2
        let rejectedFixtures: Int
    }
    try emitJSON(Result(rejectedFixtures: rejected))
}
