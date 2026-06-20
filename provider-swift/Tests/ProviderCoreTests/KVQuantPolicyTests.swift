import Foundation
import Testing
@testable import ProviderCore

@Test("KV quant policy classifies supported model aliases")
func kvQuantPolicyClassifiesSupportedModelAliases() {
    #expect(KVQuantPolicy.classify(modelID: "google/gemma-4-26b-it") == .gemma4)
    #expect(KVQuantPolicy.classify(modelID: "gemma4") == .gemma4)
    #expect(KVQuantPolicy.classify(modelID: "gemma-4") == .gemma4)
    #expect(KVQuantPolicy.classify(modelID: "openai/gpt-oss-20b") == .gptOSS)
    #expect(KVQuantPolicy.classify(modelID: "gpt_oss") == .gptOSS)
    #expect(KVQuantPolicy.classify(modelID: "qwen3.5-32b") == .unknown)
}

@Test("KV quant policy maps Apple Silicon generations to candidate modes")
func kvQuantPolicyMapsHardwareCandidateModes() {
    #expect(KVQuantPolicy.candidateMode(for: .m1) == .conservative)
    #expect(KVQuantPolicy.candidateMode(for: .m2) == .conservative)
    #expect(KVQuantPolicy.candidateMode(for: .m3) == .normal)
    #expect(KVQuantPolicy.candidateMode(for: .m4) == .normal)
    #expect(KVQuantPolicy.candidateMode(for: .m5) == .aggressiveCandidate)
    #expect(KVQuantPolicy.candidateMode(for: nil) == .conservative)
}

@Test("Gemma 4 KV quant defaults use live K8V8 g128 policy and preserve unsafe layers")
func gemma4KVQuantDefaultsAreConservative() {
    let policy = KVQuantPolicy(modelID: "gemma-4-26b", chipFamily: .m4)

    #expect(policy.modelFamily == .gemma4)
    #expect(policy.candidateMode == .normal)
    #expect(policy.plan.enabled)
    #expect(policy.plan.layerScope == .fullAndGlobalOnly)
    #expect(policy.plan.tensorTarget == .keysAndValues)
    #expect(policy.plan.keyPrecision == .quantized8Bit)
    #expect(policy.plan.valuePrecision == .quantized8Bit)
    #expect(policy.plan.valueEncoding == .affine8)
    #expect(policy.plan.quantizationStartToken == 0)
    #expect(policy.plan.rotatingSlidingPrecision == .fp16)
    #expect(policy.plan.mtpPolicy == .disabled)
}

@Test("GPT-OSS KV quant defaults use live K8V8 g64 dequant policy")
func gptOSSKVQuantDefaultsRequireSinkAwareness() {
    let policy = KVQuantPolicy(modelID: "gpt_oss", chipFamily: .m5)

    #expect(policy.modelFamily == .gptOSS)
    #expect(policy.candidateMode == .aggressiveCandidate)
    #expect(policy.plan.enabled)
    #expect(policy.plan.layerScope == .fullOnly)
    #expect(policy.plan.tensorTarget == .keysAndValues)
    #expect(policy.plan.keyPrecision == .quantized8Bit)
    #expect(policy.plan.valuePrecision == .quantized8Bit)
    #expect(policy.plan.valueEncoding == .affine8)
    #expect(policy.plan.quantizationStartToken == 0)
    #expect(policy.plan.sinkAware == .required)
    #expect(policy.plan.rotatingSlidingPrecision == .fp16)
}

@Test("Unknown KV quant model policy disables quantization and remains codable")
func unknownKVQuantPolicyDisablesQuantizationAndEncodesReportFields() throws {
    let policy = KVQuantPolicy(modelID: "unknown-model", chipFamily: .m2)

    #expect(policy.modelFamily == .unknown)
    #expect(!policy.plan.enabled)
    #expect(policy.plan.keyPrecision == .fp16)
    #expect(policy.plan.valuePrecision == .fp16)
    #expect(!policy.summary.isEmpty)
    #expect(!policy.reasons.isEmpty)

    let data = try JSONEncoder().encode(policy)
    let json = String(decoding: data, as: UTF8.self)
    #expect(json.contains("policy_version"))
    #expect(json.contains("report_description"))
}
