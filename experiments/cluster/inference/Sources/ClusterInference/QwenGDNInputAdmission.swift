import Foundation

/// One full-model chunk and same-input projection reconstruction; no transport.
enum QwenGDNInputAdmission {
    struct Inputs {
        let configurationData: Data
        let configurationSHA256: String
        let prompt: [Int]
    }

    static func validateOptions(_ options: Options) throws {
        guard options.mode.isGDNDiagnostic,
            options.executionPath == .cbv2Contiguous, options.transport == .jaccl,
            options.partition == .ffn, !options.localCorrectness,
            options.attentionOutputPrecision == .native, options.ffnOutputPrecision == .native,
            options.ffnBranchPrecision == .native,
            (1...32).contains(options.promptCount), options.chunkSize == options.promptCount,
            options.decodeCount == 1, options.repeats == 1, options.warmups == 0,
            (1...180).contains(options.timeoutSeconds), options.epoch == nil,
            options.teacherTokensFile == nil, options.logitsFile == nil,
            !options.hasRoutingDiagnostic, !options.gemmaDiagnostic, options.gemmaBoundaryFile == nil
        else { throw ProbeError("GDN diagnostics require one native CBv2 chunk of 1...32 tokens, one output/run, zero warmups, timeout<=180 and no transport or other diagnostics") }
        if options.synthetic {
            guard ["tiny", "qwen9-heads", "qwen27-heads"].contains(options.syntheticProfile),
                options.expectedArtifactAggregateSHA256 == nil else {
                throw ProbeError("GDN input synthetic diagnostics require a dense fixture without an artifact pin")
            }
        } else {
            guard options.modelDirectory != nil, options.tokensFile != nil,
                let expected = options.expectedArtifactAggregateSHA256, expected.utf8.count == 64,
                expected.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw ProbeError("Real GDN input diagnostics require a model, actual token file and lowercase artifact aggregate SHA256")
            }
        }
    }

    static func preflight(_ options: Options) throws -> Inputs {
        try validateOptions(options)
        let data = try options.synthetic ? syntheticConfiguration(options: options)
            : BoundedProbeInput.data(options.modelDirectory!.appendingPathComponent("config.json"), maximumBytes: 1_048_576)
        let text = try validateConfiguration(data, options: options)
        let vocabulary = BoundedProbeInput.integer(text["vocab_size"])!
        let prompt = try options.tokensFile.map { try BoundedProbeInput.tokenIDs($0) }
            ?? (0..<options.promptCount).map {
                3 + (($0 * 17 + Int(options.seed % UInt64(vocabulary - 3))) % (vocabulary - 3))
            }
        guard prompt.count == options.promptCount,
            prompt.allSatisfy({ (0..<vocabulary).contains($0) }) else {
            throw ProbeError("GDN diagnostic actual prompt differs from the admitted chunk or vocabulary")
        }
        return Inputs(configurationData: data, configurationSHA256: sha256(data), prompt: prompt)
    }

    @discardableResult
    static func validateConfiguration(_ data: Data, options: Options) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = root["model_type"] as? String, ["qwen3_5", "qwen3_5_text"].contains(type) else {
            throw ProbeError("GDN diagnostic requires dense Qwen metadata")
        }
        let text: [String: Any]
        if let nested = root["text_config"] {
            guard let object = nested as? [String: Any] else { throw ProbeError("GDN text_config must be an object") }
            text = object
        } else { text = root }
        guard text["model_type"] == nil || text["model_type"] as? String == "qwen3_5_text",
            text["num_experts"] == nil || BoundedProbeInput.integer(text["num_experts"]) == 0 else {
            throw ProbeError("GDN input diagnostic excludes sparse and unknown nested model types")
        }
        let limits = ["hidden_size": 8192, "num_hidden_layers": 128,
            "intermediate_size": 32768, "num_attention_heads": 128, "num_key_value_heads": 128,
            "head_dim": 512, "linear_num_key_heads": 128, "linear_num_value_heads": 128,
            "linear_key_head_dim": 512, "linear_value_head_dim": 512,
            "linear_conv_kernel_dim": 16, "full_attention_interval": 128, "vocab_size": 262144]
        for (key, upper) in limits {
            guard let value = BoundedProbeInput.integer(text[key]), (1...upper).contains(value) else {
                throw ProbeError("GDN diagnostic dimension is missing or exceeds its bound: \(key)")
            }
        }
        guard BoundedProbeInput.integer(text["vocab_size"])! > 3,
            let context = BoundedProbeInput.integer(text["max_position_embeddings"]),
            context > options.promptCount,
            BoundedProbeInput.integer(text["full_attention_interval"])! > 1 else {
            throw ProbeError("GDN diagnostic requires vocabulary, context and a first recurrent layer")
        }
        // Validate the existing semantic selections, not a name-only split.
        let plan = try QwenPartitionPlan(configuration: data, kind: .full)
        let gdn = try QwenGDNPartition(text: text)
        let fusedWidth = 2 * gdn.keyWidth + 2 * gdn.valueWidth + 2 * gdn.valueHeads
        guard !plan.isMoE, plan.layers >= plan.interval, fusedWidth <= 32768 else {
            throw ProbeError("GDN diagnostic topology or captured projection width exceeds its bound")
        }
        if options.mode == .qwenGDNArithmeticCheck {
            _ = try arithmeticEstimatedBytes(hiddenSize: gdn.hiddenSize, fusedWidth: fusedWidth,
                                              tokens: options.promptCount)
        }
        return text
    }

    /// Shared pre-load/runtime estimate; excludes model and allocator/OS overhead.
    static func arithmeticEstimatedBytes(hiddenSize: Int, fusedWidth: Int, tokens: Int) throws -> Int {
        guard (1...8192).contains(hiddenSize), hiddenSize % 64 == 0,
              (1...32768).contains(fusedWidth), (1...32).contains(tokens) else {
            throw ProbeError("GDN arithmetic geometry exceeds its estimate bounds")
        }
        let tripletBytes = fusedWidth * (hiddenSize / 8 * 4 + 2 * (hiddenSize / 64) * 4)
        let captureBytes = 16 * tokens * fusedWidth * 4 + 4 * tokens * hiddenSize * 4
        let total = 4 * tripletBytes + captureBytes
        guard total <= 512 * 1024 * 1024 else {
            throw ProbeError("GDN arithmetic variants exceed the 512 MiB additional tensor/capture estimate")
        }
        return total
    }
}
