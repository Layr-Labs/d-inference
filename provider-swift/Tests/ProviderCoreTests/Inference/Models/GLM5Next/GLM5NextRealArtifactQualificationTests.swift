import CryptoKit
import Foundation
import MLX
@_spi(Benchmarking) @_spi(Diagnostics) import MLXLMCommon
import Testing

@_spi(Benchmarking) @testable import ProviderCore

/// Greedy outputs recorded by the native mlx-swift-lm GLM5NextRealSmokeTests
/// on the same artifact: target-only, dense cache, B=1, no EOS stop.
struct GLM5NextNativeSmokeReference {
    struct Prompt: Decodable { let name: String; let ids: [Int] }
    struct Result: Decodable { let name: String; let generated: [Int] }
    let prompts: [Prompt]
    /// Execution policy label (results file stem) → prompt name → tokens.
    let outputs: [String: [String: [Int]]]

    init(directory: URL) throws {
        prompts = try JSONDecoder().decode([Prompt].self,
            from: Data(contentsOf: directory.appendingPathComponent("prompts.json")))
        var outputs: [String: [String: [Int]]] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where file.lastPathComponent.hasPrefix("results") && file.pathExtension == "json" {
            let rows = try JSONDecoder().decode([Result].self, from: Data(contentsOf: file))
            outputs[file.deletingPathExtension().lastPathComponent] =
                Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0.generated) })
        }
        self.outputs = outputs
    }

    static func commonPrefix(_ a: [Int], _ b: [Int]) -> Int {
        zip(a, b).prefix { $0 == $1 }.count
    }
}

/// Offline, explicitly expensive LOAD gates. Never run on a live provider.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GLM5_REAL_ARTIFACT"] == "1"))
struct GLM5NextRealArtifactQualificationTests {
    static let smokeTexts = [
        "capital": "What is the capital of France? Answer in one short sentence.",
        "fibonacci": "Write a Python function that returns the nth Fibonacci number.",
        "colors": "List three primary colors.",
    ]

    /// G0: load, resident memory, provider prompt contract, MTP greedy output
    /// against the native reference, MTP determinism and acceptance accounting.
    @Test func realPinnedArtifactMTPBaseline() async throws {
        let env = ProcessInfo.processInfo.environment
        let reference = try GLM5NextNativeSmokeReference(directory: URL(fileURLWithPath:
            try #require(env["DARKBLOOM_TEST_GLM5_REAL_NATIVE_SMOKE_DIR"])))
        try #require(reference.prompts.count == Self.smokeTexts.count && !reference.outputs.isEmpty)
        try await GLM5NextRealModelHarness.withLoaded { harness in
            let session = try #require(harness.session)
            let stopTokens = await session.stopTokenIDs()
            var smoke: [[String: Any]] = []
            var failures: [String] = []
            for (index, native) in reference.prompts.enumerated() {
                let prompt = try await harness.prompt(try #require(Self.smokeTexts[native.name]))
                let promptMatches = prompt == native.ids
                let first = try await harness.run(prompt, id: UInt64(1 + index * 2), output: 48)
                let second = try await harness.run(prompt, id: UInt64(2 + index * 2), output: 48)
                // The native probe ran without EOS stopping: compare against
                // its prefix through the first production stop token, which
                // CBv2 keeps in the raw delta tokens.
                var agreement: [String: Any] = [:]
                var exactPolicies: [String] = []
                for (policy, outputs) in reference.outputs.sorted(by: { $0.key < $1.key }) {
                    guard let tokens = outputs[native.name] else { continue }
                    let stop = tokens.firstIndex(where: stopTokens.contains)
                    let expected = stop.map { Array(tokens[...$0]) } ?? tokens
                    let expectStop = stop != nil
                    let exact = first.tokens == expected
                        && (expectStop ? first.reason == .stop : first.reason == .length)
                    if exact { exactPolicies.append(policy) }
                    agreement[policy] = ["commonPrefix": GLM5NextNativeSmokeReference.commonPrefix(first.tokens, expected),
                        "expectedTokens": expected.count, "expectedEOSStop": expectStop, "exact": exact]
                }
                var record = try harness.timingRecord(first)
                record["name"] = native.name
                record["promptTokens"] = prompt.count
                record["promptMatchesNative"] = promptMatches
                record["tokens"] = first.tokens
                record["text"] = try await harness.decode(first.tokens)
                record["repeatTokensEqual"] = first.tokens == second.tokens
                record["nativeAgreement"] = agreement
                record["exactNativePolicies"] = exactPolicies
                smoke.append(record)
                if !promptMatches { failures.append("\(native.name): provider prompt differs from native prompt") }
                if exactPolicies.isEmpty { failures.append("\(native.name): MTP greedy output matches no native reference") }
                if first.tokens != second.tokens { failures.append("\(native.name): MTP greedy output not repeatable") }
                if (first.mtp?.rounds ?? 0) == 0 { failures.append("\(native.name): no MTP rounds") }
            }
            // MTP repeatability across content classes at a longer budget.
            let classes = [("prose", "Write a short story about a river."),
                ("code", "Write a Swift binary search function."),
                ("json_tool", "Return JSON with a name and an array of three numbers."),
                ("reasoning", "Explain why a prime greater than two is odd.")]
            var repeatability: [[String: Any]] = []
            for (index, (contentClass, text)) in classes.enumerated() {
                let prompt = try await harness.prompt(text)
                let a = try await harness.run(prompt, id: UInt64(20 + index * 2), output: 256)
                let b = try await harness.run(prompt, id: UInt64(21 + index * 2), output: 256)
                var record = try harness.timingRecord(a)
                record["contentClass"] = contentClass
                record["repeatTokensEqual"] = a.tokens == b.tokens && a.reason == b.reason
                repeatability.append(record)
                if a.tokens != b.tokens || a.reason != b.reason { failures.append("\(contentClass): not repeatable") }
                if a.tokens.isEmpty || (a.mtp?.rounds ?? 0) == 0 { failures.append("\(contentClass): no MTP output") }
            }
            try harness.write("baseline", ["schema": 2, "qualified": false,
                "aggregateSHA256": harness.plan.weights.manifest.aggregateSHA256,
                "templateSHA256": GLM5NextRealModelHarness.templateSHA256,
                "maximumContext": harness.maximumContext, "loadSeconds": harness.loadSeconds,
                "memoryAfterLoad": harness.memoryAfterLoad, "memoryAfterRuns": GLM5NextRealModelHarness.residentMemory(),
                "swiftOptimized": !_isDebugAssertConfiguration(), "mtp": true,
                "stopTokens": stopTokens.sorted(), "smoke": smoke, "repeatability": repeatability,
                "greedyDeterministic": failures.allSatisfy { !$0.contains("repeatable") },
                "failures": failures,
                "cache": try GLM5NextRealModelHarness.json((await session.cacheSnapshot()).productionGrant)])
            #expect(failures.isEmpty, "\(failures)")
        }
    }

    /// Served chat contract through the provider engine view: coherent answers,
    /// reasoning/content separation, EOS stop, parsed tool call and a clean
    /// media refusal that leaves the slot serving.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GLM5_REAL_BEHAVIOR"] == "1"))
    func realProviderChatContract() async throws {
        try await GLM5NextRealModelHarness.withLoaded { harness in
            var records: [String: Any] = [:]
            var failures: [String] = []
            func check(_ condition: Bool, _ label: String) { if !condition { failures.append(label) } }
            func clean(_ outcome: GLM5NextRealChatOutcome) -> Bool {
                let leaked = ["<think>", "</think>", "<tool_call>", "</tool_call>", "<|user|>", "<|assistant|>",
                    "<|observation|>", "<|endoftext|>"]
                return !leaked.contains { outcome.content.contains($0) || (outcome.reasoning ?? "").contains($0) }
            }
            let chats: [(String, String, (String) -> Bool)] = [
                ("capital", GLM5NextRealArtifactQualificationTests.smokeTexts["capital"]!,
                    { $0.lowercased().contains("paris") }),
                ("fibonacci", GLM5NextRealArtifactQualificationTests.smokeTexts["fibonacci"]!,
                    { $0.contains("def ") && $0.lowercased().contains("fib") && $0.contains("return") }),
                ("colors", GLM5NextRealArtifactQualificationTests.smokeTexts["colors"]!,
                    { text in let t = text.lowercased()
                        return t.contains("red") && t.contains("blue") && (t.contains("yellow") || t.contains("green")) }),
            ]
            for (name, text, coherent) in chats {
                for effort in ["low", "high"] {
                    let outcome = try await harness.chat(["model": GLM5NextRealModelHarness.servedModelID,
                        "messages": [["role": "user", "content": text]], "reasoning_effort": effort,
                        "max_tokens": 2048, "temperature": 0])
                    records["\(name)-\(effort)"] = outcome.record
                    check(outcome.error == nil, "\(name)/\(effort): request failed")
                    check(outcome.finishReason == "stop", "\(name)/\(effort): did not stop on EOS")
                    check(coherent(outcome.content), "\(name)/\(effort): incoherent or missing answer")
                    check(clean(outcome), "\(name)/\(effort): control markup leaked")
                    if effort == "high" {
                        check(!(outcome.reasoning ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            "\(name)/high: no separated reasoning_content")
                    }
                }
            }
            let parameters: [String: Any] = ["type": "object", "properties": [String: Any]()]
            let function: [String: Any] = ["name": "clock", "description": "Returns the current time.",
                "parameters": parameters]
            let clockTool: [String: Any] = ["type": "function", "function": function]
            let tool = try await harness.chat(["model": GLM5NextRealModelHarness.servedModelID,
                "messages": [["role": "user", "content": "What time is it? Use the clock tool."]],
                "tools": [clockTool],
                "reasoning_effort": "low", "max_tokens": 1024, "temperature": 0])
            records["tool"] = tool.record
            check(tool.error == nil, "tool: request failed")
            check(tool.finishReason == "tool_calls", "tool: finish_reason is not tool_calls")
            check(tool.toolCalls.count == 1, "tool: expected exactly one parsed call")
            if let call = tool.toolCalls.first, let function = call["function"] as? [String: Any] {
                check(function["name"] as? String == "clock", "tool: wrong function name")
                let arguments = (function["arguments"] as? String).flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                check(arguments?.isEmpty == true, "tool: arguments are not an empty JSON object")
            }
            check(clean(tool), "tool: raw tool markup leaked into content")
            let image = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
            let parts: [[String: Any]] = [["type": "text", "text": "Describe this image."],
                ["type": "image_url", "image_url": ["url": image]]]
            let mediaMessage: [String: Any] = ["role": "user", "content": parts]
            let media = try await harness.chat(["model": GLM5NextRealModelHarness.servedModelID,
                "messages": [mediaMessage],
                "reasoning_effort": "low", "max_tokens": 32])
            records["media"] = media.record
            check(media.error != nil && media.response == nil, "media: was not refused")
            check(!GLM5NextLoadFaultState.isRetained, "media: refusal left a retained native fault")
            let after = try await harness.chat(["model": GLM5NextRealModelHarness.servedModelID,
                "messages": [["role": "user", "content": GLM5NextRealArtifactQualificationTests.smokeTexts["capital"]!]],
                "reasoning_effort": "low", "max_tokens": 256, "temperature": 0])
            records["afterMedia"] = after.record
            check(after.error == nil && after.finishReason == "stop" && after.content.lowercased().contains("paris"),
                "media: slot did not keep serving after the refusal")
            try harness.write("chat-contract", ["schema": 1, "qualified": false, "records": records,
                "failures": failures, "memory": GLM5NextRealModelHarness.residentMemory()])
            #expect(failures.isEmpty, "\(failures)")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GLM5_REAL_CONCURRENCY"] == "1"))
    func realConcurrentRequestsAndCancellation() async throws {
        try await GLM5NextRealModelHarness.withLoaded(concurrency: 4) { harness in
            let prompt = try await harness.prompt("Count from one to ten.")
            let serial = try await harness.run(prompt, id: 30, output: 16, suppressEOS: true)
            try #require(serial.reason == .length)
            var records: [[String: Any]] = []
            for width in [2, 4] {
                let engine = try #require(harness.session).rawEngine
                _ = try engine.beginForwardShapeObservation()
                let runs = try await withThrowingTaskGroup(of: GLM5NextRealRun.self) { group in
                    for index in 0..<width {
                        group.addTask { try await harness.run(prompt, id: UInt64(40 + width * 10 + index), output: 16,
                            suppressEOS: true, attributeMTP: false) }
                    }
                    var result: [GLM5NextRealRun] = []
                    for try await run in group { result.append(run) }
                    return result
                }
                let batched = engine.forwardShapeSnapshot().entries.contains { $0.axes.liveBatchRows >= 2 }
                records.append(["width": width, "allEqualSerial": runs.allSatisfy { $0.tokens == serial.tokens },
                    "batched": batched, "wallSeconds": runs.map(\.wallSeconds)])
                #expect(runs.count == width)
                #expect(runs.allSatisfy { $0.reason == .length && $0.tokens == serial.tokens })
                #expect(batched, "overlapping submissions must actually batch, not merely finish serially")
            }
            let cancelled = try await harness.run(prompt, id: 100, output: 1024, cancelAfterFirst: true, suppressEOS: true)
            #expect(cancelled.reason == .cancelled && !cancelled.tokens.isEmpty)
            let after = try await harness.run(prompt, id: 101, output: 16, suppressEOS: true)
            #expect(after.reason == .length && after.tokens == serial.tokens)
            try harness.write("concurrency", ["schema": 1, "qualified": false, "records": records,
                "cancelledTokens": cancelled.tokens.count, "afterCancelEqual": after.tokens == serial.tokens])
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GLM5_REAL_SSD"] == "1"))
    func realEncryptedSSDPrefixRestore() async throws {
        // Same-process ephemeral-key evidence, not Keychain persistence or
        // cross-process restart qualification.
        try await GLM5NextRealModelHarness.withLoaded(ssd: true) { harness in
            let session = try #require(harness.session)
            let store = try #require(harness.checkpointStore)
            let snapshot = await session.cacheSnapshot()
            try #require(snapshot.durableMode == "ssd_complete" && snapshot.keyMode == "ephemeral")
            let prompt = try await harness.exactPrompt(count: 1057, contentClass: "prose", nonce: "ssd-isolated")
            let cold = try await harness.run(prompt, id: 110, output: 16, cache: true, suppressEOS: true)
            try #require(cold.reason == .length)
            try await session.drainCheckpointWrites()
            let written = await session.cacheSnapshot()
            try #require((written.checkpoints?.filesWritten ?? 0) > 0)
            let enumerator = try #require(FileManager.default.enumerator(at: harness.root,
                includingPropertiesForKeys: nil))
            let files = (enumerator.allObjects as? [URL] ?? []).filter { $0.pathExtension == SSDBlockStore.fileExtension }
            try #require(!files.isEmpty)
            for file in files {
                let bytes = try Data(contentsOf: file)
                #expect(Array(bytes.prefix(4)) == SSDBlockStore.magic)
                #expect(throws: (any Error).self) {
                    try SSDBlockStore.readStreaming(from: file, kekKey: SymmetricKey(size: .bits256),
                        maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes,
                        maximumPlaintextBytes: store.config.maxReadBytes, requireEOF: true,
                        validateMetadata: { _ in }, consumeChunk: { _, _ in
                            Issue.record("foreign key exposed a real-model checkpoint chunk")
                        })
                }
            }
            let restored = try await harness.run(prompt, id: 111, output: 16, cache: true, suppressEOS: true)
            #expect(restored.stageDisposition == "staged")
            #expect((restored.usage?.prefixCachePrefillTokensSaved ?? 0) >= 1024)
            #expect(restored.tokens == cold.tokens && restored.reason == .length)
            #expect(((await session.cacheSnapshot()).checkpoints?.stageConsumptions ?? 0) > 0)
            try harness.write("ssd", ["schema": 1, "qualified": false, "files": files.count,
                "stageDisposition": restored.stageDisposition,
                "prefillTokensSaved": restored.usage?.prefixCachePrefillTokensSaved ?? 0,
                "restoredEqual": restored.tokens == cold.tokens,
                "coldTTFTSeconds": cold.ttftSeconds ?? -1, "restoredTTFTSeconds": restored.ttftSeconds ?? -1])
        }
    }
}
