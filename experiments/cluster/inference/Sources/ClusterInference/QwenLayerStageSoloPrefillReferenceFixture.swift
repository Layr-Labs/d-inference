import Foundation

/// Fabricated CPU metadata for codec admission only. No model, native array or
/// real checkpoint byte claim. Reuses existing tiny configuration and timeline.
struct QwenLayerStageSoloPrefillReferenceFixture {
    let plan: QwenLayerStagePlan
    let request: QwenLayerStageRecordedRequest
    let baselineRequest: QwenLayerStageRecordedRequest
    let descriptor: QwenLayerStageSoloPrefillReference.Descriptor
    let data: Data

    init(dtype: String = "bfloat16", promptCount: Int = 65, chunkSize: Int = 32,
         convolutionKernel: Int = 4) throws {
        typealias R = QwenLayerStageSoloPrefillReference
        let wire = try QwenLayerStagePrefillWireCheckFixture(dtype: dtype,
            promptCount: promptCount, chunkSize: chunkSize)
        let baseline = wire.agreement.request
        let request = try QwenLayerStageRecordedRequest(request: .init(
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            promptCount: promptCount, chunkSize: chunkSize, outputCount: 1),
            vocabularySize: baseline.vocabularySize, prompt: baseline.promptTokenIDs, teacher: [])
        let tiny = try syntheticConfiguration(options: Options(arguments: ["--synthetic"]))
        var configuration = try JSONSerialization.jsonObject(with: tiny) as! [String: Any]
        configuration["vocab_size"] = baseline.vocabularySize
        configuration["linear_conv_kernel_dim"] = convolutionKernel
        let config = try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
        let plan = try QwenLayerStagePlan(configuration: config, ranges: [0..<2, 2..<4])
        var entries: [R.StateEntry] = []
        func append(layer: Int, component: String, shape: [Int], dtype: String) throws {
            let elementBytes: Int
            if dtype == "int32" { elementBytes = 4 } else { elementBytes = try qwenStageWireElementBytes(dtype) }
            let count = shape.reduce(elementBytes, *)
            entries.append(.init(globalLayerIndex: layer, component: component, shape: shape,
                dtype: dtype, byteCount: count,
                sha256: sha256(Data("cpu-fixture|\(layer)|\(component)|\(shape)|\(dtype)".utf8))))
        }
        // Independent tiny shapes from SyntheticConfiguration: four layers,
        // interval two, Hk/Hv=2, Dk/Dv=128, attention KV heads2/head64.
        for layer in 0..<4 {
            if layer % 2 == 1 {
                try append(layer: layer, component: "kv.keys", shape: [1, 2, promptCount, 64], dtype: dtype)
                try append(layer: layer, component: "kv.values", shape: [1, 2, promptCount, 64], dtype: dtype)
                try append(layer: layer, component: "kv.position_offsets", shape: [1], dtype: "int32")
            } else {
                try append(layer: layer, component: "conv", shape: [1, convolutionKernel - 1, 768], dtype: dtype)
                try append(layer: layer, component: "ssm", shape: [1, 2, 128, 128], dtype: "float32")
            }
        }
        entries.sort { ($0.globalLayerIndex, $0.component) < ($1.globalLayerIndex, $1.component) }
        let stateSHA = sha256(Data((["cbv2-owned-state-v1", "tokens=\(promptCount)"]
            + entries.map(\.identity)).joined(separator: "\n").utf8))
        let descriptor = R.Descriptor(schemaVersion: 1, kind: R.kind,
            baselineEvidenceFingerprint: String(repeating: "a", count: 64),
            source: .init(artifactAggregateSHA256: String(repeating: "b", count: 64),
                sourceConfigurationSHA256: sha256(config), sourceParameterLayoutSHA256: String(repeating: "c", count: 64),
                planSHA256: plan.fingerprint, bf16ConversionEnabled: false, embeddingActivationDType: dtype,
                sourceModelTensorBytes: 1024, layerCount: 4, vocabularySize: baseline.vocabularySize),
            request: .init(baselineRequestFingerprint: baseline.request.fingerprint,
                baselineRecordedRequestFingerprint: baseline.fingerprint, promptCount: promptCount,
                chunkSize: chunkSize, outputCount: 1, vocabularySize: baseline.vocabularySize,
                promptTokenIDsSHA256: sha256(Data(baseline.promptTokenIDs.map(String.init).joined(separator: ",").utf8)),
                finalFrame: baseline.steps.last!.frame, committedTokens: promptCount),
            finalState: .init(committedTokens: promptCount, entries: entries,
                logicalByteCount: entries.reduce(0) { $0 + $1.byteCount }, fingerprint: stateSHA),
            finalLogits: .init(shape: [1, baseline.vocabularySize], dtype: dtype,
                byteCount: baseline.vocabularySize * (try qwenStageWireElementBytes(dtype)),
                logicalBytesSHA256: String(repeating: "d", count: 64)),
            selection: .init(policy: R.selectionPolicy, tokenID: 7, maximumTieCount: 1, allLogitsFinite: true))
        self.plan = plan; self.request = request; self.baselineRequest = baseline
        self.descriptor = descriptor; self.data = try canonicalJSONData(descriptor)
    }
}
