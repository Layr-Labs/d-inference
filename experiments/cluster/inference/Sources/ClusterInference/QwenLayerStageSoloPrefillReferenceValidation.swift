import Foundation

extension QwenLayerStageSoloPrefillReference {
    /// Recheck the typed request before timing; wire/reference contents never
    /// replace the caller's already admitted prompt IDs or full-model geometry.
    func requireRequest(_ actual: QwenLayerStageRecordedRequest, plan: QwenLayerStagePlan) throws {
        let d = descriptor, r = d.request, source = d.source
        guard d.schemaVersion == 1, d.kind == Self.kind,
              (1...128).contains(actual.request.promptCount), (1...32).contains(actual.request.chunkSize),
              actual.request.outputCount == 1, actual.teacherTokenIDs.isEmpty,
              (1...128).contains(actual.steps.count), actual.steps.allSatisfy({ $0.frame.phase == .prefill }),
              actual.steps.last?.committedTokens == actual.request.promptCount,
              r.promptCount == actual.request.promptCount, r.chunkSize == actual.request.chunkSize,
              r.outputCount == 1, r.vocabularySize == actual.vocabularySize,
              r.promptTokenIDsSHA256 == sha256(Data(actual.promptTokenIDs.map(String.init).joined(separator: ",").utf8)),
              r.finalFrame == actual.steps.last?.frame, r.finalFrame.finalPromptChunk,
              r.committedTokens == actual.request.promptCount,
              r.baselineRequestFingerprint != actual.request.fingerprint,
              r.baselineRecordedRequestFingerprint != actual.fingerprint,
              source.sourceConfigurationSHA256 == sha256(plan.originalConfiguration),
              source.planSHA256 == plan.fingerprint, source.layerCount == plan.layers,
              source.vocabularySize == actual.vocabularySize,
              (1...262_144).contains(source.vocabularySize),
              (1...(6 * 1024 * 1024 * 1024)).contains(source.sourceModelTensorBytes),
              [fileSHA256, d.baselineEvidenceFingerprint, source.artifactAggregateSHA256,
               source.sourceConfigurationSHA256, source.sourceParameterLayoutSHA256, source.planSHA256,
               r.baselineRequestFingerprint, r.baselineRecordedRequestFingerprint, r.promptTokenIDsSHA256,
               d.finalState.fingerprint, d.finalLogits.logicalBytesSHA256].allSatisfy(qwenStageWireIsSHA256),
              ["float16", "bfloat16", "float32"].contains(source.embeddingActivationDType),
              d.selection.policy == Self.selectionPolicy, d.selection.allLogitsFinite,
              (0..<actual.vocabularySize).contains(d.selection.tokenID),
              (1...actual.vocabularySize).contains(d.selection.maximumTieCount) else {
            throw ProbeError("Solo reference differs from the fresh bounded request, source plan or selection policy")
        }
        let logitBytes = try qwenStageWireElementBytes(d.finalLogits.dtype)
        guard d.finalLogits.shape == [1, actual.vocabularySize],
              d.finalLogits.byteCount == actual.vocabularySize * logitBytes else {
            throw ProbeError("Solo reference final logit metadata differs from its native vocabulary row")
        }
        try validateReferenceState(plan: plan)
    }

    private func validateReferenceState(plan: QwenLayerStagePlan) throws {
        let d = descriptor, state = d.finalState, frontier = d.request.committedTokens
        guard let root = try JSONSerialization.jsonObject(with: plan.originalConfiguration) as? [String: Any] else {
            throw ProbeError("Solo reference source configuration is not an object")
        }
        let text = root["text_config"] as? [String: Any] ?? root
        func n(_ key: String, limit: Int) throws -> Int {
            try QwenStageMetadata.integer(text, key, limit: limit)
        }
        func product(_ values: [Int]) throws -> Int {
            var result = 1
            for value in values {
                let next = result.multipliedReportingOverflow(by: value)
                guard value >= 0, !next.overflow else { throw ProbeError("Solo reference geometry product overflows") }
                result = next.partialValue
            }
            return result
        }
        // Same limits as QwenStageMetadata.validate, independently checked by
        // this CPU parser before it derives even an expected shape.
        let heads = try n("num_key_value_heads", limit: 128), head = try n("head_dim", limit: 512)
        let keyHeads = try n("linear_num_key_heads", limit: 128), valueHeads = try n("linear_num_value_heads", limit: 128)
        let keyDim = try n("linear_key_head_dim", limit: 512), valueDim = try n("linear_value_head_dim", limit: 512)
        let kernel = try n("linear_conv_kernel_dim", limit: 16)
        let keyChannels = try product([2, keyHeads, keyDim]), valueChannels = try product([valueHeads, valueDim])
        let channelSum = keyChannels.addingReportingOverflow(valueChannels)
        guard !channelSum.overflow else { throw ProbeError("Solo reference convolution channel count overflows") }
        let native = d.source.embeddingActivationDType
        var expected: [String: ([Int], String)] = [:]
        for layer in plan.stages.flatMap(\.layers) {
            switch layer.kind {
            case "full_attention":
                expected["\(layer.globalIndex)|kv.keys"] = ([1, heads, frontier, head], native)
                expected["\(layer.globalIndex)|kv.values"] = ([1, heads, frontier, head], native)
                expected["\(layer.globalIndex)|kv.position_offsets"] = ([1], "int32")
            case "linear_attention":
                expected["\(layer.globalIndex)|conv"] = ([1, kernel - 1, channelSum.partialValue], native)
                expected["\(layer.globalIndex)|ssm"] = ([1, valueHeads, valueDim, keyDim], "float32")
            default: throw ProbeError("Solo reference has an unsupported layer policy")
            }
        }
        guard state.committedTokens == frontier, state.entries.count <= 384,
              state.entries.count == expected.count, Set(state.entries.map(\.key)) == Set(expected.keys),
              state.entries == state.entries.sorted(by: { ($0.globalLayerIndex, $0.component) < ($1.globalLayerIndex, $1.component) }) else {
            throw ProbeError("Solo reference state is incomplete, duplicated, unordered or at a different frontier")
        }
        var total = 0
        for entry in state.entries {
            let geometry = expected[entry.key]!
            guard entry.shape == geometry.0, entry.dtype == geometry.1, qwenStageWireIsSHA256(entry.sha256) else {
                throw ProbeError("Solo reference state geometry differs at \(entry.key)")
            }
            let elementBytes: Int
            if entry.dtype == "int32" { elementBytes = 4 }
            else { elementBytes = try qwenStageWireElementBytes(entry.dtype) }
            let bytes = try product([elementBytes] + entry.shape)
            let sum = total.addingReportingOverflow(bytes)
            guard entry.byteCount == bytes, !sum.overflow else { throw ProbeError("Solo reference state byte accounting differs") }
            total = sum.partialValue
        }
        let digest = sha256(Data((["cbv2-owned-state-v1", "tokens=\(frontier)"]
            + state.entries.map(\.identity)).joined(separator: "\n").utf8))
        guard total == state.logicalByteCount, total <= 512 * 1024 * 1024, digest == state.fingerprint else {
            throw ProbeError("Solo reference state fingerprint or bounded logical byte total differs")
        }
    }

    func requireFinalState(_ actual: QwenRecordedState) throws {
        let entries = actual.entries.map { StateEntry(globalLayerIndex: $0.globalLayerIndex,
            component: $0.component, shape: $0.shape, dtype: $0.dtype, byteCount: $0.byteCount, sha256: $0.sha256) }
        guard descriptor.finalState == State(committedTokens: actual.committedTokens, entries: entries,
            logicalByteCount: actual.logicalByteCount, fingerprint: actual.fingerprint) else {
            throw ProbeError("Solo final state metadata or native-byte digests differ from the pinned reference")
        }
    }
}
