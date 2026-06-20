/// Integration tests for the Swift provider that drive the entire local stack
/// against a `MockCoordinator` (Hummingbird-hosted) on a system-assigned
/// loopback port. These exercise the real WebSocket transport, the real
/// libsodium NaCl box, and the real HTTP clients used by `EnrollmentService`,
/// `ModelCatalogClient`, `TelemetryClient`, and `UpdateBanner`. The only thing
/// faked here is the inference engine output -- inside the WebSocket handler
/// loop we yield canned chunks instead of going through `BatchScheduler`,
/// since that path requires MLX + a real model on disk.
///
/// Skipped in CI release builds (see `.github/workflows/release-swift.yml`):
///     swift test --skip CoordinatorIntegrationTests
///
/// They run locally with `swift test --filter CoordinatorIntegrationTests`.

import Foundation
import Testing
@testable import ProviderCore

// MARK: - Suite
//
// The suite name is the contract: `--skip CoordinatorIntegrationTests` (already
// wired into `.github/workflows/release-swift.yml`) drops every test below
// from CI. The suite is `.serialized` because the telemetry test exercises
// `TelemetryClient.shared` (a process-wide singleton) and other tests would
// otherwise race against its configure/shutdown cycle.

@Suite("CoordinatorIntegrationTests", .serialized)
struct CoordinatorIntegrationTests {

    // MARK: 1. Registration + attestation challenge round-trip

    @Test("CoordinatorClient registers with backend=mlx-swift and answers attestation challenges")
    func coordinatorRegistrationAndAttestationChallengeRoundTrip() async throws {
        let mock = MockCoordinator()
        let baseURL = try await mock.start()
        defer { Task { await mock.shutdown() } }

        let keys = NodeKeyPair.generate()
        let coordinator = makeClient(
            url: baseURL.mockProviderWebSocketURL(),
            publicKey: keys.publicKeyBase64
        )
        let (events, sendFn) = await coordinator.start()
        let send = SendHandle(sendFn)

        defer { Task { await coordinator.shutdown() } }

        let register = try await mock.awaitFirstRegister(timeout: .seconds(5))
        try #require(register != nil)
        let r = try #require(register)
        #expect(r.backend == "mlx-swift")
        #expect(r.publicKey == keys.publicKeyBase64)
        #expect(r.encryptedResponseChunks == true)
        let caps = try #require(r.privacyCapabilities)
        #expect(caps.textBackendInprocess == true)
        #expect(caps.textProxyDisabled == true)

        // Drive an attestation challenge through the wire and respond from the
        // test side using a canned signature. We're not validating Secure
        // Enclave material here -- only the message flow.
        try await mock.pushAttestationChallenge(nonce: "bm9uY2U=", timestamp: "2026-04-30T12:00:00Z")

        var sawChallenge = false
        await consumeEvents(events) { event in
            if case .attestationChallenge(let nonce, let ts) = event {
                #expect(nonce == "bm9uY2U=")
                #expect(ts == "2026-04-30T12:00:00Z")
                send.send(.attestationResponse(AttestationResponsePayload(
                    nonce: nonce,
                    signature: "fake-sig",
                    statusSignature: nil,
                    publicKey: keys.publicKeyBase64,
                    sipEnabled: true,
                    binaryHash: String(repeating: "b", count: 64)
                )))
                sawChallenge = true
                return .stop
            }
            return .keepGoing
        }
        #expect(sawChallenge)

        let s = try await mock.waitForSnapshot(timeout: .seconds(5)) {
            !$0.attestationResponses.isEmpty
        }
        let snap = try #require(s)
        let response = try #require(snap.attestationResponses.first)
        #expect(response.nonce == "bm9uY2U=")
        #expect(response.signature == "fake-sig")
        #expect(response.publicKey == keys.publicKeyBase64)
    }

    // MARK: 2. End-to-end encryption + cancellation

    @Test("inference_request decrypts, response chunks encrypt, cancel triggers status 499")
    func inferenceRequestE2EEncryptionAndCancellation() async throws {
        let mock = MockCoordinator()
        let baseURL = try await mock.start()
        defer { Task { await mock.shutdown() } }

        let providerKeys = NodeKeyPair.generate()
        let coordinator = makeClient(
            url: baseURL.mockProviderWebSocketURL(),
            publicKey: providerKeys.publicKeyBase64
        )
        let (events, sendFn) = await coordinator.start()
        let send = SendHandle(sendFn)
        defer { Task { await coordinator.shutdown() } }

        // Wait for the initial register so we know the WS handshake completed.
        let register = try await mock.awaitFirstRegister(timeout: .seconds(5))
        try #require(register != nil)

        // Build a real ChatCompletionRequest payload.
        let chat = ChatCompletionRequest(
            model: "mlx-community/Qwen3-0.6B-8bit",
            messages: [.init(role: "user", content: "ping")],
            stream: true
        )
        let chatJSON = try JSONEncoder().encode(chat)
        let requestId = "req-int-test-1"

        // Generate a "consumer" keypair on the test side -- the mock will
        // encrypt to the provider's public key using this as the ephemeral.
        // We do NOT short-circuit the libsodium box here: the encryption is
        // real, the decryption inside CoordinatorClient is real.
        try await mock.pushInferenceRequest(
            requestId: requestId,
            providerPublicKeyBase64: providerKeys.publicKeyBase64,
            chatRequestJSON: chatJSON
        )

        // Run a tiny "fake provider loop":
        //   1. decrypt inference_request, verify the chat request
        //   2. send inference_accepted
        //   3. encrypt canned chunks back to the consumer ephemeral key
        //   4. on cancel, send inference_error with status 499 and stop
        // We capture cross-thread state into a Sendable box so swift 6 strict
        // concurrency stays happy.
        let cannedChunks = ["data: hello", "data:  world"]
        let stateBox = LoopStateBox()
        let providerKp = providerKeys
        let chatModel = chat.model
        let chunksToSend = cannedChunks

        let testTask: Task<Void, Never> = Task { [stateBox] in
            for await event in events {
                switch event {
                case .inferenceRequest(let rid, let ciphertext, let senderKey):
                    #expect(rid == requestId)
                    guard let key = senderKey else {
                        Issue.record("missing sender public key")
                        continue
                    }
                    stateBox.setConsumerEphemeralKey(key)
                    do {
                        let plaintext = try providerKp.decrypt(
                            senderPublicKey: key,
                            ciphertext: ciphertext
                        )
                        let decoded = try JSONDecoder().decode(
                            ChatCompletionRequest.self, from: plaintext)
                        #expect(decoded.model == chatModel)
                        #expect(decoded.messages.first?.content == "ping")
                    } catch {
                        Issue.record("decrypt failed: \(error)")
                    }

                    send.send(.inferenceAccepted(requestId: rid))
                    for text in chunksToSend {
                        let encrypted = try? providerKp.encryptPayload(
                            recipientPublicKey: key,
                            plaintext: Data(text.utf8)
                        )
                        send.send(.inferenceChunk(
                            requestId: rid,
                            data: "",
                            encryptedData: encrypted
                        ))
                    }

                case .cancel(let rid):
                    #expect(rid == requestId)
                    stateBox.markCanceled()
                    send.send(.inferenceError(
                        requestId: rid,
                        error: "request cancelled",
                        statusCode: 499,
                        errorReason: nil
                    ))
                    return

                default:
                    continue
                }
            }
        }

        // Wait until the mock has captured both the accepted message and the
        // chunks, then push a cancel.
        let preCancel = try await mock.waitForSnapshot(timeout: .seconds(5)) {
            !$0.inferenceAccepted.isEmpty && $0.inferenceChunks.count >= cannedChunks.count
        }
        let preSnap = try #require(preCancel)
        #expect(preSnap.inferenceAccepted.first?.requestId == requestId)
        #expect(preSnap.inferenceChunks.count >= cannedChunks.count)

        // The chunks were encrypted to the consumer's ephemeral key (the one
        // the mock generated and the provider extracted on decrypt). We can't
        // decrypt them on the test side without the consumer secret key; what
        // we *can* verify is the wire shape: encrypted_data is non-nil, the
        // ciphertext is valid base64, and the embedded ephemeralPublicKey is
        // the provider's own (per the response-encryption contract).
        for chunk in preSnap.inferenceChunks.prefix(cannedChunks.count) {
            let payload = try #require(chunk.encryptedData)
            #expect(!payload.ciphertext.isEmpty)
            #expect(Data(base64Encoded: payload.ciphertext) != nil)
            #expect(payload.ephemeralPublicKey == providerKeys.publicKeyBase64)
        }
        #expect(stateBox.consumerEphemeralKey() != nil)

        try await mock.pushCancel(requestId: requestId)

        let post = try await mock.waitForSnapshot(timeout: .seconds(5)) {
            !$0.inferenceErrors.isEmpty
        }
        let postSnap = try #require(post)
        let err = try #require(postSnap.inferenceErrors.first)
        #expect(err.statusCode == 499)
        #expect(err.requestId == requestId)
        _ = await testTask.value
        #expect(stateBox.isCanceled())
    }

    // MARK: 3. Reconnect after WS drop

    @Test("CoordinatorClient reconnects after the server drops the WS")
    func coordinatorReconnectAfterDrop() async throws {
        let mock = MockCoordinator()
        let baseURL = try await mock.start()
        defer { Task { await mock.shutdown() } }

        let keys = NodeKeyPair.generate()
        let coordinator = makeClient(
            url: baseURL.mockProviderWebSocketURL(),
            publicKey: keys.publicKeyBase64,
            heartbeatInterval: 60
        )
        let (events, _) = await coordinator.start()

        // Drain events in the background so the AsyncStream doesn't fill up.
        let drainTask = Task {
            for await _ in events {}
        }
        defer {
            drainTask.cancel()
            Task { await coordinator.shutdown() }
        }

        // First registration.
        let first = try await mock.awaitFirstRegister(timeout: .seconds(5))
        try #require(first != nil)
        let countBefore = mock.snapshot().registers.count

        // Force-close the active WS.
        await mock.dropActiveWebSocket()

        // The provider should reconnect and re-send register. ExponentialBackoff
        // base is 1.0s, so we should see the second register within ~5s.
        let after = try await mock.waitForSnapshot(timeout: .seconds(10)) {
            $0.registers.count > countBefore
        }
        let snap = try #require(after)
        #expect(snap.registers.count >= countBefore + 1)
        #expect(snap.registers.last?.backend == "mlx-swift")
    }

    // MARK: 3b. Outbound delivery survives a reconnect (regression)

    /// Regression test for the outage where ~half the fleet got pinned
    /// `hardware/untrusted reason=timeout` after a coordinator restart.
    ///
    /// The outbound `AsyncStream` used to be created once in `start()` and
    /// reused across every reconnect. An `AsyncStream` is single-shot: once the
    /// first session's consumer task is cancelled on disconnect, the iterator is
    /// terminated, so the next session's forwarder task exited immediately and
    /// NO outbound message (attestation responses, inference replies) was ever
    /// sent again. Heartbeats/pings run on their own tasks, so the socket stayed
    /// up and the provider was never evicted — it just silently stopped
    /// answering challenges.
    ///
    /// Test #3 above only proves the provider *re-registers* after a drop, and
    /// registration uses `ws.send` directly (not the outbound stream), so it
    /// passed even with the bug. This test exercises the outbound stream
    /// specifically: it must still deliver an attestation response on the new
    /// connection.
    @Test("CoordinatorClient still delivers outbound messages after a reconnect")
    func outboundDeliverySurvivesReconnect() async throws {
        let mock = MockCoordinator()
        let baseURL = try await mock.start()
        defer { Task { await mock.shutdown() } }

        let keys = NodeKeyPair.generate()
        let coordinator = makeClient(
            url: baseURL.mockProviderWebSocketURL(),
            publicKey: keys.publicKeyBase64,
            heartbeatInterval: 60
        )
        let (events, sendFn) = await coordinator.start()
        let send = SendHandle(sendFn)
        defer { Task { await coordinator.shutdown() } }

        // Background drainer: answer every attestation challenge through the
        // stable `send` handle — the exact outbound path ProviderLoop uses.
        let drain = Task {
            for await event in events {
                if case .attestationChallenge(let nonce, _) = event {
                    send.send(.attestationResponse(AttestationResponsePayload(
                        nonce: nonce,
                        signature: "fake-sig",
                        statusSignature: nil,
                        publicKey: keys.publicKeyBase64,
                        sipEnabled: true,
                        binaryHash: String(repeating: "b", count: 64)
                    )))
                }
            }
        }
        defer { drain.cancel() }

        // First connection.
        let first = try await mock.awaitFirstRegister(timeout: .seconds(5))
        try #require(first != nil)
        let registersBefore = mock.snapshot().registers.count

        // Force a reconnect — what a coordinator restart / network blip does to
        // every provider at once.
        await mock.dropActiveWebSocket()

        // Provider reconnects and re-registers on a brand-new WebSocket.
        let reRegistered = try await mock.waitForSnapshot(timeout: .seconds(10)) {
            $0.registers.count > registersBefore
        }
        try #require(reRegistered != nil)

        // Push a challenge over the NEW connection. Pre-fix, the outbound
        // forwarder had already exited, so this response was silently dropped.
        try await mock.pushAttestationChallenge(
            nonce: "cmVjb25uZWN0",
            timestamp: "2026-05-31T08:00:00Z"
        )

        let after = try await mock.waitForSnapshot(timeout: .seconds(10)) {
            $0.attestationResponses.contains { $0.nonce == "cmVjb25uZWN0" }
        }
        let snap = try #require(
            after,
            "no attestation response after reconnect — outbound stream is dead"
        )
        let resp = try #require(snap.attestationResponses.first { $0.nonce == "cmVjb25uZWN0" })
        #expect(resp.publicKey == keys.publicKeyBase64)
    }

    // MARK: 4. EnrollmentService round-trip

    @Test("EnrollmentService either fetches the mocked profile or short-circuits as already-enrolled")
    func enrollmentRoundTripAgainstMockCoordinator() async throws {
        let mockBytes = Data("MOCK_PROFILE_<integration>".utf8)
        let mock = MockCoordinator(mobileConfig: mockBytes)
        let baseURL = try await mock.start()
        defer { Task { await mock.shutdown() } }

        let service = EnrollmentService()
        let result: EnrollmentResult
        do {
            result = try await service.enroll(
                coordinatorURL: baseURL.absoluteString,
                openSystemSettings: false
            )
        } catch EnrollmentError.serialNumberUnavailable {
            // Minimal CI image without a hardware serial. The round-trip
            // can't run on this host, but the mock is still validated by
            // every other test that hits /v1/enroll-adjacent endpoints.
            return
        } catch EnrollmentError.managedByOtherMDM {
            // Host machine is managed by a corporate MDM (e.g. Kandji on dev
            // workstations): macOS allows one MDM per device, so enroll now
            // correctly refuses before touching the network. The mock's wire
            // shape is still covered by the alreadyEnrolled branch on other
            // hosts; nothing more to verify here.
            return
        }

        if result.alreadyEnrolled {
            // Production short-circuits when an MDM profile is already
            // installed (true on most darkbloom dev workstations and CI
            // runners with the profile pre-loaded). The function never hit
            // our mock, so verify the mock's `/v1/enroll` independently to
            // ensure the wire shape matches what the production path would
            // consume on a fresh machine.
            let endpoint = baseURL.appendingPathComponent("v1/enroll")
            var post = URLRequest(url: endpoint)
            post.httpMethod = "POST"
            post.setValue("application/json", forHTTPHeaderField: "Content-Type")
            post.httpBody = try JSONSerialization.data(
                withJSONObject: ["serial_number": "ABC123"]
            )
            let (data, _) = try await URLSession.shared.data(for: post)
            #expect(data == mockBytes)
        } else {
            // Fresh machine: profile written to disk should match the mock.
            let written = try Data(contentsOf: result.profilePath)
            #expect(written == mockBytes)
            try? FileManager.default.removeItem(at: result.profilePath)
        }
    }

    // MARK: 5. ModelCatalogClient

    @Test("ModelCatalogClient fetches and decodes the mock catalog")
    func modelCatalogClientFetchesAndDecodes() async throws {
        let model = CatalogModel(
            id: "mlx-community/Test-Model",
            s3Name: "Test-Model",
            displayName: "Test Model",
            modelType: "text",
            sizeGb: 1.5,
            architecture: "test",
            description: "fixture",
            minRamGb: 8,
            active: true,
            weightHash: String(repeating: "e", count: 64)
        )
        let mock = MockCoordinator(catalog: [model])
        let baseURL = try await mock.start()
        defer { Task { await mock.shutdown() } }

        let client = ModelCatalogClient(coordinatorURL: baseURL.absoluteString)
        let catalog = try await client.fetchCatalog()
        #expect(catalog.count == 1)
        let m = try #require(catalog.first)
        #expect(m.id == model.id)
        #expect(m.s3Name == model.s3Name)
        #expect(m.displayName == model.displayName)
        #expect(m.weightHash == model.weightHash)
    }

    // MARK: 6. TelemetryClient flush

    @Test("TelemetryClient flushes events to /v1/telemetry/events on the mock")
    func telemetryClientFlushesToMockEndpoint() async throws {
        let mock = MockCoordinator()
        let baseURL = try await mock.start()
        defer { Task { await mock.shutdown() } }

        // Configure a fresh in-memory telemetry pipeline pointing at the mock.
        // maxBatch:1 makes each emit() trigger an immediate POST so the test
        // doesn't have to wait for the periodic flush timer.
        TelemetryClient.shared.configure(TelemetryClientConfig(
            coordinatorURL: baseURL.absoluteString,
            source: .provider,
            authToken: "test-token",
            version: "0.0.0-test",
            machineId: "test-machine",
            maxBatch: 1,
            flushIntervalSeconds: 0.5
        ))

        let messages = ["hello-1", "hello-2", "hello-3"]
        for m in messages {
            TelemetryClient.shared.emit(
                kind: .connectivity,
                severity: .info,
                message: m
            )
        }

        // Ensure the buffered events get flushed -- shutdown drains everything
        // synchronously and waits for in-flight HTTP sends to complete.
        await TelemetryClient.shared.shutdown()

        // The mock should have received at least one batch covering all three
        // messages. With maxBatch:1, we'd expect three batches; on slower
        // hosts a couple may coalesce, so check by total event count instead.
        let s = try await mock.waitForSnapshot(timeout: .seconds(5)) { snap in
            let total = snap.telemetryBatches.reduce(into: 0) { $0 += $1.events.count }
            return total >= messages.count
        }
        let snap = try #require(s)
        let allEvents = snap.telemetryBatches.flatMap(\.events)
        let received = Set(allEvents.map(\.message))
        for m in messages {
            #expect(received.contains(m), "expected event '\(m)' in \(received)")
        }
        // Stamping is applied: machine_id and version come through.
        #expect(allEvents.allSatisfy { $0.machineId == "test-machine" })
        #expect(allEvents.allSatisfy { $0.version == "0.0.0-test" })
    }

    // MARK: 7. UpdateBanner -- silent on same version

    @Test("UpdateBanner stays silent when /api/version reports the current version")
    func updateBannerSilentWhenSameVersion() async throws {
        let mock = MockCoordinator(
            version: MockVersionFixture(version: ProviderCore.version, changelog: nil)
        )
        let baseURL = try await mock.start()
        defer { Task { await mock.shutdown() } }

        let captured = await captureStderr {
            await UpdateBanner.run(
                coordinatorURL: baseURL.absoluteString,
                currentVersion: ProviderCore.version,
                timeout: 2.0
            )
        }
        #expect(captured.isEmpty, "expected no banner; got: \(captured)")
    }

    // MARK: 8. UpdateBanner -- prints when newer

    @Test("UpdateBanner prints to stderr when /api/version reports a newer version")
    func updateBannerPrintsWhenNewer() async throws {
        let mock = MockCoordinator(
            version: MockVersionFixture(version: "99.0.0", changelog: "Test changelog\nLine 2")
        )
        let baseURL = try await mock.start()
        defer { Task { await mock.shutdown() } }

        let captured = await captureStderr {
            await UpdateBanner.run(
                coordinatorURL: baseURL.absoluteString,
                currentVersion: "0.5.0",
                timeout: 2.0
            )
        }
        #expect(captured.contains("Update available"), "stderr: \(captured)")
        #expect(captured.contains("99.0.0"))
        #expect(captured.contains("darkbloom update"))
    }
}

// MARK: - Helpers

/// Build a CoordinatorClient configured for tests against a mock URL. Uses a
/// fixed hardware/model profile and skips registering wallet, attestation, etc.
private func makeClient(
    url: String,
    publicKey: String,
    heartbeatInterval: TimeInterval = 0.5
) -> CoordinatorClient {
    let cfg = CoordinatorClientConfig(
        url: url,
        hardware: integrationHardware(),
        models: [integrationModel()],
        backendName: "mlx-swift",
        heartbeatInterval: heartbeatInterval,
        publicKey: publicKey,
        privacyCapabilities: PrivacyCapabilities(
            textBackendInprocess: true,
            textProxyDisabled: true,
            pythonRuntimeLocked: false,
            dangerousModulesBlocked: false,
            sipEnabled: true,
            antiDebugEnabled: false,
            coreDumpsDisabled: false,
            envScrubbed: false,
            hypervisorActive: false
        )
    )
    return CoordinatorClient(
        config: cfg,
        stats: AtomicProviderStats(),
        state: ProviderState()
    )
}

private func integrationHardware() -> HardwareInfo {
    HardwareInfo(
        machineModel: "Mac16,5",
        chipName: "Apple M4 Max",
        chipFamily: .m4,
        chipTier: .max,
        memoryGb: 128,
        memoryAvailableGb: 124,
        cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
        gpuCores: 40,
        memoryBandwidthGbs: 546
    )
}

private func integrationModel() -> ModelInfo {
    ModelInfo(
        id: "mlx-community/Qwen3-0.6B-8bit",
        modelType: "qwen3",
        quantization: "8bit",
        sizeBytes: 700_000_000,
        estimatedMemoryGb: 1.0
    )
}

// MARK: Event consumer

/// Decision returned by an event-consumer body to either keep iterating or
/// stop draining the events stream.
private enum ConsumerControl {
    case keepGoing
    case stop
}

/// Drain `events` until the body returns `.stop` or the stream finishes.
/// Runs the body inline; the consumer is non-Sendable since it captures
/// test-local state.
private func consumeEvents(
    _ events: AsyncStream<CoordinatorEvent>,
    _ body: (CoordinatorEvent) -> ConsumerControl
) async {
    for await ev in events {
        if case .stop = body(ev) {
            return
        }
    }
}

// MARK: Sendable state box

/// Sendable scratchpad for the inference-cancellation test. Captures the
/// consumer-ephemeral pubkey from the inference request and a "did we see a
/// cancel" flag so the main test task can assert on them after the
/// inference-loop Task returns.
private final class LoopStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _consumerEphemeralKey: Data?
    private var _canceled: Bool = false

    func setConsumerEphemeralKey(_ key: Data) {
        lock.lock(); defer { lock.unlock() }
        _consumerEphemeralKey = key
    }

    func consumerEphemeralKey() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return _consumerEphemeralKey
    }

    func markCanceled() {
        lock.lock(); defer { lock.unlock() }
        _canceled = true
    }

    func isCanceled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _canceled
    }
}

// MARK: Stderr capture

/// Run the given async closure with stderr (FD 2) redirected into a Pipe and
/// return the bytes written to it as a UTF-8 string.
///
/// This is best-effort: only output that goes through `FileHandle.standardError`
/// or the C-level `stderr` is captured. swift-log's stderr handler routes
/// through STDERR_FILENO so the existing UpdateBanner banner (which calls
/// `FileHandle.standardError.write`) is captured.
private func captureStderr(_ body: () async -> Void) async -> String {
    let pipe = Pipe()
    let originalFD = dup(fileno(stderr))
    setvbuf(stderr, nil, _IONBF, 0)
    let pipeFD = pipe.fileHandleForWriting.fileDescriptor
    dup2(pipeFD, fileno(stderr))

    await body()

    fflush(stderr)
    dup2(originalFD, fileno(stderr))
    close(originalFD)
    try? pipe.fileHandleForWriting.close()

    let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
    return String(data: data, encoding: .utf8) ?? ""
}
