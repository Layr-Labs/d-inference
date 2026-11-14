// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMServer
import ProviderCoreFoundation
import Testing
@testable import ProviderCore

/// Opt-in real weights, production slot and loopback HTTP. The token is
/// ephemeral, the model root is explicit, and no coordinator is contacted.
/// Nothing here starts a service or takes this Mac's serving lock.
///
///   DARKBLOOM_MUSE_GLIMMER_LIVE=1
///   DARKBLOOM_MUSE_GLIMMER_HUB=<Hugging Face hub root holding the pinned snapshot>
///   DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL=1
///   DARKBLOOM_PREFIX_CACHE_TEST_ROOT=<empty directory for this run's prefix cache>
///   DARKBLOOM_MUSE_GLIMMER_RECEIPTS=<file>   (optional: one JSON line per request)
///   DARKBLOOM_MUSE_GLIMMER_LIVE_PHASES=http,speed,cache   (optional subset; `drafter` too)
///   DARKBLOOM_MUSE_GLIMMER_DRAFTER=<directory of the pinned quantized drafter>   (optional)
///   DARKBLOOM_MUSE_GLIMMER_REFERENCE=<receipts of an earlier run>   (optional)
///
/// With a drafter directory the slot loads it through the provider's funnel
/// and loader and must activate it; without one MTP is off. With a reference,
/// every case of this run that names one of the reference's cases must have
/// the same content, reasoning, finish and token count: run once without the
/// drafter, then with it and the first run's receipts.
///
/// The prefix cache must be the isolated test root, which the store encrypts
/// under a key held in memory: the run never opens the operator's cache
/// directory or its persistent key.
///
/// `http` proves that the provider loads the pinned checkpoint into a paged
/// slot and that a client receives reasoning, answer and tool calls in their
/// own fields. `speed` times streamed requests and samples memory; its
/// numbers are this machine's, not a qualification. `cache` runs one
/// conversation under one cache scope, built as the provider builds a
/// coordinator request's engine, repeats each turn under a scope never used
/// before (cold), and compares the two.
@Suite("Muse Glimmer physical-machine HTTP", .serialized)
struct MuseGlimmerLiveTests {
    static let modelID = MuseGlimmerModelPolicy.localModelID

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_MUSE_GLIMMER_LIVE"] == "1"))
    func servedThroughLoopback() async throws {
        let env = ProcessInfo.processInfo.environment
        // As `darkbloom start` does before any GPU work: MLX loads one pinned
        // metallib snapshot, whose digest enters the checkpoint identity.
        // Without it the complete prefix cache stays off
        // (`runtime_identity_unavailable`).
        let metallib = try #require(bindRuntimeMetallibForMLX(
            from: env["DARKBLOOM_MUSE_GLIMMER_METALLIB"].map { URL(fileURLWithPath: $0) }),
            "set DARKBLOOM_MUSE_GLIMMER_METALLIB to the staged mlx.metallib")
        let phases = Set((env["DARKBLOOM_MUSE_GLIMMER_LIVE_PHASES"] ?? "http,speed,cache")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        let root = try #require(env["DARKBLOOM_MUSE_GLIMMER_HUB"])
        let previous = ModelScanner.configuredCacheDirectory
        ModelScanner.configureCacheDirectory(root)
        defer { ModelScanner.configureCacheDirectory(previous) }
        try #require(SSDPrefixCacheFactory.isolatedTestRoot(environment: env) != nil,
            "set DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL=1 and DARKBLOOM_PREFIX_CACHE_TEST_ROOT")
        try #require(SSDPrefixCacheFactory.forceEphemeralKey(environment: env),
            "this run must not load a persistent cache key")

        let id = Self.modelID
        let directory = try #require(ModelScanner.resolveLocalPath(modelID: id))
        let model = try #require(ModelScanner.parseModelInfo(snapshotDir: directory, modelName: id))
        try #require(model.modelType == MuseGlimmerModelPolicy.modelType && model.templateRenderOK == true)
        #expect(model.quantization == "nvfp4")
        #expect(model.isVision == nil)
        #expect(EngineV2SupportedModels.isSupported(model: model))
        // Present only for a directory that carries the served template.
        let contract = try? PromptContractIdentity.compute(modelDirectory: directory)

        let port = UInt16(env["DARKBLOOM_MUSE_GLIMMER_PORT"] ?? "19131") ?? 19131
        let token = UUID().uuidString + UUID().uuidString
        let drafter = env["DARKBLOOM_MUSE_GLIMMER_DRAFTER"].flatMap { $0.isEmpty ? nil : $0 }
        let reference = try env["DARKBLOOM_MUSE_GLIMMER_REFERENCE"].map {
            try MuseGlimmerLiveClient.receipts(URL(fileURLWithPath: $0))
        }
        let server = StandaloneServer(config: .init(port: port, host: "127.0.0.1", authToken: token,
            mtpMode: drafter == nil ? .off : .auto, mtpDrafterPath: drafter,
            coordinatorURL: "http://127.0.0.1:1"), models: [model])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1800
        configuration.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let receipt = env["DARKBLOOM_MUSE_GLIMMER_RECEIPTS"].map { URL(fileURLWithPath: $0) }
        if let receipt { try Data().write(to: receipt) }
        let client = MuseGlimmerLiveClient(port: port, token: token, session: session, receipt: receipt)

        try await server.start()
        do {
            try #require(await server.waitUntilBound(timeoutSeconds: 10))
            MuseGlimmerLiveClient.resetPeakMemory()
            try client.record(MuseGlimmerLiveClient.memory("before-load"))
            let loadStarted = ContinuousClock.now
            try await server.ensureModelLoaded(id)
            let loadSeconds = MuseGlimmerLiveClient.seconds(since: loadStarted)
            try #require(await server.slots[id]?.bridge.kvBackendKind == .paged, "the slot must be paged")
            let checkpointPrecision = try #require(await server.slots[id]?.bridge.kvCheckpointQuantization)
            try client.record(MuseGlimmerLiveClient.memory("after-load"))
            let bridge = try #require(await server.slots[id]?.bridge)
            let mtp = await bridge.mtpStatusSnapshot()
            try client.record(["case": "mtp", "drafter_directory": drafter ?? "none",
                               "configured": mtp.configured, "active": mtp.active,
                               "fallback_reason": mtp.fallbackReason?.rawValue ?? "none",
                               "verification": mtp.verificationMode ?? "none",
                               "acceptance": mtp.acceptance ?? "none",
                               "assistant_artifact_bytes": Int(mtp.assistantArtifactBytes),
                               "assistant_resident_bytes": Int(mtp.assistantResidentBytes)])
            if drafter != nil {
                try #require(mtp.active, "the drafter did not activate: \(mtp.fallbackReason?.rawValue ?? "none")")
                #expect(mtp.verificationMode == "rectangular_exact")
            } else {
                #expect(!mtp.active)
            }
            let (_, metrics) = try await client.get("/metrics")
            try client.record(["case": "slot", "kv_backend": "paged", "load_seconds": loadSeconds,
                               "metallib_sha256": metallib,
                               "prompt_contract_id": contract ?? "none",
                               "weight_hash_present": model.weightHash?.isEmpty == false,
                               "checkpoint_precision_env": env["DARKBLOOM_CBV2_CHECKPOINT_QUANTIZATION"] ?? "default",
                               "checkpoint_precision": checkpointPrecision.rawValue,
                               "metrics": metrics.split(separator: "\n").filter {
                                   $0.contains("kv_backend") || $0.contains("prefix_cache")
                               }.map(String.init)])
            #expect(metrics.contains("backend=\"paged\""))
            if phases.contains("cache") {
                try #require(!metrics.contains("prefix_cache_status{model=\"\(id)\",state=\"disabled\""),
                    "the prefix cache is off for this slot")
            }

            if phases.contains("http") { try await Self.http(client) }
            if phases.contains("drafter") { try await Self.drafted(client, bridge: bridge) }
            if phases.contains("speed") { try await Self.speed(client) }
            if phases.contains("cache") {
                // Unset, Muse Glimmer's checkpoints store native rows.
                if env["DARKBLOOM_CBV2_CHECKPOINT_QUANTIZATION"] == nil { #expect(checkpointPrecision == .native) }
                try await Self.conversation(server: server, client: client,
                    exactRows: checkpointPrecision == .native)
            }
            if let reference, let receipt { try Self.compare(receipt: receipt, reference: reference, client: client) }
        } catch {
            await server.stopAndWait()
            throw error
        }
        await server.stopAndWait()
    }

    // MARK: - Requests

    static func chat(_ messages: [[String: Any]], maxTokens: Int, greedy: Bool = true,
                     effort: String? = nil) -> [String: Any] {
        var body: [String: Any] = ["model": modelID, "messages": messages, "max_tokens": maxTokens,
                                   "stream": false]
        if greedy { body["temperature"] = 0 }
        if let effort { body["reasoning_effort"] = effort }
        return body
    }

    static func decoded(_ data: Data) throws -> (message: [String: Any], finish: String?, usage: [String: Any]) {
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let choice = try #require((object["choices"] as? [[String: Any]])?.first)
        return (try #require(choice["message"] as? [String: Any]), choice["finish_reason"] as? String,
                object["usage"] as? [String: Any] ?? [:])
    }

    static func expectNoFraming(_ text: String?, _ name: String) {
        for marker in ["<|start|>", "<|message|>", "<|eom|>", "<|eot|>", "to=self", "to=user", "<atem:"] {
            #expect(text?.contains(marker) != true, "\(name): \(marker)")
        }
    }

    static var weatherTool: [String: Any] { ["type": "function", "function": [
        "name": "get_weather", "description": "Get the current weather in a city.",
        "parameters": ["type": "object", "properties": ["city": ["type": "string"]], "required": ["city"]]]] }

    /// A deterministic text of about 30 tokens a line, for long prompts.
    static func ledger(_ title: String, lines: Int) -> String {
        let stations = ["Alder", "Brennock", "Cardow", "Dunmere", "Elsworth", "Farrow", "Glenhollow", "Harwick"]
        let winds = ["north", "east", "south", "west"]
        return "\(title)\n" + (1...lines).map { i in
            "Record \(i): station \(stations[i % stations.count]) logged \((i * 37) % 101) millimetres of "
                + "rain on day \(i % 28 + 1), with wind at \((i * 13) % 47) km/h from the \(winds[i % 4])."
        }.joined(separator: "\n")
    }

    /// Donation outcomes settled between two snapshots of the process-wide
    /// counters, by outcome name (`donated`, `disk_space_insufficient`, ...).
    static func outcomeCounts(before: [PrefixCacheDonationOutcomeCount],
                              after: [PrefixCacheDonationOutcomeCount]) -> [String: Int] {
        let earlier = Dictionary(uniqueKeysWithValues: before.map { ($0.outcome, $0.count) })
        return after.reduce(into: [:]) { counts, entry in
            let settled = entry.count - (earlier[entry.outcome] ?? 0)
            if settled > 0 { counts[entry.outcome.rawValue] = Int(settled) }
        }
    }

    // MARK: - Phases

    /// P1 and P2: greedy and sampled text, the reasoning split, ATEM calls,
    /// streaming and not.
    static func http(_ client: MuseGlimmerLiveClient) async throws {
        let question: [[String: Any]] = [["role": "user", "content": "What is 17 times 23? Answer with the number."]]

        let (status, data) = try await client.post(chat(question, maxTokens: 2048), name: "greedy")
        try #require(status == 200, "greedy: \(String(decoding: data, as: UTF8.self))")
        let first = try decoded(data)
        #expect((first.message["content"] as? String)?.contains("391") == true)
        #expect((first.message["reasoning_content"] as? String)?.isEmpty == false)
        expectNoFraming(first.message["content"] as? String, "content")
        expectNoFraming(first.message["reasoning_content"] as? String, "reasoning_content")
        #expect(first.finish == "stop")

        // Greedy is repeatable on the same slot.
        let (repeatStatus, repeatData) = try await client.post(chat(question, maxTokens: 2048), name: "greedy-repeat")
        #expect(repeatStatus == 200)
        let repeated = try decoded(repeatData)
        let same = (repeated.message["content"] as? String) == (first.message["content"] as? String)
            && (repeated.message["reasoning_content"] as? String) == (first.message["reasoning_content"] as? String)
        try client.record(["case": "greedy-repeat-summary", "same_output": same])
        #expect(same)

        // Omitted sampling fields take the card's values.
        let (sampledStatus, sampledData) = try await client.post(
            chat(question, maxTokens: 2048, greedy: false), name: "sampled")
        #expect(sampledStatus == 200)
        let sampled = try decoded(sampledData)
        #expect((sampled.message["content"] as? String)?.contains("391") == true)
        expectNoFraming(sampled.message["content"] as? String, "sampled content")
        expectNoFraming(sampled.message["reasoning_content"] as? String, "sampled reasoning")

        let stream = try await client.stream(chat(question, maxTokens: 2048), name: "greedy-stream")
        #expect(stream.status == 200 && stream.sawDone && stream.content.contains("391"))
        #expect(!stream.reasoning.isEmpty)
        #expect(stream.finish == "stop")
        expectNoFraming(stream.body, "stream")

        // Cut inside reasoning: reasoning only, finish reason length.
        let (cutStatus, cutData) = try await client.post(chat(question, maxTokens: 8), name: "cut-in-reasoning")
        #expect(cutStatus == 200)
        let cut = try decoded(cutData)
        #expect(cut.finish == "length")
        expectNoFraming(cut.message["content"] as? String, "cut content")
        expectNoFraming(cut.message["reasoning_content"] as? String, "cut reasoning")

        let ask: [[String: Any]] = [["role": "user", "content": "Use get_weather to check the weather in Paris. Do not guess."]]
        var called = chat(ask, maxTokens: 1024, effort: "low")
        called["tools"] = [weatherTool]
        let (toolStatus, toolData) = try await client.post(called, name: "tool-auto")
        try #require(toolStatus == 200, "tool response: \(String(decoding: toolData, as: UTF8.self))")
        let toolTurn = try decoded(toolData)
        let calls = toolTurn.message["tool_calls"] as? [[String: Any]] ?? []
        #expect(calls.count == 1)
        let function = calls.first?["function"] as? [String: Any]
        #expect(function?["name"] as? String == "get_weather")
        #expect((function?["arguments"] as? String)?.contains("Paris") == true)
        #expect(toolTurn.finish == "tool_calls")
        expectNoFraming(toolTurn.message["content"] as? String, "tool content")

        let streamedCall = try await client.stream(called, name: "tool-auto-stream")
        #expect(streamedCall.status == 200 && streamedCall.sawDone)
        #expect(streamedCall.calls.count == 1)
        #expect(streamedCall.calls[0]?.name == "get_weather")
        #expect(streamedCall.calls[0]?.arguments.contains("Paris") == true)
        #expect(streamedCall.finish == "tool_calls")
        expectNoFraming(streamedCall.content, "tool stream content")

        // The tool result goes back through the template's history path.
        let callID = calls.first?["id"] as? String ?? "call_1"
        var followUp = chat(ask + [
            ["role": "assistant", "content": NSNull(), "tool_calls": calls],
            ["role": "tool", "tool_call_id": callID, "content": "{\"temp_c\": 18, \"sky\": \"clear\"}"],
        ], maxTokens: 1024, effort: "low")
        followUp["tools"] = [weatherTool]
        let (followStatus, followData) = try await client.post(followUp, name: "tool-result")
        try #require(followStatus == 200, "follow-up: \(String(decoding: followData, as: UTF8.self))")
        let final = try decoded(followData)
        #expect((final.message["content"] as? String)?.contains("18") == true)
        expectNoFraming(final.message["content"] as? String, "follow-up content")

        let followStream = try await client.stream(followUp, name: "tool-result-stream")
        #expect(followStream.status == 200 && followStream.sawDone && followStream.content.contains("18"))
        expectNoFraming(followStream.body, "follow-up stream")
    }

    /// Matched requests for the drafter: three prompts, greedy and sampled,
    /// each with a seed so its engine request id is the same in every run
    /// (the sampler keys its noise by the id). Each request records the
    /// slot's drafter counters before and after it.
    static func drafted(_ client: MuseGlimmerLiveClient, bridge: EngineV2Bridge) async throws {
        let prompts: [(String, [[String: Any]], String?)] = [
            ("p1", [["role": "user", "content": "What is 17 times 23? Answer with the number."]], nil),
            ("s1", [["role": "user", "content": "Explain in detail how a refrigerator keeps food cold."]], nil),
            ("copy", [["role": "user", "content": ledger("Ledger D (drafter run).", lines: 60)
                + "\n\nCopy records 1 to 12 exactly as written, one per line, with nothing else."]], "low"),
        ]
        for (name, messages, effort) in prompts {
            for sampled in [false, true] {
                var body = chat(messages, maxTokens: 256, greedy: !sampled, effort: effort)
                body["seed"] = 99
                if sampled { body["temperature"] = 1.0; body["top_p"] = 0.95 }
                let label = "draft-\(name)-\(sampled ? "sampled" : "greedy")"
                let before = await bridge.mtpStatusSnapshot()
                let result = try await client.stream(body, name: label)
                let after = await bridge.mtpStatusSnapshot()
                #expect(result.status == 200 && result.completionTokens > 0, "\(label)")
                let rounds = after.rounds - before.rounds
                let accepted = after.acceptedDraftTokens - before.acceptedDraftTokens
                let emitted = after.committedEmittedTokens - before.committedEmittedTokens
                try client.record(["case": label + "-mtp", "rounds": rounds,
                    "proposed": after.proposedTokens - before.proposedTokens, "accepted": accepted,
                    "emitted": emitted, "seed_rows": after.seedRows - before.seedRows,
                    "rectangular_rounds": after.rectangularVerificationRounds - before.rectangularVerificationRounds,
                    "serial_rounds": after.serialVerificationRounds - before.serialVerificationRounds,
                    "accepted_per_round": rounds > 0 ? Double(accepted) / Double(rounds) : 0,
                    "emitted_per_round": rounds > 0 ? Double(emitted) / Double(rounds) : 0,
                    "selected_depth": after.selectedDepth,
                    "acceptance_by_position": zip(after.acceptanceByPosition,
                        before.acceptanceByPosition + Array(repeating: 0, count: max(0,
                            after.acceptanceByPosition.count - before.acceptanceByPosition.count)))
                        .map { $0 - $1 },
                    "completion_tokens": result.completionTokens, "decode_tok_s": result.decodeTokensPerSecond ?? -1])
            }
        }
    }

    /// Every case of this run whose name a reference case also has must
    /// carry the same text: drafter on against drafter off.
    static func compare(receipt: URL, reference: [String: [String: Any]], client: MuseGlimmerLiveClient) throws {
        let fields = ["content", "reasoning", "finish", "completion_tokens"]
        var compared = 0, equal = 0
        var differing: [String] = []
        for (name, current) in try MuseGlimmerLiveClient.receipts(receipt).sorted(by: { $0.key < $1.key }) {
            guard let earlier = reference[name], current["content"] != nil, earlier["content"] != nil else { continue }
            compared += 1
            let same = fields.allSatisfy { "\(current[$0] ?? "")" == "\(earlier[$0] ?? "")" }
            if same { equal += 1 } else { differing.append(name) }
            #expect(same, "\(name): output differs from the reference run")
        }
        try client.record(["case": "reference-comparison", "compared": compared, "equal": equal,
                           "differing": differing])
        #expect(compared > 0, "no case of this run is in the reference")
    }

    /// S1 and P4: decode, time to first token and prefill through HTTP, with
    /// memory at load, prefill and decode.
    static func speed(_ client: MuseGlimmerLiveClient) async throws {
        try client.record(["case": "load-average-start", "load": MuseGlimmerLiveClient.loadAverage()])
        // The baseline's shape: a short prompt, 300 tokens, greedy, streamed, three runs.
        let matched = chat([["role": "user", "content": "Explain in detail how a refrigerator keeps food cold."]],
                           maxTokens: 300)
        for run in 0..<3 {
            let result = try await client.stream(matched, name: "decode-matched-\(run)")
            #expect(result.status == 200 && result.completionTokens > 0)
        }

        // A prompt of at least 4,096 tokens that no earlier request shares:
        // prefill, then a short decode.
        let long = chat([["role": "user", "content": ledger("Ledger S (speed run).", lines: 180)
            + "\n\nWhich station logged the most rain on day 9? Answer briefly."]], maxTokens: 256, effort: "low")
        MuseGlimmerLiveClient.resetPeakMemory()
        try client.record(MuseGlimmerLiveClient.memory("before-prefill"))
        var atFirstToken: [String: Any] = [:]
        let result = try await client.stream(long, name: "prefill-long") {
            atFirstToken = MuseGlimmerLiveClient.memory("after-prefill")
            MuseGlimmerLiveClient.resetPeakMemory()
        }
        try client.record(atFirstToken)
        try client.record(MuseGlimmerLiveClient.memory("after-decode"))
        #expect(result.status == 200)
        #expect(result.promptTokens >= 4_096)
        if let ttft = result.firstTokenSeconds {
            try client.record(["case": "prefill-long-summary", "prompt_tokens": result.promptTokens,
                               "ttft_seconds": ttft, "prompt_tokens_per_ttft_second": Double(result.promptTokens) / ttft,
                               "decode_tok_s": result.decodeTokensPerSecond ?? -1])
        }
        try client.record(["case": "load-average-end", "load": MuseGlimmerLiveClient.loadAverage()])
    }

    /// C1, C2 and C3. The engine is built as the provider builds a
    /// coordinator request's engine (`ProviderLoop+InferenceHandler`), on
    /// this server's slot, with the authenticated scope the coordinator
    /// would send. Each turn runs under scope A, then under a scope never
    /// used before (cold); the two must agree when checkpoint rows are exact.
    static func conversation(server: StandaloneServer, client: MuseGlimmerLiveClient, exactRows: Bool)
        async throws
    {
        let slot = try #require(await server.slots[modelID])
        // One render date for the whole conversation: a run may cross midnight UTC.
        let date = PromptRenderDate.capture()
        func scoped(_ body: [String: Any], scope: String, name: String) async throws -> [String: Any] {
            let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            let inbound = try ProviderLoop.decodeInboundChatRequest(data)
            var request = inbound.request
            if request.reasoningParser == nil {
                request.reasoningParser = ProviderLoop.inferReasoningParser(for: slot.modelType)
            }
            let controls = inbound.extensions.templateControls
                .servingCoordinatorRequest(planned: true).withPromptDate(date)
            let usage = EngineV2RequestUsageSignal()
            let engine = MultiModelBatchSchedulerEngine(
                registryProvider: { @Sendable in
                    [modelID: .init(tokenizer: slot.tokenizer, modelType: slot.modelType,
                                    container: slot.container, isVLM: slot.isVLM, engineV2Bridge: slot.bridge)]
                },
                defaultMaxTokens: ProviderLoop.schedulerDefaultMaxTokens,
                templateControls: controls, cacheScope: scope, engineV2Usage: usage)
            let store = slot.bridge.ssdHybridCheckpointStore
            let before = store?.stats()
            // Each donation settles one outcome in the process-wide counters
            // (the store's default recorder). This test is the process's only
            // requester, so the difference names this request's writes.
            let outcomesBefore = PrefixCacheDonationTelemetry.shared.snapshot()
            let started = ContinuousClock.now
            let response = try await MLXOpenAIService(engine: engine).createChatCompletion(request: request)
            let seconds = MuseGlimmerLiveClient.seconds(since: started)
            // Checkpoint writes are queued; settle them so this request's
            // writes are counted here and the next turn can find them.
            await store?.waitForWritesForTesting()
            let after = store?.stats()
            let outcomes = Self.outcomeCounts(
                before: outcomesBefore, after: PrefixCacheDonationTelemetry.shared.snapshot())
            let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(response))
                as? [String: Any])
            let choice = (object["choices"] as? [[String: Any]])?.first ?? [:]
            let message = choice["message"] as? [String: Any] ?? [:]
            let tokens = object["usage"] as? [String: Any] ?? [:]
            let fields: [String: Any] = ["case": name, "scope": scope, "seconds": seconds,
                "prompt_tokens": tokens["prompt_tokens"] as? Int ?? 0,
                "completion_tokens": tokens["completion_tokens"] as? Int ?? 0,
                "cached_tokens": usage.prefixCacheHitTokens ?? -1,
                "prefill_tokens_saved": usage.prefixCachePrefillTokensSaved ?? -1,
                "lookup": usage.lookupResult.map { "\($0)" } ?? "none",
                "finish": choice["finish_reason"] as? String ?? "none",
                "content": message["content"] as? String ?? "",
                "reasoning": message["reasoning_content"] as? String ?? "",
                "checkpoint_files_written": (after?.filesWritten ?? 0) - (before?.filesWritten ?? 0),
                "checkpoint_delta_files_written": (after?.deltaFilesWritten ?? 0) - (before?.deltaFilesWritten ?? 0),
                "checkpoint_bytes_written": (after?.bytesWritten ?? 0) - (before?.bytesWritten ?? 0),
                "checkpoint_write_ms": (after?.writeMilliseconds ?? 0) - (before?.writeMilliseconds ?? 0),
                "checkpoint_writes_dropped": (after?.writesDropped ?? 0) - (before?.writesDropped ?? 0),
                "checkpoint_write_outcomes": outcomes,
                "store_disk_bytes": store?.diskBytesOnDisk ?? -1]
            try client.record(fields)
            return fields
        }

        // Lookups a short reasoning pass can answer, so every turn ends with
        // an answer the next turn's history carries.
        let system = ledger("Ledger C (conversation). Answer questions about these records briefly.", lines: 120)
        let questions = [
            "Which station logged record 12, and how much rain?",
            "What wind direction does record 40 give?",
            "On which day was record 77 logged?",
            "Did record 101 log more rain than record 102?",
            "What wind speed does record 55 give?",
            "In one sentence, repeat your answers about records 12 and 40.",
        ]
        let scopeA = "glimmer-live-A-" + UUID().uuidString
        var messages: [[String: Any]] = [["role": "system", "content": system]]
        var promptTotal = 0, cachedTotal = 0, laterPrompt = 0, laterCached = 0, equalTurns = 0
        for (turn, question) in questions.enumerated() {
            messages.append(["role": "user", "content": question])
            let body = chat(messages, maxTokens: 512, effort: "low")
            let warm = try await scoped(body, scope: scopeA, name: "turn-\(turn + 1)-scope-A")
            let cold = try await scoped(body, scope: "glimmer-live-cold-" + UUID().uuidString,
                                        name: "turn-\(turn + 1)-cold")
            let prompt = warm["prompt_tokens"] as? Int ?? 0
            let hit = max(0, warm["cached_tokens"] as? Int ?? 0)
            promptTotal += prompt
            cachedTotal += hit
            if turn > 0 { laterPrompt += prompt; laterCached += hit }
            // C3: a scope that never ran this prefix never hits it.
            #expect(cold["cached_tokens"] as? Int == 0, "turn \(turn + 1): a new scope hit")
            let same = ["content", "reasoning", "finish", "completion_tokens"].allSatisfy {
                "\(warm[$0] ?? "")" == "\(cold[$0] ?? "")"
            }
            if same { equalTurns += 1 }
            if exactRows { #expect(same, "turn \(turn + 1): restored and cold outputs differ") }
            if turn > 0 { #expect(hit > 0, "turn \(turn + 1): no prefix reuse under one scope") }
            let answer = (warm["content"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(no answer)"
            messages.append(["role": "assistant", "content": answer])
        }
        // The first turn's prompt again under scope A, then through local HTTP.
        let firstTurn = chat([["role": "system", "content": system], ["role": "user", "content": questions[0]]],
                             maxTokens: 512, effort: "low")
        let again = try await scoped(firstTurn, scope: scopeA, name: "turn-1-again-scope-A")
        let (localStatus, _) = try await client.post(firstTurn, name: "turn-1-local-http")
        #expect(localStatus == 200)
        try client.record(["case": "conversation-summary", "turns": questions.count,
            "prompt_tokens": promptTotal, "cached_tokens": cachedTotal,
            "hit_rate_all_turns": promptTotal > 0 ? Double(cachedTotal) / Double(promptTotal) : 0,
            "hit_rate_turns_2_on": laterPrompt > 0 ? Double(laterCached) / Double(laterPrompt) : 0,
            "restored_equals_cold_turns": equalTurns, "exact_rows": exactRows,
            "turn_1_again_cached": again["cached_tokens"] as? Int ?? -1])
    }
}
