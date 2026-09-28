import Foundation

/// Reuse the retained admission fixture's exact configuration and synthetic IDs.
/// These are real Options/local-admission constructors, never file preflight.
struct QwenLongPrefillResidentCohortFixture {
    let configuration: Data
    let arithmetic: QwenLongPrefillArithmeticEnvironment.Receipt
    let promptA: Data, promptB: Data

    init() throws {
        configuration = try QwenLongPrefillResidentRankFixture.configuration()
        arithmetic = try QwenLongPrefillArithmeticEnvironment.admit(
            QwenLongPrefillArithmeticEnvironment.requiredValues)
        promptA = try QwenLongPrefillResidentRankFixture.prompt(0)
        promptB = try QwenLongPrefillResidentRankFixture.prompt(1)
    }

    func request(_ index: Int, prompt: Data? = nil, cut: Int? = 12) throws
        -> QwenLongPrefillResidentRankRequest {
        let epoch = try QwenLongPrefillResidentRankFixture.epoch(index)
        let data = prompt ?? promptA
        let spec = try QwenLayerStageProfiledPrefillRequestSpec(profile: .longPrefill8KV1,
            requestID: QwenLayerStageRankAdmission.requestID(epoch: epoch), batchSize: 1,
            promptCount: 8192, chunkSize: 512, outputCount: 1)
        let local = try QwenRegistered9BLongPrefillReferenceAdmission(configuration: configuration,
            expectedArtifactAggregateSHA256: QwenLongPrefillResidentRankFixture.artifactSHA256,
            promptData: data, expectedPromptSHA256: sha256(data), request: spec,
            arithmetic: arithmetic, stageCut: cut)
        return .init(epoch: epoch, local: local)
    }

    func options(_ first: QwenLongPrefillResidentRankRequest, cut: Int? = 12,
                 policy: String = "serial_v1") throws -> Options {
        var arguments = ["--mode", "qwen-long-prefill-rank-check", "--model-dir", "unused-model",
            "--tokens-file", "unused-prompt", "--artifact-aggregate-sha256",
            QwenLongPrefillResidentRankFixture.artifactSHA256,
            "--long-prompt-sha256", first.local.promptFileSHA256, "--epoch", first.epoch,
            "--transport", "loopback-test", "--stage-prefill-policy", policy,
            "--stage-logits-dtype", "bfloat16", "--execution-path", "cbv2-contiguous",
            "--prompt-tokens", "8192", "--chunk-size", "512", "--decode-tokens", "1",
            "--repeats", "1", "--warmups", "0", "--timeout-seconds", "300"]
        if let cut { arguments += ["--stage-cut", String(cut)] }
        return try Options(arguments: arguments)
    }
}
