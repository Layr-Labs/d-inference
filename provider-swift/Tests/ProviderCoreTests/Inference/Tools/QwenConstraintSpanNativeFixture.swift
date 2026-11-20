// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import ProviderCore

// Observe the public assistant contract while forwarding every operation to
// the real native head. Array values are read only after the stream finishes.
final class ProviderObservedQwenAssistant: CBv2MTPRequestStatefulDrafter {
    let native: Qwen35InlineMTPAssistant
    private(set) var starts: [(token: MLXArray, history: Int)] = []
    private var rounds: Set<ObjectIdentifier> = []

    init(_ native: Qwen35InlineMTPAssistant) { self.native = native }
    var mtpTargetIdentity: ObjectIdentifier? { native.mtpTargetIdentity }
    var requiredVerificationMode: CBv2MTPVerificationMode? { native.requiredVerificationMode }
    var maximumDraftTokens: Int? { native.maximumDraftTokens }
    var maximumSpeculativeBatch: Int? { native.maximumSpeculativeBatch }
    var supportsTargetPrefixAcceptance: Bool { native.supportsTargetPrefixAcceptance }
    var supportsEarlyDraftSubmission: Bool { native.supportsEarlyDraftSubmission }
    var prefersBatchedRectangularAttention: Bool { native.prefersBatchedRectangularAttention }
    var commitsAcceptedPrefixPerRow: Bool { native.commitsAcceptedPrefixPerRow }
    var supportsOrdinaryDecodeHistory: Bool { native.supportsOrdinaryDecodeHistory }
    var requiresCommittedObservationFence: Bool { native.requiresCommittedObservationFence }
    var draftShortlistSize: Int? { native.draftShortlistSize }
    var submitsEveryDraftStepEarly: Bool { native.submitsEveryDraftStepEarly }
    var requestStateBytesPerToken: Int { native.requestStateBytesPerToken }
    var requestStateTokenGranularity: Int { native.requestStateTokenGranularity }
    var requestStateTokenAllocationPadding: Int { native.requestStateTokenAllocationPadding }
    var requestStateAllocationSpecs: [CBv2AuxiliaryAllocationSpec]? {
        native.requestStateAllocationSpecs
    }

    func prepare(rows: [CBv2MTPRowCapture]) -> CBv2MTPPreparedCapture {
        native.prepare(rows: rows)
    }

    func draftStep(tokens: MLXArray, hidden: MLXArray, prepared: CBv2MTPPreparedCapture)
        -> (tokens: MLXArray, hidden: MLXArray)
    {
        native.draftStep(tokens: tokens, hidden: hidden, prepared: prepared)
    }

    func makeRequestState() -> any CBv2MTPRequestState { native.makeRequestState() }
    func configureRequestState(_ state: any CBv2MTPRequestState, maximumSequenceLength: Int)
        throws
    {
        try native.configureRequestState(state, maximumSequenceLength: maximumSequenceLength)
    }

    func observeCommittedTarget(
        _ observation: CBv2MTPCommittedTargetObservation, requestState: any CBv2MTPRequestState
    ) {
        native.observeCommittedTarget(observation, requestState: requestState)
    }

    func draftStep(
        tokens: MLXArray, hidden: MLXArray, shortlist: MLXArray?,
        requestState: any CBv2MTPRequestState
    ) -> (tokens: MLXArray, hidden: MLXArray) {
        if rounds.insert(ObjectIdentifier(requestState)).inserted {
            starts.append((tokens, requestState.committedInputCount))
        }
        return native.draftStep(
            tokens: tokens, hidden: hidden, shortlist: shortlist, requestState: requestState)
    }

    func evaluationTargets(for state: any CBv2MTPRequestState) -> [MLXArray] {
        native.evaluationTargets(for: state)
    }

    func requestStateDidFinishEvaluation(_ state: any CBv2MTPRequestState) throws {
        try native.requestStateDidFinishEvaluation(state)
    }

    func finalizeRound(
        requestState: any CBv2MTPRequestState, confirmedInputTokens: Int,
        committedDraftTokens: MLXArray, committedTargetHidden: MLXArray
    ) {
        native.finalizeRound(
            requestState: requestState, confirmedInputTokens: confirmedInputTokens,
            committedDraftTokens: committedDraftTokens, committedTargetHidden: committedTargetHidden
        )
        rounds.remove(ObjectIdentifier(requestState))
    }

    func discardRound(requestState: any CBv2MTPRequestState) {
        native.discardRound(requestState: requestState)
        rounds.remove(ObjectIdentifier(requestState))
    }

    func releaseRequestState(_ state: any CBv2MTPRequestState) {
        native.releaseRequestState(state)
        rounds.remove(ObjectIdentifier(state))
    }
}

// Shared deterministic input for the two native model fixtures, not an output
// oracle. Stream expectations remain independent literal strings and token IDs.
func providerSpanSuccessorWeights(path: [Int], repeating tokenToRepeat: Int? = nil)
    -> (embedding: [Float], head: [Float]) {
    let width = 64, vocabularySize = 248320
    precondition(path.count < 64 && path.allSatisfy { (0..<vocabularySize).contains($0) })
    if let tokenToRepeat { precondition(path.contains(tokenToRepeat)) }
    var embedding = [Float](repeating: 0, count: vocabularySize * width)
    var head = embedding
    for (index, token) in path.enumerated() {
        for column in 0..<width {
            let value: Float = (tokenToRepeat == nil ? index : 0) & (1 << (column % 6)) == 0 ? -0.25 : 0.25
            embedding[token * width + column] = value
            if let tokenToRepeat {
                head[tokenToRepeat * width + column] = value
            } else if index + 1 < path.count {
                head[path[index + 1] * width + column] = value
            }
        }
    }
    return (embedding, head)
}

// A tiny real hybrid target and inline head loaded through public weights.
// The final projections are zero, leaving a wide-margin successor code.
func makeProviderQwenSpanFixture(outputTokens: [Int], promptToken: Int, stopToken: Int,
                                 repeatsSingleToken: Bool = false) throws -> (Qwen35TextModel, Qwen35InlineMTPAssistant) {
    let json = Data(
        #"""
        {"model_type":"qwen3_5_moe",
         "mtplx_mtp":{"included":true,"prefix":"mtp.","block_size":3},
         "mtplx_mtp_quantization":{},
         "text_config":{"model_type":"qwen3_5_moe_text","hidden_size":64,
          "num_hidden_layers":4,"intermediate_size":64,"num_attention_heads":2,
          "num_key_value_heads":1,"head_dim":64,"linear_num_value_heads":1,
          "linear_num_key_heads":1,"linear_key_head_dim":64,"linear_value_head_dim":64,
          "linear_conv_kernel_dim":4,"full_attention_interval":2,"vocab_size":248320,
          "num_experts":0,"num_experts_per_tok":0,"moe_intermediate_size":32,
          "shared_expert_intermediate_size":32,"norm_topk_prob":true,
          "mtp_num_hidden_layers":1,"tie_word_embeddings":false}}
        """#.utf8)
    let object = try JSONSerialization.jsonObject(with: json) as! [String: Any]
    let configuration = try JSONDecoder().decode(
        Qwen35TextConfiguration.self,
        from: JSONSerialization.data(withJSONObject: object["text_config"]!))
    let target = Qwen35TextModel(configuration)
    let path = [promptToken] + outputTokens + [stopToken]
    precondition(!repeatsSingleToken || outputTokens.count == 1)
    let (code, head) = providerSpanSuccessorWeights(path: path,
        repeating: repeatsSingleToken ? outputTokens[0] : nil)
    var parameters = Dictionary(uniqueKeysWithValues: target.parameters().flattened())
    for (key, value) in parameters {
        parameters[key] = value.asType(.bfloat16)
        if key.hasSuffix(".self_attn.o_proj.weight")
            || key.hasSuffix(".linear_attn.out_proj.weight")
            || key.hasSuffix(".mlp.down_proj.weight")
        {
            parameters[key] = MLXArray.zeros(value.shape, dtype: .bfloat16)
        }
    }
    parameters["model.embed_tokens.weight"] = MLXArray(code, [248320, 64]).asType(.bfloat16)
    parameters["lm_head.weight"] = MLXArray(head, [248320, 64]).asType(.bfloat16)
    target.update(parameters: ModuleParameters.unflattened(parameters))

    // The head's full-attention block shares the public checkpoint layout.
    var weights: [String: MLXArray] = Dictionary(
        uniqueKeysWithValues: parameters.compactMap { key, value in
            key.hasPrefix("model.layers.1.")
                ? ("mtp.layers.0." + String(key.dropFirst("model.layers.1.".count)), value) : nil
        })
    for key in ["pre_fc_norm_hidden", "pre_fc_norm_embedding", "norm"] {
        weights["mtp.\(key).weight"] = MLXArray.ones([64], dtype: .bfloat16)
    }
    var fusion = [Float](repeating: 0, count: 64 * 128)
    for index in 0 ..< 64 { fusion[index * 128 + index] = 1 }
    weights["mtp.fc.weight"] = MLXArray(fusion, [64, 128]).asType(.bfloat16)
    quantize(model: target, groupSize: 32, bits: 4) { _, module in module is Embedding }
    eval(target)

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("provider-qwen-span-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try json.write(to: directory.appendingPathComponent("config.json"))
    let shard = "model-00001-of-00001.safetensors"
    try save(arrays: weights, url: directory.appendingPathComponent(shard))
    try JSONSerialization.data(withJSONObject: [
        "weight_map": Dictionary(uniqueKeysWithValues: weights.keys.map { ($0, shard) })
    ]).write(to: directory.appendingPathComponent("model.safetensors.index.json"))
    let assistant = try Qwen35InlineMTPAssistant.load(
        from: directory, target: target, verificationMode: .serialTarget)
    return (target, assistant)
}


func makeProviderQwenSpanEngine(target: Qwen35TextModel, native: Qwen35InlineMTPAssistant,
                                tokenizer: any MLXLMCommon.Tokenizer, enabled: Bool)
    throws -> (EngineV2, ProviderObservedQwenAssistant) {
    let assistant = ProviderObservedQwenAssistant(native)
    let kinds = target.cbv2LayerKinds
    let adapter = CBv2SteppableLanguageModelAdapter(target)
    let observed = try CBv2NativeKVTypeProbe.run(model: adapter, layerKinds: kinds,
        caches: target.newCacheV2 { CBv2LayerCache(layerIndex: $0, kind: $1) })
    let backend = try PagedKVBackend(layerKinds: kinds,
        config: .init(capacityBytes: 64 << 20, maxPrefillChunk: 32,
                      nominalMaxSequenceLength: 8192, segmentSizeBytes: 64 << 10,
                      layerDTypes: observed.layerDTypes))
    let storage = backend.makeLayerCaches()
    let indices = Dictionary(uniqueKeysWithValues: kinds.enumerated().map {
        ($0.element.modelLayerIndex ?? $0.offset, $0.offset)
    })
    let engine = EngineV2(model: adapter, layerKinds: kinds, backend: backend,
        cacheProvider: CBv2LayerCacheBank(caches: target.newCacheV2 { index, _ in storage[indices[index]!] }),
        detokenizerFactory: CBv2TextDetokenizerFactory(tokenizer: tokenizer),
        schedulerConfig: .init(maxConcurrentRequests: 1, maxBatchedTokensPerStep: 32,
                              prefillChunkSize: 32, maxWaiting: 4, enablePrefixCache: false),
        admissionConfig: .init(watermarkFraction: 0), mtpDrafter: assistant,
        mtpConfig: .init(enabled: true, maxDraftTokens: 2, fixedDraftTokens: 2,
                         verificationMode: .serialTarget, freeSpanSpeculation: enabled))
    return (engine, assistant)
}
