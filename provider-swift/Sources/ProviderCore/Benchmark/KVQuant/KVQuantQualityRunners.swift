import Foundation

public struct KVQuantQualityRunner {
    public init() {}

    public func run(
        config: KVQuantGateConfig,
        suite: KVQuantSuite,
        hardware _: HardwareInfo,
        modelDirectory: URL?
    ) async -> KVQuantSuiteReport {
        let startedAt = Date()
        guard let modelDirectory else {
            return .skipped(
                suite: suite,
                config: config,
                modelPath: nil,
                reason: "local model snapshot for '\(config.modelID)' was not found in the HuggingFace cache and no modelDirectory was supplied",
                todos: ["Download the target MLX model or pass --model-dir."],
                startedAt: startedAt,
                endedAt: Date()
            )
        }

        let evaluator = KVQuantEvaluator(config: config, modelDirectory: modelDirectory)
        do {
            let quality: KVQuantQualityReport
            switch suite {
            case .perplexity:
                quality = try await runPerplexity(config: config, evaluator: evaluator)
            case .logits:
                quality = try await runLogits(config: config, evaluator: evaluator)
            case .niah:
                quality = try await runNIAH(config: config, evaluator: evaluator)
            case .performance, .memory, .output, .capacity:
                quality = KVQuantQualityReport(
                    suite: suite,
                    metricName: suite.displayName,
                    dataDirectory: config.dataDirectory,
                    metrics: [:],
                    passFail: .skipped("\(suite.displayName) is not a quality-runner suite"),
                    todos: ["Run this suite through its dedicated runner."]
                )
            }
            return KVQuantSuiteReport(
                suite: suite,
                modelID: config.modelID,
                modelPath: modelDirectory.path,
                reference: config.reference,
                candidate: config.candidate,
                contexts: config.contexts,
                iterationCount: config.iterations,
                startedAt: startedAt,
                endedAt: Date(),
                performance: nil,
                quality: quality,
                passFail: quality.passFail,
                failures: quality.passFail.failures,
                skipped: quality.passFail.skipped ? [quality.passFail.reason ?? "skipped"] : [],
                todos: quality.todos
            )
        } catch let error as KVQuantEvaluatorError {
            return .skipped(
                suite: suite,
                config: config,
                modelPath: modelDirectory.path,
                reason: error.localizedDescription,
                todos: ["Provide a complete target model snapshot before running this suite."],
                startedAt: startedAt,
                endedAt: Date()
            )
        } catch {
            return .failed(
                suite: suite,
                config: config,
                modelPath: modelDirectory.path,
                failures: ["\(suite.displayName) failed: \(error.localizedDescription)"],
                startedAt: startedAt,
                endedAt: Date()
            )
        }
    }

    private func runPerplexity(config: KVQuantGateConfig, evaluator: KVQuantEvaluator) async throws -> KVQuantQualityReport {
        let texts = try fixtureTexts(config: config)
        var referenceScores: [KVQuantSequenceScore] = []
        var candidateScores: [KVQuantSequenceScore] = []
        let maxTokens = config.contexts.max().map { min(max($0, 32), 4096) }

        for text in texts.prefix(max(config.iterations, 1)) {
            referenceScores.append(try await evaluator.score(text: text, mode: config.reference, maxTokens: maxTokens))
            candidateScores.append(try await evaluator.score(text: text, mode: config.candidate, maxTokens: maxTokens))
        }

        let deltas = zip(referenceScores, candidateScores).map { $1.perplexity - $0.perplexity }
        let ratios = zip(referenceScores, candidateScores).map { $1.perplexity / max($0.perplexity, .leastNonzeroMagnitude) }
        let nllDeltas = zip(referenceScores, candidateScores).map {
            $1.meanNegativeLogLikelihood - $0.meanNegativeLogLikelihood
        }

        let metrics: [String: KVQuantMetricSummary] = [
            "ppl.reference": .init(unit: "perplexity", samples: referenceScores.map(\.perplexity)),
            "ppl.candidate": .init(unit: "perplexity", samples: candidateScores.map(\.perplexity)),
            "ppl.absolute_delta": .init(unit: "perplexity", samples: deltas),
            "ppl.ratio": .init(unit: "ratio", samples: ratios),
            "ppl.relative_delta_pct": .init(unit: "percent", samples: ratios.map { ($0 - 1) * 100 }),
            "nll.reference": .init(unit: "nats_per_token", samples: referenceScores.map(\.meanNegativeLogLikelihood)),
            "nll.candidate": .init(unit: "nats_per_token", samples: candidateScores.map(\.meanNegativeLogLikelihood)),
            "nll.absolute_delta": .init(unit: "nats_per_token", samples: nllDeltas),
            "tokens.scored": .init(unit: "tokens", samples: referenceScores.map { Double($0.scoredTokenCount) }),
        ]

        return KVQuantQualityReport(
            suite: .perplexity,
            metricName: "perplexity",
            dataDirectory: config.dataDirectory,
            metrics: metrics,
            passFail: .passed(),
            todos: []
        )
    }

    private func runLogits(config: KVQuantGateConfig, evaluator: KVQuantEvaluator) async throws -> KVQuantQualityReport {
        // Generation-fidelity: reference greedy-continues each prompt, candidate is
        // teacher-forced over that continuation. This is the trustworthy quality gate
        // (correct gen forward, confident reference tokens, quantization engaged).
        //
        // Use LONG coherent prompts (truncated to the target context) so most of the
        // KV is quantized — the capacity regime the objective targets. Short prompts
        // are also included for breadth.
        let targetCtx = config.contexts.max() ?? 2048
        let longPrompts = ((try? fixtureTexts(config: config)) ?? [])
            .map { String($0.prefix(targetCtx * 4)) }  // ~4 chars/token
            .filter { $0.count > 200 }
        let prompts = longPrompts + Self.genFidelityPrompts
        let genTokens = min(max(config.decodeTokens, 32), 128)
        var candTop1: [Double] = []
        var candTop5: [Double] = []
        var refSelf: [Double] = []

        for prompt in prompts.prefix(max(config.iterations, 1) * 2) {
            let r = try await evaluator.generationAgreement(
                prompt: prompt,
                reference: config.reference,
                candidate: config.candidate,
                count: genTokens)
            guard r.generatedTokens > 0 else { continue }
            candTop1.append(r.candidateTop1)
            candTop5.append(r.candidateTop5)
            refSelf.append(r.referenceSelfTop1)
        }

        return KVQuantQualityReport(
            suite: .logits,
            metricName: "generation_fidelity",
            dataDirectory: config.dataDirectory,
            metrics: [
                "top_token.greedy_match_rate": .init(unit: "rate", samples: candTop1),
                "top_token.top5_overlap_rate": .init(unit: "rate", samples: candTop5),
                "top_token.reference_self_match_rate": .init(unit: "rate", samples: refSelf),
            ],
            passFail: .passed(),
            todos: refSelf.allSatisfy { $0 > 0.999 } ? [] : ["reference self-agreement < 1.0 — investigate scorer determinism"]
        )
    }

    /// Short, coherent prompts that elicit confident continuations from instruct
    /// models, so reference greedy tokens are high-probability and fidelity is
    /// meaningful (independent of raw-text PPL quirks).
    public static let genFidelityPrompts: [String] = [
        "Explain step by step how photosynthesis works in plants.",
        "Write a short paragraph about the history of the Roman Empire.",
        "List five practical tips for writing clean, maintainable software.",
        "Describe how a hash map works and why lookups are fast.",
        "Summarize the plot of a typical detective mystery novel.",
        "Explain the difference between TCP and UDP networking protocols.",
    ]

    private func runNIAH(config: KVQuantGateConfig, evaluator: KVQuantEvaluator) async throws -> KVQuantQualityReport {
        let cases = try loadNIAHFixtures(config: config)
        var referenceExact: [Double] = []
        var referenceContains: [Double] = []
        var candidateExact: [Double] = []
        var candidateContains: [Double] = []
        var exactAgree: [Double] = []
        var containsAgree: [Double] = []
        var evaluated = 0

        for item in cases.prefix(max(config.iterations, 1)) {
            let prompt = niahPrompt(item: item)
            let maxTokens = min(config.decodeTokens, 64)
            let referenceOutput = normalize(try await evaluator.generate(prompt: prompt, mode: config.reference, maxTokens: maxTokens))
            let candidateOutput = normalize(try await evaluator.generate(prompt: prompt, mode: config.candidate, maxTokens: maxTokens))
            let normalizedExpected = normalize(item.expectedAnswer)

            let refExact = referenceOutput == normalizedExpected ? 1.0 : 0.0
            let refContains = referenceOutput.contains(normalizedExpected) ? 1.0 : 0.0
            let candExact = candidateOutput == normalizedExpected ? 1.0 : 0.0
            let candContains = candidateOutput.contains(normalizedExpected) ? 1.0 : 0.0

            referenceExact.append(refExact)
            referenceContains.append(refContains)
            candidateExact.append(candExact)
            candidateContains.append(candContains)
            exactAgree.append(refExact == candExact ? 1.0 : 0.0)
            containsAgree.append(refContains == candContains ? 1.0 : 0.0)
            evaluated += 1
        }

        let metrics: [String: KVQuantMetricSummary] = [
            "niah.reference_exact_match_rate": .init(unit: "rate", samples: referenceExact),
            "niah.exact_match_rate": .init(unit: "rate", samples: candidateExact),
            "niah.exact_match_agreement_rate": .init(unit: "rate", samples: exactAgree),
            "niah.reference_contains_rate": .init(unit: "rate", samples: referenceContains),
            "niah.answer_contains_rate": .init(unit: "rate", samples: candidateContains),
            "niah.contains_agreement_rate": .init(unit: "rate", samples: containsAgree),
            "niah.evaluated_cases": .init(unit: "cases", samples: [Double(evaluated)]),
        ]

        return KVQuantQualityReport(
            suite: .niah,
            metricName: "needle_in_a_haystack",
            dataDirectory: config.dataDirectory,
            metrics: metrics,
            passFail: .passed(),
            todos: []
        )
    }

    fileprivate static func outputReport(config: KVQuantGateConfig, evaluator: KVQuantEvaluator) async throws -> KVQuantQualityReport {
        let cases = try loadOutputFixtures(config: config)
        var referencePass: [Double] = []
        var candidatePass: [Double] = []
        var passAgree: [Double] = []
        var referenceJsonValid: [Double] = []
        var candidateJsonValid: [Double] = []
        var jsonValidAgree: [Double] = []
        var referenceRequired: [Double] = []
        var candidateRequired: [Double] = []
        var requiredAgree: [Double] = []
        var unsafeRefusal: [Double] = []

        for item in cases.prefix(max(config.iterations, 1)) {
            let maxTokens = item.maxTokens ?? config.decodeTokens
            let referenceOutput = try await evaluator.generate(messages: item.messages, mode: config.reference, maxTokens: maxTokens)
            let candidateOutput = try await evaluator.generate(messages: item.messages, mode: config.candidate, maxTokens: maxTokens)
            let referenceResult = checkOutput(referenceOutput, checks: item.checks)
            let candidateResult = checkOutput(candidateOutput, checks: item.checks)

            referencePass.append(referenceResult.passed ? 1 : 0)
            candidatePass.append(candidateResult.passed ? 1 : 0)
            passAgree.append(referenceResult.passed == candidateResult.passed ? 1 : 0)

            let refJV = referenceResult.jsonValid ?? true
            let candJV = candidateResult.jsonValid ?? true
            referenceJsonValid.append(refJV ? 1 : 0)
            candidateJsonValid.append(candJV ? 1 : 0)
            jsonValidAgree.append(refJV == candJV ? 1 : 0)

            referenceRequired.append(referenceResult.requiredSubstringsPassed ? 1 : 0)
            candidateRequired.append(candidateResult.requiredSubstringsPassed ? 1 : 0)
            requiredAgree.append(referenceResult.requiredSubstringsPassed == candidateResult.requiredSubstringsPassed ? 1 : 0)

            unsafeRefusal.append(candidateResult.unsafeRefusal ? 1 : 0)
        }

        let metrics: [String: KVQuantMetricSummary] = [
            "output.reference_pass_rate": .init(unit: "rate", samples: referencePass),
            "output.pass_rate": .init(unit: "rate", samples: candidatePass),
            "output.pass_agreement_rate": .init(unit: "rate", samples: passAgree),
            "output.reference_json_valid_rate": .init(unit: "rate", samples: referenceJsonValid),
            "output.json_valid_rate": .init(unit: "rate", samples: candidateJsonValid),
            "output.json_valid_agreement_rate": .init(unit: "rate", samples: jsonValidAgree),
            "output.reference_required_substrings_rate": .init(unit: "rate", samples: referenceRequired),
            "output.required_substrings_rate": .init(unit: "rate", samples: candidateRequired),
            "output.required_substrings_agreement_rate": .init(unit: "rate", samples: requiredAgree),
            "output.unsafe_refusal_rate": .init(unit: "rate", samples: unsafeRefusal),
        ]

        return KVQuantQualityReport(
            suite: .output,
            metricName: "output_agreement",
            dataDirectory: config.dataDirectory,
            metrics: metrics,
            passFail: .passed(),
            todos: []
        )
    }
}

public struct KVQuantOutputSmokeRunner {
    public init() {}

    public func run(
        config: KVQuantGateConfig,
        hardware _: HardwareInfo,
        modelDirectory: URL?
    ) async -> KVQuantSuiteReport {
        let startedAt = Date()
        guard let modelDirectory else {
            return .skipped(
                suite: .output,
                config: config,
                modelPath: nil,
                reason: "local model snapshot for '\(config.modelID)' was not found in the HuggingFace cache and no modelDirectory was supplied",
                todos: ["Download the target MLX model or pass --model-dir."],
                startedAt: startedAt,
                endedAt: Date()
            )
        }
        let evaluator = KVQuantEvaluator(config: config, modelDirectory: modelDirectory)
        do {
            let quality = try await KVQuantQualityRunner.outputReport(config: config, evaluator: evaluator)
            return KVQuantSuiteReport(
                suite: .output,
                modelID: config.modelID,
                modelPath: modelDirectory.path,
                reference: config.reference,
                candidate: config.candidate,
                contexts: config.contexts,
                iterationCount: config.iterations,
                startedAt: startedAt,
                endedAt: Date(),
                performance: nil,
                quality: quality,
                passFail: quality.passFail,
                failures: quality.passFail.failures,
                skipped: quality.passFail.skipped ? [quality.passFail.reason ?? "skipped"] : [],
                todos: quality.todos
            )
        } catch let error as KVQuantEvaluatorError {
            return .skipped(
                suite: .output,
                config: config,
                modelPath: modelDirectory.path,
                reason: error.localizedDescription,
                todos: ["Provide a complete target model snapshot before running output agreement."],
                startedAt: startedAt,
                endedAt: Date()
            )
        } catch {
            return .failed(
                suite: .output,
                config: config,
                modelPath: modelDirectory.path,
                failures: ["output suite failed: \(error.localizedDescription)"],
                startedAt: startedAt,
                endedAt: Date()
            )
        }
    }
}

private struct OutputFixture: Decodable {
    let id: String
    let category: String
    let maxTokens: Int?
    let messages: [[String: String]]
    let checks: OutputChecks

    enum CodingKeys: String, CodingKey {
        case id
        case category
        case maxTokens = "max_tokens"
        case messages
        case checks
    }
}

private struct OutputChecks: Decodable {
    let mustInclude: [String]?
    let forbid: [String]?
    let jsonOnly: Bool?

    enum CodingKeys: String, CodingKey {
        case mustInclude = "must_include"
        case forbid
        case jsonOnly = "json_only"
    }
}

private struct NIAHFixture: Decodable {
    let id: String
    let kind: String
    let targetContextTokens: Int?
    let needle: String?
    let expectedAnswer: String
    let prompt: String?
    let needleInsertAfterSegment: Int?
    let needleInsertFraction: Double?
    let fillerTemplate: String?
    let needleTemplate: String?
    let question: String?

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case targetContextTokens = "target_context_tokens"
        case needle
        case expectedAnswer = "expected_answer"
        case prompt
        case needleInsertAfterSegment = "needle_insert_after_segment"
        case needleInsertFraction = "needle_insert_fraction"
        case fillerTemplate = "filler_template"
        case needleTemplate = "needle_template"
        case question
    }
}

private struct OutputCheckResult {
    let passed: Bool
    let jsonValid: Bool?
    let requiredSubstringsPassed: Bool
    let unsafeRefusal: Bool
}

private func fixtureTexts(config: KVQuantGateConfig) throws -> [String] {
    // Prefer PPL-specific fixtures if available; otherwise fall back to output-smoke.
    let pplURL = fixtureURL(config: config, relativePath: "prompts/ppl.jsonl")
    if FileManager.default.fileExists(atPath: pplURL.path) {
        return try loadJSONL(PPLFixture.self, from: pplURL).map(\.text)
    }
    return try loadOutputFixtures(config: config).map { item in
        item.messages.map { message in
            "\(message["role"] ?? "user"): \(message["content"] ?? "")"
        }.joined(separator: "\n")
    }
}

private struct PPLFixture: Decodable {
    let text: String
}

private func loadOutputFixtures(config: KVQuantGateConfig) throws -> [OutputFixture] {
    try loadJSONL(OutputFixture.self, from: fixtureURL(config: config, relativePath: "prompts/output-smoke.jsonl"))
}

private func loadNIAHFixtures(config: KVQuantGateConfig) throws -> [NIAHFixture] {
    try loadJSONL(NIAHFixture.self, from: fixtureURL(config: config, relativePath: "prompts/niah-smoke.jsonl"))
}

private func fixtureURL(config: KVQuantGateConfig, relativePath: String) -> URL {
    if let dataDirectory = config.dataDirectory {
        return dataDirectory.appendingPathComponent(relativePath)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Benchmarks/KVQuant")
        .appendingPathComponent(relativePath)
}

private func loadJSONL<T: Decodable>(_ type: T.Type, from url: URL) throws -> [T] {
    let data = try Data(contentsOf: url)
    let text = String(decoding: data, as: UTF8.self)
    let decoder = JSONDecoder()
    return try text.split(separator: "\n").map { line in
        try decoder.decode(type, from: Data(line.utf8))
    }
}

private func checkOutput(_ output: String, checks: OutputChecks) -> OutputCheckResult {
    let lower = output.lowercased()
    let requiredOK = checks.mustInclude?.allSatisfy { lower.contains($0.lowercased()) } ?? true
    let forbidOK = !(checks.forbid?.contains { lower.contains($0.lowercased()) } ?? false)
    let jsonValid: Bool? = checks.jsonOnly == true ? isJSONObject(output) : nil
    let refusal = ["i can't", "i cannot", "unable to", "i'm sorry"].contains { lower.contains($0) }
    return OutputCheckResult(
        passed: requiredOK && forbidOK && (jsonValid ?? true) && !refusal,
        jsonValid: jsonValid,
        requiredSubstringsPassed: requiredOK,
        unsafeRefusal: refusal
    )
}

private func isJSONObject(_ output: String) -> Bool {
    guard let data = output.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data)
    else { return false }
    return object is [String: Any]
}

private func niahPrompt(item: NIAHFixture) -> String {
    if let prompt = item.prompt { return prompt }
    let target = max(item.targetContextTokens ?? 1024, 128)
    let filler = item.fillerTemplate ?? "Segment {i}: harmless filler."
    let needle = item.needleTemplate ?? "Segment {i}: The retrieval key is \(item.expectedAnswer)."
    let insert = item.needleInsertAfterSegment ?? Int(Double(target / 32) * (item.needleInsertFraction ?? 0.5))
    var segments: [String] = []
    for i in 0..<max(target / 32, insert + 2) {
        let template = i == insert ? needle : filler
        segments.append(template.replacingOccurrences(of: "{i}", with: "\(i)"))
    }
    return segments.joined(separator: "\n") + "\nQuestion: \(item.question ?? "What is the retrieval key?") Answer with only the exact key."
}

private func normalize(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: "`", with: "")
        .replacingOccurrences(of: "\"", with: "")
}
