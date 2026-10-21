import Foundation
import Darwin
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import MLXLMCommon
@testable import MLXVLM
import NIOCore
import Testing
@testable import ProviderCore

private actor SuperHTTPAccounting {
    var acquired = 0
    var released = 0
    var draining = false
    func acquire() throws {
        guard !draining else { throw MultiModelBatchSchedulerEngineError.modelNotLoaded("drained fixture") }
        acquired += 1
    }
    func release() { released += 1 }
    func drain() { draining = true }
}

/// Live loopback HTTP, actual native bridge and tiny synthetic weights/tokenizer.
/// This does not install or advertise a production model or prove tokenizer parity.
struct NemotronSuperLocalHTTPTests {
    @Test(.timeLimit(.minutes(1))) func liveHTTPTextStreamingAuthErrorsAndRestart() async throws {
        let (installed, construction, residency) = try SuperInstalledFixture().make()
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: .max) })
        let lease = try #require(await budget.claimPendingLoad(requestID: "super-http-fixture",
            weightBytes: UInt64(installed.receipt.payloadBytes), minimumKVBytes: 2 << 30))
        let tokenizer = TokenizerHandle(SuperSyntheticTokenizer())
        let owner = try await NemotronSuperLocalBridgeBuilder.make(installed: installed, tokenizer: tokenizer,
            eosTokenIDs: [31], sizing: .init(weightsBytes: installed.receipt.payloadBytes,
                fp16KVBytesPerToken: 64, maxContextLength: 64, defaultMaxTokens: 2),
            kvBytesCapacity: 2 << 30, kvBudget: budget, loadLease: lease,
            construction: construction, environment: [:])
        let bridge = owner.bridge
        let accounting = SuperHTTPAccounting()
        let model = NemotronSuperLocalBinding.modelID
        // New server instances bind ephemeral loopback ports over the same owned
        // fixture bridge. No live provider cache, credentials or registry are used.
        for _ in 0..<2 {
            let app = makeLocalInferenceApplication(
                config: .init(host: "127.0.0.1", port: 0, authToken: "synthetic-super-fixture"),
                defaultMaxTokens: 2, acquire: { requested in
                    guard requested == model else {
                        throw MultiModelBatchSchedulerEngineError.modelNotLoaded(requested)
                    }
                    try await accounting.acquire()
                    return .init(tokenizer: tokenizer,
                        releaseToken: OneShotRelease(release: { _ in await accounting.release() }, modelId: model),
                        modelType: "nemotron_h_omni", engineV2Bridge: bridge)
                }, tokenizerProvider: { _ in .init(tokenizer: tokenizer, modelType: "nemotron_h_omni") },
                availableModels: { [model] }, mtpSlots: { [] },
                modelTypeProvider: { _ in "nemotron_h_omni" })
            try await app.test(.live) { client in
                let body = ByteBuffer(string: "{\"model\":\"\(model)\",\"stream\":true,\"max_tokens\":2,\"messages\":[{\"role\":\"user\",\"content\":\"fixture\"}]}")
                let before = await accounting.acquired
                try await client.execute(uri: "/v1/chat/completions", method: .post,
                    headers: [.contentType: "application/json"], body: body) { response in
                    #expect(response.status == .unauthorized)
                }
                #expect(await accounting.acquired == before)
                let headers: HTTPFields = [.contentType: "application/json",
                    .authorization: "Bearer synthetic-super-fixture"]
                try await client.execute(uri: "/v1/models", method: .get, headers: headers) { response in
                    #expect(response.status == .ok)
                    #expect(String(buffer: response.body).contains(model))
                }
                try await client.execute(uri: "/v1/chat/completions", method: .post,
                    headers: headers, body: body) { response in
                    #expect(response.status == .ok)
                    let output = String(buffer: response.body)
                    #expect(output.contains("[DONE]"))
                    #expect(output.contains("chat.completion.chunk"))
                    #expect(output.contains("x"))
                }
                try await client.execute(uri: "/v1/chat/completions", method: .post,
                    headers: headers, body: ByteBuffer(string: "{")) { response in
                    #expect(response.status == .badRequest)
                }
            }
        }
        await accounting.drain()
        #expect(await accounting.acquired == 2)
        #expect(await accounting.released == 2)
        try await owner.closeAfterDrain()
        #expect(residency.snapshot.usedBytes == 0)
        #expect(await budget.finishPendingLoad(lease))
        #expect(await budget.outstandingReservedBytes() == 0)
    }
}


extension NemotronSuperLocalHTTPTests {
    @Test(.timeLimit(.minutes(2))) func liveHTTPInlineImagesUseOwnerAndPreserveErrors() async throws {
        let dimensions = NemotronRadioDimensions(width: 2, layers: 1, heads: 1,
            channels: 3, patch: 16, positionSide: 32, prefix: 1, mlpWidth: 3)
        let (installed, construction, residency) = try SuperInstalledFixture(radioDimensions: dimensions).make()
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: .max) })
        let lease = try #require(await budget.claimPendingLoad(requestID: "super-image-http-fixture",
            weightBytes: UInt64(installed.receipt.payloadBytes), minimumKVBytes: 2 << 30))
        let tokenizer = TokenizerHandle(SuperSyntheticImageTokenizer())
        let owner = try await NemotronSuperLocalBridgeBuilder.make(installed: installed,
            tokenizer: tokenizer, eosTokenIDs: [31],
            sizing: .init(weightsBytes: installed.receipt.payloadBytes, fp16KVBytesPerToken: 64,
                maxContextLength: 1024, defaultMaxTokens: 2), kvBytesCapacity: 2 << 30,
            kvBudget: budget, loadLease: lease, construction: construction, environment: [:])
        let template = try #require(Data(base64Encoded: superImagePinnedTemplateBase64,
                                        options: .ignoreUnknownCharacters))
        let hook = try NemotronSuperLocalImageHTTP(owner: owner, templateBytes: template)
        let accounting = SuperHTTPAccounting()
        let model = NemotronSuperLocalBinding.modelID
        let png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAF0lEQVR4nGP4z8BAEiJN9aiGUQ1DSgMAkPn/Afnh+ngAAAAASUVORK5CYII="
        @Sendable func body(image: String, stream: Bool = false, thinking: Bool? = false,
                  extra: [String: Any] = [:]) throws -> ByteBuffer {
            var value: [String: Any] = ["model": model, "stream": stream, "temperature": 0,
                "max_tokens": 2, "messages": [["role": "user", "content": [
                    ["type": "text", "text": "fixture"],
                    ["type": "image_url", "image_url": ["url": image]]]]]]
            if let thinking { value["enable_thinking"] = thinking }
            value.merge(extra) { _, new in new }
            return ByteBuffer(bytes: try JSONSerialization.data(withJSONObject: value))
        }
        func application(hook: NemotronSuperLocalImageHTTP?) -> LocalInferenceApplication {
            makeLocalInferenceApplication(
                config: .init(host: "127.0.0.1", port: 0, authToken: "synthetic-super-image"),
                defaultMaxTokens: 2, acquire: { requested in
                    try await accounting.acquire()
                    throw MultiModelBatchSchedulerEngineError.modelNotLoaded(requested)
                }, tokenizerProvider: { _ in .init(tokenizer: tokenizer, modelType: "nemotron_h_omni") },
                availableModels: { [] }, mtpSlots: { [] },
                modelTypeProvider: { _ in "nemotron_h_omni" }, nemotronSuperImageHTTP: hook)
        }
        let headers: HTTPFields = [.contentType: "application/json",
                                  .authorization: "Bearer synthetic-super-image"]
        let baseline = await budget.outstandingReservedBytes()
        try await application(hook: nil).test(.live) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post,
                headers: headers, body: try body(image: png)) { response in
                #expect(response.status != .ok)
            }
        }
        let fallbackBeforeHook = await accounting.acquired
        try await application(hook: hook).test(.live) { client in
            // The existing upload limit rejects before raw-hook selection.
            try await client.execute(uri: "/v1/chat/completions", method: .post,
                headers: headers,
                body: ByteBuffer(bytes: [UInt8](repeating: 0, count: localInferenceMaxUploadBytes + 1))) { response in
                #expect(response.status == .contentTooLarge)
            }
        }
        // Two independent loopback binds exercise server restart with the same
        // dedicated owner, without publishing the model in discovery.
        for _ in 0..<2 {
            try await application(hook: hook).test(.live) { client in
                try await client.execute(uri: "/v1/chat/completions", method: .post,
                    headers: [.contentType: "application/json"], body: try body(image: png)) { response in
                    #expect(response.status == .unauthorized)
                }
                try await client.execute(uri: "/v1/models", method: .get, headers: headers) { response in
                    #expect(response.status == .ok)
                    #expect(!String(buffer: response.body).contains(model))
                }
                // Thinking defaults on (template default); generated text then
                // stays in the reference reasoning channel until `</think>`.
                for stream in [false, true] {
                    for thinking in [false, true, nil] as [Bool?] {
                        try await client.execute(uri: "/v1/chat/completions", method: .post,
                            headers: headers, body: try body(image: png, stream: stream,
                                                             thinking: thinking)) { response in
                            #expect(response.status == .ok)
                            #expect(response.headers[.accessControlAllowOrigin] == "*")
                            let output = String(buffer: response.body)
                            #expect(output.contains(stream ? "[DONE]" : "chat.completion"))
                            #expect(!output.contains("\"error\""))
                            #expect(output.contains(thinking == false ? "\"content\":\"x" : "\"reasoning_content\":\"x"))
                        }
                    }
                }
                for invalid in [try body(image: "https://example.invalid/never-fetch.png", stream: true),
                                try body(image: "data:image/jpeg;base64,AA==", stream: true),
                                try body(image: png, extra: ["enable_thinking": false,
                                    "chat_template_kwargs": ["enable_thinking": true]]),
                                try body(image: png, extra: ["response_format": ["type": "json_object"]]),
                                ByteBuffer(string: "{")] {
                    try await client.execute(uri: "/v1/chat/completions", method: .post,
                        headers: headers, body: invalid) { response in
                        #expect(response.status == .badRequest)
                        #expect(String(buffer: response.body).contains("error"))
                        #expect(!String(buffer: response.body).contains("never-fetch"))
                    }
                }
            }
            #expect(await budget.outstandingReservedBytes() == baseline)
        }
        #expect(await accounting.acquired == fallbackBeforeHook)
        try await owner.closeAfterDrain()
        try await application(hook: hook).test(.live) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post,
                headers: headers, body: try body(image: png)) { response in
                #expect(response.status == .serviceUnavailable)
            }
            // Auth still wins over a drained owner and malformed media.
            try await client.execute(uri: "/v1/chat/completions", method: .post,
                body: try body(image: "invalid")) { response in
                #expect(response.status == .unauthorized)
            }
        }
        #expect(residency.snapshot.usedBytes == 0)
        #expect(await budget.finishPendingLoad(lease))
        #expect(await budget.outstandingReservedBytes() == 0)
    }
}


extension NemotronSuperLocalHTTPTests {
    /// Size and context bounds are the request's own, so a retry elsewhere
    /// cannot help: each refusal is 400, not the retryable 503, and holds no
    /// reservation. One image is at least 256 visual tokens, so a 256-token
    /// context admits its tokens but never its prompt.
    @Test(.timeLimit(.minutes(2))) func imageRequestsOutsideTheirBoundsAreRefusedWith400() async throws {
        let dimensions = NemotronRadioDimensions(width: 2, layers: 1, heads: 1,
            channels: 3, patch: 16, positionSide: 32, prefix: 1, mlpWidth: 3)
        let (installed, construction, residency) = try SuperInstalledFixture(radioDimensions: dimensions).make()
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: .max) })
        let lease = try #require(await budget.claimPendingLoad(requestID: "super-image-http-bounds",
            weightBytes: UInt64(installed.receipt.payloadBytes), minimumKVBytes: 2 << 30))
        let tokenizer = TokenizerHandle(SuperSyntheticImageTokenizer())
        let owner = try await NemotronSuperLocalBridgeBuilder.make(installed: installed,
            tokenizer: tokenizer, eosTokenIDs: [31],
            sizing: .init(weightsBytes: installed.receipt.payloadBytes, fp16KVBytesPerToken: 64,
                maxContextLength: 256, defaultMaxTokens: 2), kvBytesCapacity: 2 << 30,
            kvBudget: budget, loadLease: lease, construction: construction, environment: [:])
        let template = try #require(Data(base64Encoded: superImagePinnedTemplateBase64,
                                        options: .ignoreUnknownCharacters))
        let hook = try NemotronSuperLocalImageHTTP(owner: owner, templateBytes: template)
        let token = "synthetic-super-bounds"
        let app = makeLocalInferenceApplication(
            config: .init(host: "127.0.0.1", port: 0, authToken: token), defaultMaxTokens: 2,
            acquire: { id in throw MultiModelBatchSchedulerEngineError.modelNotLoaded(id) },
            tokenizerProvider: { _ in .init(tokenizer: tokenizer, modelType: "nemotron_h_omni") },
            availableModels: { [] }, mtpSlots: { [] },
            modelTypeProvider: { _ in "nemotron_h_omni" }, nemotronSuperImageHTTP: hook)
        let png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAF0lEQVR4nGP4z8BAEiJN9aiGUQ1DSgMAkPn/Afnh+ngAAAAASUVORK5CYII="
        func body(images: Int, text: String = "fixture") throws -> ByteBuffer {
            let parts: [[String: Any]] = [["type": "text", "text": text]]
                + Array(repeating: ["type": "image_url", "image_url": ["url": png]], count: images)
            return ByteBuffer(bytes: try JSONSerialization.data(withJSONObject: [
                "model": NemotronSuperLocalBinding.modelID, "stream": true, "temperature": 0,
                "max_tokens": 2, "enable_thinking": false, "messages": [["role": "user", "content": parts]]]))
        }
        let refusals = [
            ("body over the 8 MiB encoded ceiling", try body(images: 1, text: String(repeating: "x", count: 8 << 20))),
            ("512 visual tokens beyond the context", try body(images: 2)),
            ("prompt beyond the context", try body(images: 1)),
        ]
        let headers: HTTPFields = [.contentType: "application/json", .authorization: "Bearer " + token]
        let baseline = await budget.outstandingReservedBytes()
        try await app.test(.live) { client in
            for (name, request) in refusals {
                try await client.execute(uri: "/v1/chat/completions", method: .post,
                    headers: headers, body: request) { response in
                    #expect(response.status == .badRequest, "\(name)")
                    #expect(String(buffer: response.body).contains("\"error\""), "\(name)")
                }
                #expect(await budget.outstandingReservedBytes() == baseline, "\(name)")
            }
        }
        try await owner.closeAfterDrain()
        #expect(residency.snapshot.usedBytes == 0)
        #expect(await budget.finishPendingLoad(lease))
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    @Test(.timeLimit(.minutes(1))) func imageHTTPResetRetainsChargeUntilTerminalRetires() async throws {
        let dimensions = NemotronRadioDimensions(width: 2, layers: 1, heads: 1,
            channels: 3, patch: 16, positionSide: 32, prefix: 1, mlpWidth: 3)
        let (installed, construction, residency) = try SuperInstalledFixture(radioDimensions: dimensions).make()
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: .max) })
        let lease = try #require(await budget.claimPendingLoad(requestID: "super-image-http-reset",
            weightBytes: UInt64(installed.receipt.payloadBytes), minimumKVBytes: 2 << 30))
        let tokenizer = TokenizerHandle(SuperSyntheticImageTokenizer())
        let owner = try await NemotronSuperLocalBridgeBuilder.make(installed: installed,
            tokenizer: tokenizer, eosTokenIDs: [31],
            sizing: .init(weightsBytes: installed.receipt.payloadBytes, fp16KVBytesPerToken: 64,
                maxContextLength: 1024, defaultMaxTokens: 2), kvBytesCapacity: 2 << 30,
            kvBudget: budget, loadLease: lease, construction: construction, environment: [:])
        let template = try #require(Data(base64Encoded: superImagePinnedTemplateBase64,
                                        options: .ignoreUnknownCharacters))
        let hook = try NemotronSuperLocalImageHTTP(owner: owner, templateBytes: template)
        let tracker = LocalResponseTracker()
        let gate = SuperHTTPTerminalGate()
        let disconnect = SuperHTTPDisconnectWitness()
        let baseline = await budget.outstandingReservedBytes()
        let model = NemotronSuperLocalBinding.modelID
        let token = "synthetic-super-reset"
        let data = try JSONSerialization.data(withJSONObject: [
            "model": model, "stream": true, "max_tokens": 2, "temperature": 0,
            "enable_thinking": false,
            "messages": [["role": "user", "content": [
                ["type": "text", "text": "fixture"],
                ["type": "image_url", "image_url": ["url":
                    "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAF0lEQVR4nGP4z8BAEiJN9aiGUQ1DSgMAkPn/Afnh+ngAAAAASUVORK5CYII="]]]]]
        ])
        let app = makeLocalInferenceApplication(
            config: .init(host: "127.0.0.1", port: 0, authToken: token), defaultMaxTokens: 2,
            acquire: { id in throw MultiModelBatchSchedulerEngineError.modelNotLoaded(id) },
            tokenizerProvider: { _ in .init(tokenizer: tokenizer, modelType: "nemotron_h_omni") },
            availableModels: { [] }, mtpSlots: { [] }, responseTracker: tracker,
            modelTypeProvider: { _ in "nemotron_h_omni" }, nemotronSuperImageHTTP: hook)
        // The existing debug seam holds a real pump after its content events but
        // before terminal observation/refunds. This proves streamed-response
        // cancellation during retirement, not cancellation during active decode.
        await owner.bridge._testInstallCancelledSettlementHooks(
            beforeNativeTerminal: { _ in
                // The real HTTP request task-local is inherited by the bridge
                // pump. Register against that exact connection's scope rather
                // than using response-body retirement as a disconnect signal.
                let scope = LocalRequestCancellation.current
                let registration = scope?.register { disconnect.observeCancellation() }
                disconnect.observeScope(scope != nil)
                defer { registration?.remove() }
                await gate.hold()
            }, onSettlementWait: {})
        do {
            try await app.test(.live) { client in
                let socket = try SuperHTTPResetSocket(port: try #require(client.port), token: token, body: data)
                defer { socket.close() }
                do {
                    let prefix = try socket.readUntilContent()
                    #expect(prefix.contains("200 OK"))
                    #expect(!prefix.contains("[DONE]"))
                    try await superHTTPEventually("terminal gate entered") { await gate.entered }
                    try #require(!(await gate.released))
                    try #require(disconnect.registered, "Native pump must inherit this HTTP request's cancellation scope")
                    #expect(!disconnect.cancelled)
                    #expect(tracker.activeCount == 1)
                    #expect(await budget.outstandingReservedBytes() > baseline)
                    #expect(await owner.bridge._testLivePumpCount() == 1)
                    socket.close() // SO_LINGER=0 produces an actual transport RST.
                    try await superHTTPEventually("reset reached its exact request cancellation scope") {
                        disconnect.cancelled
                    }
                    // The transport may already have retired the reset body, so
                    // the response tracker can read 0 or 1 here. A transport abort
                    // is not native completion: the held pump and the real
                    // media/KV charges must remain until its gate opens, and the
                    // tracker reaches 0 once it has (checked below).
                    try #require(!(await gate.released))
                    #expect(await budget.outstandingReservedBytes() > baseline)
                    #expect(await owner.bridge._testLivePumpCount() == 1)
                    let headers: HTTPFields = [.authorization: "Bearer " + token]
                    try await client.execute(uri: "/v1/models", method: .get, headers: headers) { response in
                        #expect(response.status == .ok)
                        #expect(!String(buffer: response.body).contains(model))
                    }
                    await gate.release()
                    try await superHTTPEventually("reset native work retired") {
                        let reserved = await budget.outstandingReservedBytes()
                        let active = await owner.bridge.activeRequestCount()
                        let pumps = await owner.bridge._testLivePumpCount()
                        return reserved == baseline && active == 0 && pumps == 0 && tracker.activeCount == 0
                    }
                    // Same owner and a separate HTTP connection remain usable.
                    try await client.execute(uri: "/v1/chat/completions", method: .post,
                        headers: [.contentType: "application/json", .authorization: "Bearer " + token],
                        body: ByteBuffer(bytes: data)) { response in
                        #expect(response.status == .ok)
                        #expect(String(buffer: response.body).contains("[DONE]"))
                        #expect(String(buffer: response.body).contains("x"))
                    }
                    try await superHTTPEventually("surviving connection retired") {
                        let reserved = await budget.outstandingReservedBytes()
                        return reserved == baseline && tracker.activeCount == 0
                    }
                    #expect(!(await gate.timedOut))
                } catch {
                    socket.close()
                    await gate.release()
                    throw error
                }
            }
        } catch {
            // Always release the bounded latch before draining; a failed assertion
            // must not strand a pump or turn cleanup into an unbounded wait.
            await gate.release()
            try await owner.closeAfterDrain()
            _ = await budget.finishPendingLoad(lease)
            throw error
        }
        await gate.release()
        try await owner.closeAfterDrain()
        #expect(residency.snapshot.usedBytes == 0)
        #expect(await budget.finishPendingLoad(lease))
        #expect(await budget.outstandingReservedBytes() == 0)
    }
}

actor SuperHTTPTerminalGate {
    private(set) var entered = false
    private(set) var released = false
    private(set) var timedOut = false
    private var waiter: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        guard !released else { return }
        // Independent bounded failsafe: transport/read assertion failures cannot
        // hold a native pump forever, even if the explicit catch cleanup fails.
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(20)) }
            catch { return }
            self.release(timedOut: true)
        }
        await withCheckedContinuation { waiter = $0 }
        timeout.cancel()
    }
    func release(timedOut: Bool = false) {
        guard !released else { return }
        released = true; self.timedOut = timedOut
        waiter?.resume(); waiter = nil
    }
}

func superHTTPEventually(_ description: String,
    _ predicate: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !(await predicate()), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(await predicate(), "Timed out waiting for \(description)")
}

/// Adapted from DiffusionGemmaConcurrencyLiveTests.ResetSocket. A new private
/// loopback connection is the only descriptor reset; no shared client connection
/// pool or process-global socket state is changed.
final class SuperHTTPResetSocket {
    private var descriptor: Int32 = -1
    init(port: Int, token: String, body: Data) throws {
        descriptor = try Self.connect(port: port)
        do {
            var noSignal: Int32 = 1
            try #require(setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                                   socklen_t(MemoryLayout.size(ofValue: noSignal))) == 0)
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            try #require(setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                                   socklen_t(MemoryLayout.size(ofValue: timeout))) == 0)
            timeout = timeval(tv_sec: 0, tv_usec: 200_000)
            try #require(setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                                   socklen_t(MemoryLayout.size(ofValue: timeout))) == 0)
            var reset = linger(l_onoff: 1, l_linger: 0)
            try #require(setsockopt(descriptor, SOL_SOCKET, SO_LINGER, &reset,
                                   socklen_t(MemoryLayout.size(ofValue: reset))) == 0)
            let header = "POST /v1/chat/completions HTTP/1.1\r\nHost: localhost:\(port)\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            let payload = Data(header.utf8) + body
            try payload.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.send(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                    if count < 0 && errno == EINTR { continue }
                    try #require(count > 0)
                    offset += count
                }
            }
        } catch { close(); throw error }
    }
    private static func connect(port: Int) throws -> Int32 {
        guard (1...65535).contains(port) else { throw POSIXError(.EINVAL) }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_flags = AI_NUMERICSERV
        var addresses: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo("localhost", String(port), &hints, &addresses)
        guard status == 0, let addresses else { throw POSIXError(.EINVAL) }
        defer { freeaddrinfo(addresses) }
        var next: UnsafeMutablePointer<addrinfo>? = addresses
        while let candidate = next {
            let address = candidate.pointee; next = address.ai_next
            let socket = Darwin.socket(address.ai_family, address.ai_socktype, address.ai_protocol)
            if socket < 0 { continue }
            if Darwin.connect(socket, address.ai_addr, address.ai_addrlen) == 0 { return socket }
            Darwin.close(socket)
        }
        throw POSIXError(.ECONNREFUSED)
    }
    func readUntilContent() throws -> String {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var result = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while ContinuousClock.now < deadline && result.count < 64 * 1024 {
            let count = Darwin.recv(descriptor, &bytes, bytes.count, 0)
            if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
            try #require(count > 0, "Socket ended before a streamed content delta")
            result.append(contentsOf: bytes.prefix(count))
            let text = String(decoding: result, as: UTF8.self)
            if text.contains("\"content\":\"x") { return text }
        }
        throw POSIXError(.ETIMEDOUT)
    }
    func close() {
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
    }
    deinit { close() }
}


/// Direct witness on the reset request's actual transport cancellation scope.
/// The terminal latch keeps this registration alive until native retirement.
private final class SuperHTTPDisconnectWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var hasScope = false
    private var didCancel = false
    var registered: Bool { lock.withLock { hasScope } }
    var cancelled: Bool { lock.withLock { didCancel } }
    func observeScope(_ present: Bool) { lock.withLock { hasScope = present } }
    func observeCancellation() { lock.withLock { didCancel = true } }
}
