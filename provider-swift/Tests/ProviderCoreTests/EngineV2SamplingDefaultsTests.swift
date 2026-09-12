import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

// Artifact sampling defaults (`generation_config.json`) — gate, parse,
// resolve, and the translation rule "request wins, artifact fills omitted
// knobs, legacy stays byte-identical for every other family".

private let nemotronGenerationConfig = """
    {
      "_from_model_config": true,
      "bos_token_id": 1,
      "do_sample": true,
      "eos_token_id": [2, 11],
      "pad_token_id": 0,
      "top_p": 0.95,
      "transformers_version": "4.57.6",
      "temperature": 1.0
    }
    """

private func request(_ json: String) throws -> ChatCompletionRequest {
    try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
}

private let bareRequest = #"{"model":"m","messages":[{"role":"user","content":"hi"}]}"#

@Suite("Artifact sampling defaults")
struct EngineV2SamplingDefaultsTests {

    // MARK: gate

    @Test func gateAdmitsOnlyTheQualifiedNemotronListing() {
        for id in [
            EngineV2SupportedModels.nemotron35LightningMTPModelID,
            EngineV2SupportedModels.nemotron35LightningModelID,
            EngineV2SupportedModels.nemotron35LightningRegistryModelID,
        ] {
            #expect(EngineV2SamplingDefaults.honorsArtifactDefaults(modelId: id, modelType: "nemotron_h"))
            #expect(EngineV2SamplingDefaults.honorsArtifactDefaults(modelId: id, modelType: " Nemotron_H\n"))
        }
        // Same model_type, different (unqualified) listing — Nano and Lightning share nemotron_h.
        #expect(!EngineV2SamplingDefaults.honorsArtifactDefaults(
            modelId: "nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B", modelType: "nemotron_h"))
        // Qualified listing id but a different model_type must not be admitted.
        #expect(!EngineV2SamplingDefaults.honorsArtifactDefaults(
            modelId: EngineV2SupportedModels.nemotron35LightningMTPModelID, modelType: "qwen3"))
        #expect(!EngineV2SamplingDefaults.honorsArtifactDefaults(
            modelId: EngineV2SupportedModels.nemotron35LightningMTPModelID, modelType: nil))
        // Other families stay legacy regardless of their own generation_config.
        for (id, type) in [
            ("mlx-community/Qwen3-0.6B", "qwen3"),
            ("google/gemma-3-27b-it", "gemma3"),
            ("openai/gpt-oss-20b", "gpt_oss"),
            ("mlx-community/Qwen3.5-397B", "qwen3_5"),
        ] {
            #expect(!EngineV2SamplingDefaults.honorsArtifactDefaults(modelId: id, modelType: type))
        }
    }

    // MARK: parse

    @Test func parseReadsTheNemotronArtifactDefaults() {
        let defaults = EngineV2SamplingDefaults.parse(Data(nemotronGenerationConfig.utf8))
        #expect(defaults.temperature == 1.0)
        #expect(defaults.topP == 0.95)
        #expect(defaults.topK == nil)
        #expect(defaults.repetitionPenalty == nil)
        #expect(!defaults.isLegacy)
    }

    @Test func parseTreatsDoSampleFalseAsLegacyGreedy() {
        let json = #"{"do_sample": false, "temperature": 0.7, "top_p": 0.9, "top_k": 40}"#
        #expect(EngineV2SamplingDefaults.parse(Data(json.utf8)) == .legacy)
    }

    @Test func parseAppliesDeclaredValuesWhenDoSampleIsAbsent() {
        let json = #"{"temperature": 0.7, "top_p": 0.9, "top_k": 40, "repetition_penalty": 1.1}"#
        let defaults = EngineV2SamplingDefaults.parse(Data(json.utf8))
        #expect(defaults.temperature == 0.7)
        #expect(defaults.topP == 0.9)
        #expect(defaults.topK == 40)
        #expect(defaults.repetitionPenalty == 1.1)
    }

    @Test func parseIgnoresOutOfRangeValuesFieldByField() {
        let json = #"{"do_sample": true, "temperature": -1, "top_p": 0, "top_k": -5, "repetition_penalty": 0}"#
        #expect(EngineV2SamplingDefaults.parse(Data(json.utf8)) == .legacy)
        let mixed = #"{"do_sample": true, "temperature": 1.0, "top_p": 1.5}"#
        let defaults = EngineV2SamplingDefaults.parse(Data(mixed.utf8))
        #expect(defaults.temperature == 1.0)
        #expect(defaults.topP == nil)
    }

    @Test func parseOfUnreadableOrEmptyBodyIsLegacy() {
        #expect(EngineV2SamplingDefaults.parse(Data()) == .legacy)
        #expect(EngineV2SamplingDefaults.parse(Data("not json".utf8)) == .legacy)
        #expect(EngineV2SamplingDefaults.parse(Data("{}".utf8)) == .legacy)
    }

    // MARK: resolve

    @Test func resolveReadsTheCheckpointOnlyWhenAdmitted() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sampling-defaults-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(nemotronGenerationConfig.utf8).write(
            to: directory.appendingPathComponent("generation_config.json"))
        let admitted = EngineV2SamplingDefaults.resolve(
            modelId: EngineV2SupportedModels.nemotron35LightningMTPModelID,
            modelType: "nemotron_h",
            modelDirectory: directory)
        #expect(admitted.temperature == 1.0)
        #expect(admitted.topP == 0.95)
        // Same directory, unadmitted family → legacy, file never consulted.
        #expect(EngineV2SamplingDefaults.resolve(
            modelId: "mlx-community/Qwen3-0.6B", modelType: "qwen3", modelDirectory: directory) == .legacy)
        // Admitted but no directory / no file → legacy.
        #expect(EngineV2SamplingDefaults.resolve(
            modelId: EngineV2SupportedModels.nemotron35LightningMTPModelID,
            modelType: "nemotron_h", modelDirectory: nil) == .legacy)
        #expect(EngineV2SamplingDefaults.resolve(
            modelId: EngineV2SupportedModels.nemotron35LightningMTPModelID,
            modelType: "nemotron_h",
            modelDirectory: directory.appendingPathComponent("missing")) == .legacy)
    }

    // MARK: translation

    @Test func legacyDefaultsReproduceTheHistoricalGreedyTranslationExactly() throws {
        let sampling = EngineV2Translation.samplingParams(from: try request(bareRequest))
        #expect(sampling.temperature == 0.0)
        #expect(sampling.topP == 1.0)
        #expect(sampling.topK == 0)
        #expect(sampling.repetitionPenalty == 1.0)
        #expect(sampling.seed == nil)
        let explicitLegacy = EngineV2Translation.samplingParams(
            from: try request(bareRequest), defaults: .legacy)
        #expect(explicitLegacy.temperature == sampling.temperature)
        #expect(explicitLegacy.topP == sampling.topP)
        #expect(explicitLegacy.topK == sampling.topK)
        #expect(explicitLegacy.repetitionPenalty == sampling.repetitionPenalty)
    }

    @Test func artifactDefaultsFillOnlyOmittedKnobs() throws {
        let defaults = EngineV2SamplingDefaults.parse(Data(nemotronGenerationConfig.utf8))
        let omitted = EngineV2Translation.samplingParams(from: try request(bareRequest), defaults: defaults)
        #expect(omitted.temperature == 1.0)
        #expect(omitted.topP == 0.95)
        #expect(omitted.topK == 0)
        #expect(omitted.repetitionPenalty == 1.0)
        #expect(omitted.seed == nil)
    }

    @Test func explicitRequestValuesAlwaysWin() throws {
        let defaults = EngineV2SamplingDefaults.parse(Data(nemotronGenerationConfig.utf8))
        let greedy = EngineV2Translation.samplingParams(
            from: try request(#"{"model":"m","messages":[],"temperature":0}"#), defaults: defaults)
        #expect(greedy.temperature == 0.0)
        #expect(greedy.topP == 0.95)
        let pinned = EngineV2Translation.samplingParams(
            from: try request(#"{"model":"m","messages":[],"temperature":0.3,"top_p":0.5,"top_k":7,"repetition_penalty":1.2,"seed":4242}"#),
            defaults: defaults)
        #expect(pinned.temperature == 0.3)
        #expect(pinned.topP == 0.5)
        #expect(pinned.topK == 7)
        #expect(pinned.repetitionPenalty == 1.2)
        #expect(pinned.seed == 4242)
    }

    @Test func cbv2RequestThreadsTheDefaults() throws {
        let defaults = EngineV2SamplingDefaults.parse(Data(nemotronGenerationConfig.utf8))
        let translated = EngineV2Translation.cbv2Request(
            id: CBv2RequestID(0), promptTokens: [1, 2, 3], request: try request(bareRequest),
            defaultMaxTokens: 16, stopTokenIds: [2], samplingDefaults: defaults)
        #expect(translated.sampling.temperature == 1.0)
        #expect(translated.sampling.topP == 0.95)
        #expect(translated.maxTokens == 16)
        let legacy = EngineV2Translation.cbv2Request(
            id: CBv2RequestID(0), promptTokens: [1, 2, 3], request: try request(bareRequest),
            defaultMaxTokens: 16, stopTokenIds: [2])
        #expect(legacy.sampling.temperature == 0.0)
        #expect(legacy.sampling.topP == 1.0)
    }
}
