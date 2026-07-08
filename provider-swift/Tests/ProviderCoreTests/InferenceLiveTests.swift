// InferenceLiveTests -- end-to-end live MLX inference against models in
// the local HuggingFace cache.
//
// v0.7.5 one-engine: every model slot serves through the CBv2
// `EngineV2Bridge` (the legacy BatchScheduler engine is deleted), and only
// CBv2-adapted families (gpt-oss, gemma4) can serve. The tiny-Qwen
// scheduler tests that used to live here died with the legacy engine;
// what remains targets the production checkpoints.
//
// Gating
// ------
// These tests load real model weights, run real generations on the GPU,
// and take seconds to minutes. They are **opt-in** via env vars:
//
//   DARKBLOOM_LIVE_MLX_TESTS=1   required for any test in this file
//   DARKBLOOM_LIVE_MLX_GEMMA=1        required additionally for the multi-GB Gemma tests
//   DARKBLOOM_LIVE_MLX_MULTI_MODEL=1  required additionally for tests needing two local models
//
// They also require an `mlx.metallib` to exist somewhere under
// `provider-swift/.build/`. `LiveInferenceFixtures.ensureMetallibColocated()`
// finds it and copies it next to the xctest runner so MLX's colocated
// lookup succeeds. If the metallib is missing entirely, every test is
// skipped with an explanation of how to install one
// (`./scripts/fetch-metallib.sh debug`).
//
// Running
// -------
//   cd provider-swift
//   DARKBLOOM_LIVE_MLX_TESTS=1 swift test --filter InferenceLiveTests
//
// Adding the Gemma cases:
//   DARKBLOOM_LIVE_MLX_TESTS=1 \
//     DARKBLOOM_LIVE_MLX_GEMMA=1 \
//     swift test --filter InferenceLiveTests
//
// Adding the two-model standalone case:
//   DARKBLOOM_LIVE_MLX_TESTS=1 \
//     DARKBLOOM_LIVE_MLX_MULTI_MODEL=1 \
//     DARKBLOOM_LIVE_MLX_GEMMA=1 \
//     swift test --filter InferenceLiveTests
//
// Cleanup
// -------
// Bridge-based tests `defer` `await bridge.shutdown()` +
// `MLX.Memory.clearCache()`; server-based tests stop the standalone server.
// Memory budget is set up-front via `MLX.GPU.set(memoryLimit:)` so a
// runaway test can't consume all of unified RAM.

import Foundation
import Darwin
import Hummingbird
import HummingbirdTesting
import MLX
import MLXLLM
import MLXLMCommon
import Testing
@testable import ProviderCore

// MARK: - Suite

/// Live tests are serialized by default. MLX state (caches, peak memory,
/// loaded weights) is process-global; running two model loads in parallel
/// produces unpredictable OOM-vs-eviction behavior that masks real bugs.
@Suite("live MLX inference", .serialized)
struct InferenceLiveTests {

    // MARK: 1. Standalone server

    @Test(
        "standalone server serves two local models through one process",
        .enabled(
            if: LiveInferenceFixtures.multiModelLiveTestsEnabled
                && LiveInferenceFixtures.gemmaTestsEnabled,
            "set DARKBLOOM_LIVE_MLX_TESTS=1, DARKBLOOM_LIVE_MLX_MULTI_MODEL=1 and DARKBLOOM_LIVE_MLX_GEMMA=1 to run the two-model standalone live test (v0.7.5 one-engine: only CBv2-adapted checkpoints can serve, so this uses gpt-oss + gemma-qat — the production pair)"
        )
    )
    func liveStandaloneServerServesTwoModelsThroughOneProcess() async throws {
        // v0.7.5 one-engine: the standalone server refuses models without a
        // CBv2 adapter, so this test serves the PRODUCTION pair (gpt-oss +
        // gemma-qat) — the same checkpoints as EngineV2CoResidencyLiveTests
        // — and doubles as the standalone co-residency check: two v2 slots,
        // re-sliced grants, both serving through one process.
        let gptossID = EngineV2CoResidencyLiveTests.gptossID
        let gemmaQatID = EngineV2CoResidencyLiveTests.gemmaQatID
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            Issue.record("skipped: \(LiveFixtureSkip.missingMetallib.description)")
            return
        }
        guard case .found = LiveInferenceFixtures.locate(gptossID) else {
            Issue.record("skipped: \(LiveFixtureSkip.modelNotInCache(gptossID).description)")
            return
        }
        guard case .found = LiveInferenceFixtures.locate(gemmaQatID) else {
            Issue.record("skipped: \(LiveFixtureSkip.modelNotInCache(gemmaQatID).description)")
            return
        }
        LiveInferenceFixtures.applyMemoryBudget(maxBytes: 48 * 1024 * 1024 * 1024)

        let server = StandaloneServer(
            config: StandaloneServerConfig(maxCachedModels: 2),
            models: [
                liveModelInfo(
                    id: gptossID, quantization: "mxfp4",
                    modelType: "gpt_oss", estimatedMemoryGb: 13),
                liveModelInfo(
                    id: gemmaQatID, quantization: "4bit",
                    modelType: "gemma4", estimatedMemoryGb: 16),
            ]
        )
        let app = server.makeApplication()

        try await app.test(.router) { client in
            func assertChat(model: String, prompt: String) async throws {
                let request = ChatCompletionRequest(
                    model: model,
                    messages: [ChatMessage(role: "user", content: prompt)],
                    temperature: 0.0,
                    max_tokens: 12,
                    stream: false
                )
                let body = String(data: try JSONEncoder().encode(request), encoding: .utf8) ?? "{}"
                try await client.execute(
                    uri: "/v1/chat/completions",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(string: body)
                ) { response in
                    let responseBody = String(buffer: response.body)
                    #expect(response.status == .ok, "standalone response for \(model): \(response.status) \(responseBody)")
                    let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: Data(responseBody.utf8))
                    #expect(decoded.model == model)
                    #expect(!decoded.choices.isEmpty)
                    #expect(!decoded.choices[0].message.content.isEmpty)
                    #expect(decoded.usage.completion_tokens > 0)
                }
            }

            try await assertChat(model: gptossID, prompt: "Reply with one word: first.")
            try await assertChat(model: gemmaQatID, prompt: "Reply with one word: second.")
            try await assertChat(model: gptossID, prompt: "Reply with one word: again.")

            // Both slots are v2 co-residents: each holds a live engine KV
            // grant and the two grants never exceed one fleet budget
            // (Σ(grants) ≤ budget is the §1.1 invariant, here observed
            // through the standalone server's own slots).
            let grantA = await server.debugEngineKVGrant(modelId: gptossID)
            let grantB = await server.debugEngineKVGrant(modelId: gemmaQatID)
            #expect((grantA ?? 0) > 0)
            #expect((grantB ?? 0) > 0)
        }
        await server.stopAndWait()
    }

    @Test(
        "standalone socket disconnect cleans up slot reservations",
        .enabled(
            if: LiveInferenceFixtures.liveTestsEnabled,
            "set DARKBLOOM_LIVE_MLX_TESTS=1 to run live MLX inference tests"
        )
    )
    func liveStandaloneSocketDisconnectCleansUpSlotReservations() async throws {
        // v0.7.5 one-engine: the standalone server only serves CBv2-adapted
        // checkpoints, so this uses gpt-oss (the smallest production model)
        // instead of the retired tiny-qwen fixture.
        let modelID = EngineV2CoResidencyLiveTests.gptossID
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            Issue.record("skipped: \(LiveFixtureSkip.missingMetallib.description)")
            return
        }
        guard case .found = LiveInferenceFixtures.locate(modelID) else {
            Issue.record("skipped: \(LiveFixtureSkip.modelNotInCache(modelID).description)")
            return
        }
        LiveInferenceFixtures.applyMemoryBudget(maxBytes: 24 * 1024 * 1024 * 1024)

        let port = try reserveUnusedTCPPort()
        let server = StandaloneServer(
            config: StandaloneServerConfig(port: port, maxCachedModels: 1),
            models: [
                liveModelInfo(
                    id: modelID, quantization: "mxfp4",
                    modelType: "gpt_oss", estimatedMemoryGb: 13)
            ]
        )
        do {
            try await server.start()
            let listening = try await waitForTCPPort(port, timeout: .seconds(10))
            try #require(listening, "standalone server did not listen on port \(port)")

            try await assertStandaloneDisconnectCleanup(
                server: server, port: port, modelID: modelID, stream: true)
            try await assertStandaloneDisconnectCleanup(
                server: server, port: port, modelID: modelID, stream: false)
        } catch {
            await server.stopAndWait()
            throw error
        }
        await server.stopAndWait()
    }

    // MARK: 2. Gemma 26B

    @Test(
        "Gemma 26B produces plausible arithmetic answer",
        .enabled(
            if: LiveInferenceFixtures.gemmaTestsEnabled,
            "set DARKBLOOM_LIVE_MLX_TESTS=1 and DARKBLOOM_LIVE_MLX_GEMMA=1 to run the 27 GB Gemma test"
        )
    )
    func liveInferenceWithGemmaProducesPlausibleOutput() async throws {
        let loaded: LiveInferenceFixtures.LoadedBridge
        do {
            // Larger memory budget for the 27 GB MoE.
            loaded = try await LiveInferenceFixtures.loadBridge(
                modelID: LiveInferenceFixtures.gemmaModelID,
                maxConcurrentRequests: 1,
                memoryBudgetBytes: 64 * 1024 * 1024 * 1024
            )
        } catch let skip as LiveFixtureSkip {
            Issue.record("skipped: \(skip.description)")
            return
        }
        let bridge = loaded.bridge
        defer {
            Task {
                await bridge.shutdown()
                MLX.Memory.clearCache()
            }
        }

        // Template + tokenize the prompt ourselves — exactly like the
        // production `MultiModelBatchSchedulerEngine` does before
        // `bridge.submitTokenized`.
        let prompt = "What is 7 * 8? Reply with just the number."
        let messages: [[String: any Sendable]] = [["role": "user", "content": prompt]]
        let promptTokens: [Int] = try await loaded.container.perform { ctx in
            try ctx.tokenizer.applyChatTemplate(
                messages: messages, tools: nil, additionalContext: nil)
        }

        let request = ChatCompletionRequest(
            model: LiveInferenceFixtures.gemmaModelID,
            messages: [ChatMessage(role: "user", content: prompt)],
            temperature: 0.0,
            max_tokens: 32
        )

        let result = await collect(from: bridge, promptTokens: promptTokens, request: request)

        #expect(!result.didError, "unexpected error: \(result.error ?? "")")
        #expect(result.info != nil, "no .info event received")
        #expect(
            result.fullText.contains("56"),
            "expected '56' in output, got: \(result.fullText.debugDescription)"
        )
    }

    // MARK: 3. Chat-template fidelity (Phase 0)

    @Test(
        "tokenizer chat template embeds system + user content in order",
        .enabled(
            if: LiveInferenceFixtures.liveTestsEnabled,
            "set DARKBLOOM_LIVE_MLX_TESTS=1 to run live MLX inference tests"
        )
    )
    func liveInferenceTokenizerChatTemplateMatchesExpected() async throws {
        // The fidelity check doesn't need a serving engine -- it operates on
        // the model's UserInputProcessor directly. But it does need the
        // metallib (mlx-swift-lm pulls in MLX initialization on tokenizer
        // load) and a real model on disk.
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            Issue.record("skipped: \(LiveFixtureSkip.missingMetallib.description)")
            return
        }
        LiveInferenceFixtures.applyMemoryBudget()

        let modelID: String
        let directory: URL
        switch LiveInferenceFixtures.locate(LiveInferenceFixtures.tinyModelID) {
        case .found(let url):
            modelID = LiveInferenceFixtures.tinyModelID
            directory = url
        case .missing:
            switch LiveInferenceFixtures.locate(LiveInferenceFixtures.tinyModelFallbackID) {
            case .found(let url):
                modelID = LiveInferenceFixtures.tinyModelFallbackID
                directory = url
            case .missing(let id):
                Issue.record("skipped: \(LiveFixtureSkip.modelNotInCache(id).description)")
                return
            }
        }

        let container = try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: LocalTokenizerLoader()
        )

        let systemContent = "You are a terse assistant. Reply with one word."
        let userContent = "What color is the sky on a clear day?"

        let messages: [[String: any Sendable]] = [
            ["role": "system", "content": systemContent],
            ["role": "user", "content": userContent],
        ]
        let userInput = UserInput(messages: messages)

        // Use `ModelContainer.prepare(input:)` rather than the closure-form
        // `perform(...)` because the closure-form requires `UserInput` to be
        // `Sendable`, and it is not (it can carry CIImage / AVAsset).
        // `prepare(input:)` declares `consuming sending UserInput` so the
        // value transfers cleanly across the actor isolation boundary.
        let prepared = try await container.prepare(input: userInput)
        let tokenIds: [Int] = prepared.text.tokens.asArray(Int.self)

        #expect(!tokenIds.isEmpty, "tokenizer produced 0 tokens for a 2-message chat")

        let decoded = await container.decode(tokenIds: tokenIds)

        // The chat template shape varies by model family (Qwen3 uses
        // ChatML-ish "<|im_start|>system" sections; Qwen2.5 uses
        // "<|im_start|>system" identically). What MUST hold across all of
        // them is that the system content appears before the user content
        // in the rendered string, both verbatim.
        guard let systemRange = decoded.range(of: systemContent) else {
            let snippet = String(decoded.prefix(300))
            Issue.record(
                "system content '\(systemContent)' missing from decoded prompt for \(modelID): \(snippet.debugDescription)"
            )
            return
        }
        guard let userRange = decoded.range(of: userContent) else {
            let snippet = String(decoded.prefix(300))
            Issue.record(
                "user content '\(userContent)' missing from decoded prompt for \(modelID): \(snippet.debugDescription)"
            )
            return
        }
        #expect(
            systemRange.lowerBound < userRange.lowerBound,
            "system content must precede user content in chat template (model: \(modelID))"
        )

        // Sanity check: re-encoding the decoded prompt should round-trip
        // to a token count within a small delta. This guards against
        // tokenizer / Jinja regressions that drop characters silently.
        let reencoded = await container.encode(decoded)
        let drift = abs(reencoded.count - tokenIds.count)
        #expect(
            drift <= 4,
            "decode -> encode round-trip drifted by \(drift) tokens (orig: \(tokenIds.count), reencoded: \(reencoded.count))"
        )
    }
}

private func liveModelInfo(
    id: String,
    quantization: String,
    modelType: String = "chat",
    estimatedMemoryGb: Double = 0.25
) -> ModelInfo {
    ModelInfo(
        id: id,
        modelType: modelType,
        quantization: quantization,
        sizeBytes: 0,
        estimatedMemoryGb: estimatedMemoryGb
    )
}

private func waitUntil(timeout: Duration, predicate: () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if predicate() { return true }
        try await Task.sleep(for: .milliseconds(25))
    }
    return predicate()
}

private func waitUntilAsync(timeout: Duration, predicate: () async -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await predicate() { return true }
        try await Task.sleep(for: .milliseconds(25))
    }
    return await predicate()
}

private func assertStandaloneDisconnectCleanup(
    server: StandaloneServer,
    port: UInt16,
    modelID: String,
    stream: Bool
) async throws {
    var fd: Int32? = try openRawStandaloneRequest(port: port, modelID: modelID, stream: stream)
    defer {
        if let fd { closeSocket(fd) }
    }

    let becameActive = try await waitUntilAsync(timeout: .seconds(180)) {
        guard let active = await server.debugActiveRequestCount(modelId: modelID) else {
            return false
        }
        return active > 0
    }
    try #require(becameActive, "standalone \(stream ? "streaming" : "non-streaming") request never became active")

    if let openFD = fd {
        abortSocket(openFD)
        fd = nil
    }

    // Streaming requests release on the next chunk write (broken pipe).
    // Non-streaming requests don't release until the handler finishes
    // because Hummingbird only detects the disconnect when it tries to
    // write the response. That can take generation_time (~13-20s for
    // gpt-oss at max_tokens=512). 60s gives headroom on slow runners.
    // Tracked as a known limitation of the MLXLMServer adoption; a future
    // middleware can hook NIO channel-inactive into Task cancellation to
    // restore pre-rewrite latency.
    let cleanupTimeout: Duration = stream ? .seconds(5) : .seconds(60)
    let cleanedUp = try await waitUntilAsync(timeout: cleanupTimeout) {
        guard let active = await server.debugActiveRequestCount(modelId: modelID) else {
            return false
        }
        let reservations = await server.debugSlotReservationCount(modelId: modelID)
        return active == 0 && reservations == 0
    }

    let active = await server.debugActiveRequestCount(modelId: modelID)
    let reservations = await server.debugSlotReservationCount(modelId: modelID)
    #expect(
        cleanedUp,
        "standalone \(stream ? "streaming" : "non-streaming") disconnect left active=\(String(describing: active)), reservations=\(reservations)"
    )
}

private func openRawStandaloneRequest(port: UInt16, modelID: String, stream: Bool) throws -> Int32 {
    let request = ChatCompletionRequest(
        model: modelID,
        messages: [
            ChatMessage(
                role: "user",
                content: "Write a long, detailed story about a robot exploring Mars. Continue until you reach the token limit."
            ),
        ],
        temperature: 0.7,
        max_tokens: 512,
        stream: stream
    )
    let body = String(data: try JSONEncoder().encode(request), encoding: .utf8) ?? "{}"
    let raw = """
        POST /v1/chat/completions HTTP/1.1\r
        Host: 127.0.0.1:\(port)\r
        Content-Type: application/json\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """

    let fd = try connectSocket(port: port)
    do {
        try writeAll(fd: fd, Data(raw.utf8))
        return fd
    } catch {
        closeSocket(fd)
        throw error
    }
}

private func waitForTCPPort(_ port: UInt16, timeout: Duration) async throws -> Bool {
    try await waitUntil(timeout: timeout) {
        guard let fd = try? connectSocket(port: port) else { return false }
        closeSocket(fd)
        return true
    }
}

private func reserveUnusedTCPPort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw LiveSocketError.posix("socket", errno) }
    defer { closeSocket(fd) }

    var reuse: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else { throw LiveSocketError.posix("bind", errno) }

    var bound = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            getsockname(fd, sockaddrPointer, &length)
        }
    }
    guard nameResult == 0 else { throw LiveSocketError.posix("getsockname", errno) }
    return UInt16(bigEndian: bound.sin_port)
}

private func connectSocket(port: UInt16) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw LiveSocketError.posix("socket", errno) }

    var noSigpipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let connectResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connectResult == 0 else {
        let err = errno
        closeSocket(fd)
        throw LiveSocketError.posix("connect", err)
    }
    return fd
}

private func writeAll(fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        var written = 0
        while written < rawBuffer.count {
            let result = Darwin.send(fd, base.advanced(by: written), rawBuffer.count - written, 0)
            guard result > 0 else { throw LiveSocketError.posix("send", errno) }
            written += result
        }
    }
}

private func closeSocket(_ fd: Int32) {
    _ = Darwin.shutdown(fd, SHUT_RDWR)
    _ = Darwin.close(fd)
}

private func abortSocket(_ fd: Int32) {
    var lingerOption = linger(l_onoff: 1, l_linger: 0)
    setsockopt(fd, SOL_SOCKET, SO_LINGER, &lingerOption, socklen_t(MemoryLayout<linger>.size))
    _ = Darwin.close(fd)
}

private enum LiveSocketError: Error, CustomStringConvertible {
    case posix(String, Int32)

    var description: String {
        switch self {
        case .posix(let operation, let code):
            return "\(operation) failed: \(String(cString: strerror(code)))"
        }
    }
}
