import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import MLXLMCommon
@testable import MLXVLM
import NIOCore
import Testing
@testable import ProviderCore

/// Fixture tokenizer for both hook routes: the template renders `[1, 18, 2]`
/// when a message carries an image part and `[1, 2, 3]` otherwise. Never an
/// official tokenizer.
private struct SuperRouteTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [1, 2, 3] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        String(repeating: "x", count: tokenIds.count)
    }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { "x" }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        "\(messages)".contains("image_url") ? [1, 18, 2] : [1, 2, 3]
    }
    func applyChatTemplate(messages: [[String: any Sendable]], chatTemplate: String,
                           tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] {
        try applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}

private let superAdmissionPNG = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAF0lEQVR4nGP4z8BAEiJN9aiGUQ1DSgMAkPn/Afnh+ngAAAAASUVORK5CYII="

private func superAdmissionBody(image: Bool, stream: Bool) throws -> Data {
    let content: Any = image
        ? [["type": "text", "text": "fixture"], ["type": "image_url", "image_url": ["url": superAdmissionPNG]]]
        : "fixture"
    return try JSONSerialization.data(withJSONObject: [
        "model": NemotronSuperLocalBinding.modelID, "stream": stream, "max_tokens": 2,
        "temperature": 0, "enable_thinking": false,
        "messages": [["role": "user", "content": content]]])
}

private func superAdmissionApplication(hook: NemotronSuperLocalImageHTTP, token: String,
    tokenizer: TokenizerHandle, tracker: LocalResponseTracker? = nil) -> LocalInferenceApplication {
    makeLocalInferenceApplication(
        config: .init(host: "127.0.0.1", port: 0, authToken: token), defaultMaxTokens: 2,
        acquire: { id in throw MultiModelBatchSchedulerEngineError.modelNotLoaded(id) },
        tokenizerProvider: { _ in .init(tokenizer: tokenizer, modelType: "nemotron_h_omni") },
        availableModels: { [] }, mtpSlots: { [] }, responseTracker: tracker,
        modelTypeProvider: { _ in "nemotron_h_omni" }, nemotronSuperImageHTTP: hook)
}

/// Live loopback HTTP admission through the Super hook on the actual native
/// bridge with tiny synthetic weights: the single-request owner's busy status
/// and the text-only hook of a speculating owner.
struct NemotronSuperLocalHTTPAdmissionTests {
    @Test(.timeLimit(.minutes(2))) func busyOwnerRefusesWith429BeforeAnyResponse() async throws {
        let dimensions = NemotronRadioDimensions(width: 2, layers: 1, heads: 1,
            channels: 3, patch: 16, positionSide: 32, prefix: 1, mlpWidth: 3)
        let (installed, construction, residency) = try SuperInstalledFixture(radioDimensions: dimensions).make()
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: .max) })
        let lease = try #require(await budget.claimPendingLoad(requestID: "super-http-busy",
            weightBytes: UInt64(installed.receipt.payloadBytes), minimumKVBytes: 2 << 30))
        let tokenizer = TokenizerHandle(SuperRouteTokenizer())
        let owner = try await NemotronSuperLocalBridgeBuilder.make(installed: installed,
            tokenizer: tokenizer, eosTokenIDs: [31],
            sizing: .init(weightsBytes: installed.receipt.payloadBytes, fp16KVBytesPerToken: 64,
                maxContextLength: 1024, defaultMaxTokens: 2), kvBytesCapacity: 2 << 30,
            kvBudget: budget, loadLease: lease, construction: construction, environment: [:])
        let template = try #require(Data(base64Encoded: superImagePinnedTemplateBase64,
                                        options: .ignoreUnknownCharacters))
        let hook = try NemotronSuperLocalImageHTTP(owner: owner, templateBytes: template)
        let token = "synthetic-super-busy"
        let tracker = LocalResponseTracker()
        let gate = SuperHTTPTerminalGate()
        let baseline = await budget.outstandingReservedBytes()
        // Holds the first request's real pump after its content, before native
        // terminal observation: the owner is busy until that retirement.
        await owner.bridge._testInstallCancelledSettlementHooks(
            beforeNativeTerminal: { _ in await gate.hold() }, onSettlementWait: {})
        let headers: HTTPFields = [.contentType: "application/json", .authorization: "Bearer " + token]
        do {
            try await superAdmissionApplication(hook: hook, token: token, tokenizer: tokenizer,
                                                tracker: tracker).test(.live) { client in
                let socket = try SuperHTTPResetSocket(port: try #require(client.port), token: token,
                    body: try superAdmissionBody(image: true, stream: true))
                defer { socket.close() }
                #expect(try socket.readUntilContent().contains("200 OK"))
                try await superHTTPEventually("first request held before terminal") { await gate.entered }
                let held = await budget.outstandingReservedBytes()
                #expect(held > baseline)
                for (image, stream) in [(false, true), (false, false), (true, true), (true, false)] {
                    try await client.execute(uri: "/v1/chat/completions", method: .post, headers: headers,
                        body: ByteBuffer(bytes: try superAdmissionBody(image: image, stream: stream))) { response in
                        #expect(response.status == .tooManyRequests, "image \(image) stream \(stream)")
                        #expect(response.headers[.contentType] == "application/json")
                        let text = String(buffer: response.body)
                        #expect(text.contains("\"error\"") && !text.contains("data:"))
                    }
                }
                // Refused requests reserved nothing: no media, ingress or KV row.
                #expect(await budget.outstandingReservedBytes() == held)
                #expect(await owner.bridge._testLivePumpCount() == 1)
                await gate.release()
                try await superHTTPEventually("held request retired") {
                    let reserved = await budget.outstandingReservedBytes()
                    let active = await owner.bridge.activeRequestCount()
                    return reserved == baseline && active == 0 && tracker.activeCount == 0
                }
                for image in [false, true] {
                    try await client.execute(uri: "/v1/chat/completions", method: .post, headers: headers,
                        body: ByteBuffer(bytes: try superAdmissionBody(image: image, stream: true))) { response in
                        #expect(response.status == .ok)
                        #expect(String(buffer: response.body).contains("[DONE]"))
                    }
                }
                #expect(!(await gate.timedOut))
            }
        } catch {
            await gate.release()
            try await owner.closeAfterDrain()
            _ = await budget.finishPendingLoad(lease)
            throw error
        }
        await gate.release()
        await hook.drain()
        try await owner.closeAfterDrain()
        #expect(residency.snapshot.usedBytes == 0)
        #expect(await budget.finishPendingLoad(lease))
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    /// A batched owner holds its configured requests in flight at once and
    /// refuses the next with 429 before headers, reserving nothing for it.
    @Test(.timeLimit(.minutes(2))) func batchedOwnerAdmitsItsRequestsAndRefusesTheNextWith429() async throws {
        // Row-exact batched decode needs the latent-MoE layout of the MTP fixture.
        let fixture = try SuperMTPInstalledFixture().make()
        let (installed, construction, residency) = (fixture.installed, fixture.construction, fixture.residency)
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: .max) })
        let lease = try #require(await budget.claimPendingLoad(requestID: "super-http-batched",
            weightBytes: UInt64(installed.receipt.payloadBytes), minimumKVBytes: 4 << 30))
        let tokenizer = TokenizerHandle(SuperRouteTokenizer())
        let owner = try await NemotronSuperLocalBridgeBuilder.make(installed: installed,
            tokenizer: tokenizer, eosTokenIDs: [63],
            sizing: .init(weightsBytes: installed.receipt.payloadBytes, fp16KVBytesPerToken: 64,
                maxContextLength: 64, defaultMaxTokens: 2), kvBytesCapacity: 4 << 30,
            kvBudget: budget, loadLease: lease, construction: construction,
            environment: [NemotronSuperLocalBridgeBuilder.maxConcurrentKey: "2"])
        let template = try #require(Data(base64Encoded: superImagePinnedTemplateBase64,
                                        options: .ignoreUnknownCharacters))
        let hook = try NemotronSuperLocalImageHTTP(owner: owner, templateBytes: template)
        let token = "synthetic-super-batched"
        let tracker = LocalResponseTracker()
        let held = SuperHTTPHeldTerminals()
        let baseline = await budget.outstandingReservedBytes()
        // Both requests can finish in one batched decode step, so hold every
        // terminal with the persistent gate rather than a re-armed one-shot.
        await owner.bridge._testInstallPersistentTerminalGate { _ in await held.hold() }
        let headers: HTTPFields = [.contentType: "application/json", .authorization: "Bearer " + token]
        do {
            try await superAdmissionApplication(hook: hook, token: token, tokenizer: tokenizer,
                                                tracker: tracker).test(.live) { client in
                let port = try #require(client.port)
                let first = try SuperHTTPResetSocket(port: port, token: token,
                    body: try superAdmissionBody(image: false, stream: true))
                defer { first.close() }
                let second = try SuperHTTPResetSocket(port: port, token: token,
                    body: try superAdmissionBody(image: false, stream: true))
                defer { second.close() }
                #expect(try first.readUntilContent().contains("200 OK"))
                #expect(try second.readUntilContent().contains("200 OK"))
                try await superHTTPEventually("both requests held before terminal") { await held.count == 2 }
                let reserved = await budget.outstandingReservedBytes()
                try await client.execute(uri: "/v1/chat/completions", method: .post, headers: headers,
                    body: ByteBuffer(bytes: try superAdmissionBody(image: false, stream: true))) { response in
                    #expect(response.status == .tooManyRequests)
                    #expect(!String(buffer: response.body).contains("data:"))
                }
                #expect(await budget.outstandingReservedBytes() == reserved)
                await held.release()
                try await superHTTPEventually("held requests retired") {
                    let reserved = await budget.outstandingReservedBytes()
                    let active = await owner.bridge.activeRequestCount()
                    return reserved == baseline && active == 0 && tracker.activeCount == 0
                }
                try await client.execute(uri: "/v1/chat/completions", method: .post, headers: headers,
                    body: ByteBuffer(bytes: try superAdmissionBody(image: false, stream: true))) { response in
                    #expect(response.status == .ok)
                    #expect(String(buffer: response.body).contains("[DONE]"))
                }
                #expect(!(await held.timedOut))
            }
        } catch {
            await held.release()
            try await owner.closeAfterDrain()
            _ = await budget.finishPendingLoad(lease)
            throw error
        }
        await held.release()
        await hook.drain()
        try await owner.closeAfterDrain()
        #expect(residency.snapshot.usedBytes == 0)
        #expect(await budget.finishPendingLoad(lease))
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    @Test(.timeLimit(.minutes(3))) func speculatingOwnerHookServesTextAndRefusesImagesWith400() async throws {
        let fixture = try SuperMTPInstalledFixture().make()
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 16 << 30, active: 0, cache: 0, systemAvailable: .max) })
        let bytes = fixture.installed.receipt.payloadBytes
            + (try NemotronSuperLocalMTP.loadSupplementBytes(fixture.headQuote))
        let lease = try #require(await budget.claimPendingLoad(requestID: "super-http-mtp",
            weightBytes: UInt64(bytes), minimumKVBytes: 2 << 30))
        let tokenizer = TokenizerHandle(SuperRouteTokenizer())
        let owner = try await NemotronSuperLocalBridgeBuilder.make(installed: fixture.installed,
            tokenizer: tokenizer, eosTokenIDs: [63],
            sizing: .init(weightsBytes: fixture.installed.receipt.payloadBytes,
                fp16KVBytesPerToken: 64, maxContextLength: 64, defaultMaxTokens: 2),
            kvBytesCapacity: 2 << 30, kvBudget: budget, loadLease: lease,
            construction: fixture.construction,
            mtp: .init(module: fixture.head, setting: .init(depth: 1)), environment: [:])
        #expect(owner.speculates)
        let template = try #require(Data(base64Encoded: superImagePinnedTemplateBase64,
                                        options: .ignoreUnknownCharacters))
        // The hook takes the owner's text binding and never asks for media.
        let hook = try NemotronSuperLocalImageHTTP(owner: owner, templateBytes: template)
        let token = "synthetic-super-mtp-hook"
        let headers: HTTPFields = [.contentType: "application/json", .authorization: "Bearer " + token]
        let baseline = await budget.outstandingReservedBytes()
        try await superAdmissionApplication(hook: hook, token: token, tokenizer: tokenizer).test(.live) { client in
            for stream in [true, false] {
                try await client.execute(uri: "/v1/chat/completions", method: .post, headers: headers,
                    body: ByteBuffer(bytes: try superAdmissionBody(image: false, stream: stream))) { response in
                    #expect(response.status == .ok)
                    let text = String(buffer: response.body)
                    #expect(text.contains(stream ? "[DONE]" : "chat.completion"))
                    #expect(text.contains("\"content\":\"x") && !text.contains("\"error\""))
                }
                try await client.execute(uri: "/v1/chat/completions", method: .post, headers: headers,
                    body: ByteBuffer(bytes: try superAdmissionBody(image: true, stream: stream))) { response in
                    #expect(response.status == .badRequest)
                    let text = String(buffer: response.body)
                    #expect(text.contains("Media input is not supported.") && !text.contains("data:"))
                }
            }
        }
        #expect(await budget.outstandingReservedBytes() == baseline)
        let ownedEngine = await owner.bridge.ownedEngine
        // The served engine is the speculative build (a plain build has none).
        #expect((ownedEngine as? EngineV2)?.mtpMetricsSnapshot() != nil)
        await hook.drain()
        try await owner.closeAfterDrain()
        #expect(fixture.residency.snapshot.usedBytes == 0)
        #expect(await budget.finishPendingLoad(lease))
        #expect(await budget.outstandingReservedBytes() == 0)
    }
}

/// Holds every native pump before its terminal until released; a bounded
/// failsafe releases them if a failed assertion skips the explicit release.
private actor SuperHTTPHeldTerminals {
    private(set) var count = 0
    private(set) var released = false
    private(set) var timedOut = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var failsafe: Task<Void, Never>?

    func hold() async {
        count += 1
        guard !released else { return }
        if failsafe == nil {
            failsafe = Task {
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                self.release(timedOut: true)
            }
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release(timedOut: Bool = false) {
        guard !released else { return }
        released = true
        self.timedOut = timedOut
        failsafe?.cancel()
        failsafe = nil
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}
