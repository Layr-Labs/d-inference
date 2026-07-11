import CryptoKit
import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

private struct ProviderLoopV2TestKeySource: ProviderJournalKeySource {
    let key: SymmetricKey
    func loadOrCreateKey() throws -> SymmetricKey { key }
}

private struct ProviderLoopV2TestSigner: TerminalDigestSigner {
    let key = P256.Signing.PrivateKey()

    var publicKeyBase64: String {
        key.publicKey.rawRepresentation.base64EncodedString()
    }

    func signTerminalDigest(_ digest: TerminalDigest) throws -> Data {
        try key.signature(for: digest.bytes).derRepresentation
    }
}

private actor ProviderLoopV2PrepareGate {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var entered = false

    init() {
        let (stream, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        self.stream = stream
        self.continuation = continuation
    }

    func pause() async {
        entered = true
        for await _ in stream {
            return
        }
    }

    func hasEntered() -> Bool { entered }

    func release() {
        continuation.yield()
        continuation.finish()
    }
}

private actor ProviderLoopV2DeterministicExecutor: PreparedInferenceExecutor {
    private struct Held {
        let inference: PreparedInference
        let continuation: AsyncStream<GenerationEvent>.Continuation
        let completion: PreparedInferenceCompletion
        let usageLedger: PreparedInferenceUsageLedger
    }

    private let heldRequestID: RequestID
    private var prepared: [LeaseID: PreparedInference] = [:]
    private var held: [LeaseID: Held] = [:]

    init(heldRequestID: RequestID) {
        self.heldRequestID = heldRequestID
    }

    func prepareInference(
        _ inference: PreparedInference,
        expiresAt _: Date
    ) async throws -> PreparedInferenceAdmission {
        prepared[inference.identity.leaseID] = inference
        return PreparedInferenceAdmission(
            promptTokens: inference.facts.promptTokens,
            maxOutputTokens: inference.facts.maxOutputTokens,
            engineQueueDepth: 2,
            reservedKVBytes: 8_192,
            reservedMediaBytes: inference.facts.mediaBytes,
            prefillCanBegin: false,
            estimatedPrefillMilliseconds: 7
        )
    }

    func startPreparedInference(
        identity: AttemptIdentity
    ) async throws -> PreparedInferenceExecution {
        guard let inference = prepared[identity.leaseID],
            inference.identity == identity
        else {
            throw PreparedInferenceAdmissionError.unknownLease
        }
        let completion = PreparedInferenceCompletion()
        let usageLedger = PreparedInferenceUsageLedger(
            promptTokens: UInt64(clamping: inference.facts.promptTokens))
        let (events, continuation) = AsyncStream<GenerationEvent>.makeStream()
        if identity.requestID == heldRequestID {
            held[identity.leaseID] = Held(
                inference: inference,
                continuation: continuation,
                completion: completion,
                usageLedger: usageLedger
            )
        } else {
            Task {
                continuation.yield(.chunk("hello"))
                continuation.yield(.chunk(" world"))
                continuation.yield(
                    .info(
                        promptTokens: inference.facts.promptTokens,
                        completionTokens: 2,
                        tokensPerSecond: 10,
                        finishReason: "stop"
                    ))
                continuation.finish()
                await completion.finish()
                await inference.resourceRelease.fire()
            }
        }
        return PreparedInferenceExecution(
            events: events,
            completion: completion,
            usageLedger: usageLedger
        )
    }

    func abortPreparedInference(identity: AttemptIdentity) async {
        guard let inference = prepared.removeValue(forKey: identity.leaseID),
            inference.identity == identity
        else { return }
        held.removeValue(forKey: identity.leaseID)?.continuation.finish()
        await inference.resourceRelease.fire()
    }

    func cancelPreparedInference(identity: AttemptIdentity) async {
        if let value = held.removeValue(forKey: identity.leaseID),
            value.inference.identity == identity
        {
            value.continuation.yield(
                .info(
                    promptTokens: value.inference.facts.promptTokens,
                    completionTokens: 3,
                    tokensPerSecond: 10,
                    finishReason: nil
                ))
            value.continuation.yield(.error("request cancelled"))
            value.continuation.finish()
            await value.completion.finish()
            await value.inference.resourceRelease.fire()
            prepared.removeValue(forKey: identity.leaseID)
            return
        }
        guard let inference = prepared.removeValue(forKey: identity.leaseID),
            inference.identity == identity
        else { return }
        await inference.resourceRelease.fire()
    }

    func forceReleasePreparedInference(identity: AttemptIdentity) async {
        await cancelPreparedInference(identity: identity)
    }

    func containsPrepared(identity: AttemptIdentity) -> Bool {
        prepared[identity.leaseID]?.identity == identity
    }
}

@Suite("ProviderLoop protocol v2 real-wire integration")
struct ProviderLoopV2IntegrationTests {
    @Test("prepare/start stream durability replay ACK abort cancel and v1 fence")
    func completeLifecycle() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "provider-loop-v2-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }

        let loop = try makeProviderLoopV2TestLoop(
            durableDirectory: directory)
        let providerKeys = await loop.keyPair
        let heldRequestID = providerLoopV2ID(0x73)
        let delayedPrepareRequestID = providerLoopV2ID(0xB1)
        let prepareGate = ProviderLoopV2PrepareGate()
        let executor = ProviderLoopV2DeterministicExecutor(
            heldRequestID: heldRequestID)
        let signer = ProviderLoopV2TestSigner()
        let attempts = V2PreparedAttemptCoordinator(
            directory: directory,
            signer: signer,
            manager: PreparedLeaseManager(
                automaticallyExpire: false,
                terminalWaitTimeout: .seconds(2)
            ),
            keySource: ProviderLoopV2TestKeySource(
                key: SymmetricKey(data: Data(repeating: 0x42, count: 32)))
        )
        let hooks = ProviderLoopV2InferenceHooks(
            prepare: { message in
                if message.identity.requestID == delayedPrepareRequestID {
                    await prepareGate.pause()
                }
                try makeDeterministicPreparedInference(
                    message: message,
                    providerKeys: providerKeys
                )
            },
            executor: { _ in executor }
        )

        let mock = MockCoordinator()
        let baseURL = try await mock.start()
        let client = CoordinatorClient(
            config: CoordinatorClientConfig(
                url: baseURL.mockProviderWebSocketURL(),
                hardware: providerLoopV2Hardware(),
                models: [],
                backendName: "mlx-swift",
                heartbeatInterval: 60,
                publicKey: providerKeys.publicKeyBase64
            ),
            stats: AtomicProviderStats(),
            state: await loop.state,
            liveAPNsToken: { nil }
        )
        let send = SendHandle(await client.outboundSender())
        let handler = Task {
            await loop.runProtocolV2Handlers(
                coordinator: client,
                send: send,
                attempts: attempts,
                hooks: hooks
            )
        }
        var shutdownPreparedIdentity: AttemptIdentity?

        do {
            #expect(await client.installProtocolV2RuntimeHandler())
            _ = await client.start()
            let registration = try #require(
                await mock.awaitFirstRegister(timeout: .seconds(5)))
            #expect(registration.protocolCapabilities?.supportsV2 == true)
            let generation = try #require(
                registration.providerProcessGeneration)
            let providerID = providerLoopV2ID(0x11)
            try await mock.pushRegisterAcknowledgement(
                providerID: providerID,
                providerProcessGeneration: generation,
                sessionEpoch: 1,
                protocolCapabilities: .current
            )
            try await waitForProviderLoopV2Session(
                client, epoch: 1)

            let providerState = await loop.state
            providerState.warmModels = ["model-a"]
            let readyRevision = providerState.modelStateRevision
            let readySnapshot = try #require(
                try await mock.waitForSnapshot(timeout: .seconds(5)) {
                    $0.modelReadyEvents.contains(where: {
                        $0.model == "model-a" && $0.stateRevision == readyRevision
                    })
                        && $0.heartbeats.contains(where: {
                            $0.modelStateRevision == readyRevision
                                && $0.warmModels == ["model-a"]
                        })
                })
            let ready = try #require(
                readySnapshot.modelReadyEvents.first(where: {
                    $0.model == "model-a" && $0.stateRevision == readyRevision
                }))
            #expect(ready.identity.sessionEpoch == 1)

            let first = providerLoopV2Attempt(
                providerID: providerID,
                generation: generation,
                sessionEpoch: 1,
                request: 0x31,
                attempt: 0x41,
                reservation: 0x51,
                lease: 0x61
            )
            let request = Data(
                #"{"model":"model-a","messages":[{"role":"user","content":"hello"}],"max_tokens":4,"stream":true}"#
                    .utf8)
            let consumer = try await mock.pushV2Prepare(
                identity: first,
                model: "model-a",
                providerPublicKeyBase64: providerKeys.publicKeyBase64,
                chatRequestJSON: request
            )
            let preparedSnapshot = try #require(
                try await mock.waitForSnapshot(timeout: .seconds(5)) {
                    $0.prepared.contains(where: { $0.identity == first })
                })
            let prepared = try #require(
                preparedSnapshot.prepared.first(where: {
                    $0.identity == first
                }))
            #expect(prepared.model == "model-a")
            #expect(prepared.promptTokens == 2)
            #expect(prepared.maxOutputTokens == 4)
            #expect(prepared.engineQueueDepth == 2)
            #expect(prepared.reservedKVBytes == 8_192)
            #expect(prepared.reservedMediaBytes == 0)
            #expect(preparedSnapshot.binaryFrames.isEmpty)

            try await mock.pushV2Start(identity: first)
            let completedSnapshot = try #require(
                try await mock.waitForSnapshot(timeout: .seconds(5)) {
                    $0.startAcks.contains(where: { $0.identity == first })
                        && !$0.binaryFrames.isEmpty
                        && $0.providerTerminals.contains(where: {
                            $0.identity == first
                        })
                })
            let terminal = try #require(
                completedSnapshot.providerTerminals.first(where: {
                    $0.identity == first
                }))
            let startAckWireIndex = try #require(
                completedSnapshot.v2WireEvents.firstIndex(of: .startAck(first)))
            let firstBinaryWireIndex = try #require(
                completedSnapshot.v2WireEvents.firstIndex(of: .binary(first)))
            #expect(startAckWireIndex < firstBinaryWireIndex)
            #expect(terminal.outcome == .completed)
            #expect(terminal.completionTokens <= prepared.maxOutputTokens)
            #expect(await attempts.pendingTerminalCount() == 1)

            var plaintextFrames: [Data] = []
            var verifiedRolling = RollingResponseSHA256()
            var previousCumulativeTokens: UInt64 = 0
            for (index, wire) in completedSnapshot.binaryFrames.enumerated() {
                let opened = try consumer.openProtocolV2Frame(
                    senderPublicKey: providerKeys.publicKeyBytes,
                    wire: wire
                )
                #expect(opened.header.attemptIdentity == first)
                #expect(opened.header.sequence == UInt64(index))
                #expect(opened.header.kind == .responseChunk)
                #expect(opened.header.cumulativeTokens >= previousCumulativeTokens)
                let checkpoint = try verifiedRolling.append(
                    sequence: opened.header.sequence,
                    cumulativeTokens: opened.header.cumulativeTokens,
                    responseBytes: opened.plaintext
                )
                #expect(checkpoint.rollingDigest.bytes == opened.header.rollingDigest)
                previousCumulativeTokens = opened.header.cumulativeTokens
                plaintextFrames.append(opened.plaintext)
            }
            let joined = plaintextFrames.reduce(into: Data()) {
                $0.append($1)
            }
            #expect(String(data: joined, encoding: .utf8)?.contains("hello world") == true)
            #expect(String(data: joined, encoding: .utf8)?.contains("data: [DONE]") == true)
            #expect(terminal.responseHash.bytes == TerminalDigest.sha256(joined).bytes)
            #expect(
                terminal.rollingDigest.bytes
                    == V2BinaryFrame.decode(
                        try #require(completedSnapshot.binaryFrames.last)
                    ).header.rollingDigest
            )

            let terminalCountBeforeReconnect =
                completedSnapshot.providerTerminals.count
            await mock.dropActiveWebSocket()
            _ = try #require(
                try await mock.waitForSnapshot(timeout: .seconds(8)) {
                    $0.registers.count >= 2
                })
            try await mock.pushRegisterAcknowledgement(
                providerID: providerID,
                providerProcessGeneration: generation,
                sessionEpoch: 2,
                protocolCapabilities: .current
            )
            try await waitForProviderLoopV2Session(
                client, epoch: 2)
            _ = try #require(
                try await mock.waitForSnapshot(timeout: .seconds(5)) {
                    $0.providerTerminals.count > terminalCountBeforeReconnect
                })

            // A control accepted by the old WebSocket session can never become
            // current after reconnect. The real CoordinatorClient session gate
            // drops it before the ProviderLoop handler sees it.
            let staleStartAckCount = mock.snapshot().startAcks.count
            let staleErrorCount = mock.snapshot().structuredErrors.count
            try await mock.pushV2Start(identity: first)
            try await Task.sleep(for: .milliseconds(100))
            #expect(mock.snapshot().startAcks.count == staleStartAckCount)
            #expect(mock.snapshot().structuredErrors.count == staleErrorCount)

            try await mock.pushV2TerminalAck(
                identity: first,
                terminalDigest: terminal.terminalDigest,
                disposition: .conflict
            )
            _ = try #require(
                try await mock.waitForSnapshot(timeout: .seconds(5)) {
                    $0.structuredErrors.contains(where: {
                        $0.identity == first && $0.errorClass == .security
                    })
                })
            #expect(await attempts.pendingTerminalCount() == 1)
            try await mock.pushV2TerminalAck(
                identity: first,
                terminalDigest: terminal.terminalDigest,
                disposition: .settled
            )
            try await waitForPendingTerminalCount(
                attempts, expected: 0)

            let cancelled = providerLoopV2Attempt(
                providerID: providerID,
                generation: generation,
                sessionEpoch: 2,
                request: 0x73,
                attempt: 0x74,
                reservation: 0x75,
                lease: 0x76
            )
            _ = try await mock.pushV2Prepare(
                identity: cancelled,
                model: "model-a",
                providerPublicKeyBase64: providerKeys.publicKeyBase64,
                chatRequestJSON: request
            )
            _ = try #require(
                try await mock.waitForSnapshot(timeout: .seconds(5)) {
                    $0.prepared.contains(where: {
                        $0.identity == cancelled
                    })
                })
            try await mock.pushV2Start(identity: cancelled)
            _ = try #require(
                try await mock.waitForSnapshot(timeout: .seconds(5)) {
                    $0.startAcks.contains(where: {
                        $0.identity == cancelled
                    })
                })
            try await mock.pushV2Cancel(
                identity: cancelled,
                reason: "integration_cancel"
            )
            let cancelledSnapshot = try #require(
                try await mock.waitForSnapshot(timeout: .seconds(5)) {
                    $0.cancelAcks.contains(where: {
                        $0.identity == cancelled
                    })
                        && $0.providerTerminals.contains(where: {
                            $0.identity == cancelled
                                && $0.outcome == .cancelled
                        })
                })
            let cancelledTerminal = try #require(
                cancelledSnapshot.providerTerminals.last(where: {
                    $0.identity == cancelled
                }))
            #expect(cancelledTerminal.completionTokens == 0)
            #expect(cancelledTerminal.finalGeneratedTokens == 3)
            #expect(
                cancelledTerminal.finalGeneratedTokens
                    > cancelledTerminal.completionTokens)
            try await mock.pushV2TerminalAck(
                identity: cancelled,
                terminalDigest: cancelledTerminal.terminalDigest,
                disposition: .released
            )
            try await waitForPendingTerminalCount(
                attempts, expected: 0)

            let aborted = providerLoopV2Attempt(
                providerID: providerID,
                generation: generation,
                sessionEpoch: 2,
                request: 0x81,
                attempt: 0x82,
                reservation: 0x83,
                lease: 0x84
            )
            _ = try await mock.pushV2Prepare(
                identity: aborted,
                model: "model-a",
                providerPublicKeyBase64: providerKeys.publicKeyBase64,
                chatRequestJSON: request
            )
            _ = try #require(
                try await mock.waitForSnapshot(timeout: .seconds(5)) {
                    $0.prepared.contains(where: { $0.identity == aborted })
                })
            try await mock.pushV2Abort(
                identity: aborted,
                reason: "reordered_abort"
            )
            _ = try #require(
                try await mock.waitForSnapshot(timeout: .seconds(5)) {
                    $0.abortAcks.contains(where: {
                        $0.identity == aborted
                    })
                })
            let startAckCount = mock.snapshot().startAcks.count
            let binaryCount = mock.snapshot().binaryFrames.count
            try await mock.pushV2Start(identity: aborted)
            _ = try #require(
                try await mock.waitForSnapshot(timeout: .seconds(5)) {
                    $0.structuredErrors.contains(where: {
                        $0.identity == aborted
                    })
                })
            #expect(mock.snapshot().startAcks.count == startAckCount)
            #expect(mock.snapshot().binaryFrames.count == binaryCount)

            let abortBeforePrepare = providerLoopV2Attempt(
                providerID: providerID,
                generation: generation,
                sessionEpoch: 2,
                request: 0x91,
                attempt: 0x92,
                reservation: 0x93,
                lease: 0x94
            )
            try await mock.pushV2Abort(
                identity: abortBeforePrepare,
                reason: "abort_before_prepare"
            )
            _ = try #require(
                try await mock.waitForSnapshot(timeout: .seconds(5)) {
                    $0.abortAcks.contains(where: {
                        $0.identity == abortBeforePrepare
                    })
                })
            let preparedCount = mock.snapshot().prepared.count
            let binaryCountAfterAbort = mock.snapshot().binaryFrames.count
            _ = try await mock.pushV2Prepare(
                identity: abortBeforePrepare,
                model: "model-a",
                providerPublicKeyBase64: providerKeys.publicKeyBase64,
                chatRequestJSON: request
            )
            _ = try #require(
                try await mock.waitForSnapshot(timeout: .seconds(5)) {
                    $0.structuredErrors.contains(where: {
                        $0.identity == abortBeforePrepare
                            && $0.errorClass == .security
                    })
                })
            #expect(mock.snapshot().prepared.count == preparedCount)
            #expect(mock.snapshot().binaryFrames.count == binaryCountAfterAbort)

            // Prepare performs decryption/rendering/tokenization outside the
            // serialized durable transition. An abort that arrives while that work
            // is suspended must win when prepare re-enters the composition actor.
            let abortDuringPrepare = providerLoopV2Attempt(
                providerID: providerID,
                generation: generation,
                sessionEpoch: 2,
                request: 0xB1,
                attempt: 0xB2,
                reservation: 0xB3,
                lease: 0xB4
            )
            let preparedBeforeRace = mock.snapshot().prepared.count
            _ = try await mock.pushV2Prepare(
                identity: abortDuringPrepare,
                model: "model-a",
                providerPublicKeyBase64: providerKeys.publicKeyBase64,
                chatRequestJSON: request
            )
            let gateDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !(await prepareGate.hasEntered()),
                ContinuousClock.now < gateDeadline
            {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await prepareGate.hasEntered())
            try await mock.pushV2Abort(
                identity: abortDuringPrepare,
                reason: "abort_during_prepare"
            )
            _ = try #require(
                try await mock.waitForSnapshot(timeout: .seconds(5)) {
                    $0.abortAcks.contains(where: {
                        $0.identity == abortDuringPrepare
                    })
                })
            await prepareGate.release()
            _ = try #require(
                try await mock.waitForSnapshot(timeout: .seconds(5)) {
                    $0.structuredErrors.contains(where: {
                        $0.identity == abortDuringPrepare
                            && $0.errorClass == .security
                    })
                })
            #expect(mock.snapshot().prepared.count == preparedBeforeRace)

            providerState.warmModels = []
            let goneRevision = providerState.modelStateRevision
            _ = try #require(
                try await mock.waitForSnapshot(timeout: .seconds(5)) {
                    $0.modelGoneEvents.contains(where: {
                        $0.model == "model-a" && $0.stateRevision == goneRevision
                    })
                        && $0.heartbeats.contains(where: {
                            $0.modelStateRevision == goneRevision
                                && $0.warmModels.isEmpty
                        })
                })

            let shutdownPrepared = providerLoopV2Attempt(
                providerID: providerID,
                generation: generation,
                sessionEpoch: 2,
                request: 0xA1,
                attempt: 0xA2,
                reservation: 0xA3,
                lease: 0xA4
            )
            shutdownPreparedIdentity = shutdownPrepared
            _ = try await mock.pushV2Prepare(
                identity: shutdownPrepared,
                model: "model-a",
                providerPublicKeyBase64: providerKeys.publicKeyBase64,
                chatRequestJSON: request
            )
            _ = try #require(
                try await mock.waitForSnapshot(timeout: .seconds(5)) {
                    $0.prepared.contains(where: {
                        $0.identity == shutdownPrepared
                    })
                })
            #expect(await executor.containsPrepared(identity: shutdownPrepared))
        } catch {
            await prepareGate.release()
            handler.cancel()
            await client.shutdown()
            await handler.value
            await mock.shutdown()
            throw error
        }

        handler.cancel()
        await client.shutdown()
        await handler.value
        if let shutdownPreparedIdentity {
            #expect(
                !(await executor.containsPrepared(
                    identity: shutdownPreparedIdentity
                )))
        }
        await mock.shutdown()
    }

    @Test("signed replay fence reclaims tombstone capacity; invalid proof cannot")
    func replayFenceCapacityRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "provider-loop-v2-replay-fence-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }

        let capacity = try TerminalJournalCapacity(
            maxEntries: 1,
            maxEncryptedRecordBytes:
                TerminalJournalCapacity.minimumEncryptedRecordBytes,
            maxTotalReservedBytes:
                TerminalJournalCapacity.minimumEncryptedRecordBytes
        )
        let loop = try makeProviderLoopV2TestLoop(
            durableDirectory: directory)
        let providerKeys = await loop.keyPair
        let providerID = providerLoopV2ID(0x11)
        let historicalGeneration = providerLoopV2ID(0x99)
        let historicalAbort = providerLoopV2Attempt(
            providerID: providerID,
            generation: historicalGeneration,
            sessionEpoch: 7,
            request: 0x21,
            attempt: 0x22,
            reservation: 0x23,
            lease: 0x24
        )
        let keySource = ProviderLoopV2TestKeySource(
            key: SymmetricKey(data: Data(repeating: 0x51, count: 32)))
        // Simulate the previous provider process: persist its abort, release the
        // store lock, then reopen the same state under the new process session.
        do {
            let historicalStore = try AttemptTombstones(
                directory: directory,
                providerID: providerID.description,
                keySource: keySource,
                capacity: capacity
            )
            _ = try await historicalStore.recordAbort(
                AttemptAbortTombstone(identity: historicalAbort))
        }
        let executor = ProviderLoopV2DeterministicExecutor(
            heldRequestID: providerLoopV2ID(0xFF))
        let attempts = V2PreparedAttemptCoordinator(
            directory: directory,
            signer: ProviderLoopV2TestSigner(),
            manager: PreparedLeaseManager(automaticallyExpire: false),
            keySource: keySource,
            capacity: capacity
        )
        let hooks = ProviderLoopV2InferenceHooks(
            prepare: { message in
                try makeDeterministicPreparedInference(
                    message: message,
                    providerKeys: providerKeys
                )
            },
            executor: { _ in executor }
        )
        let mock = MockCoordinator()
        let baseURL = try await mock.start()
        let client = CoordinatorClient(
            config: CoordinatorClientConfig(
                url: baseURL.mockProviderWebSocketURL(),
                hardware: providerLoopV2Hardware(),
                models: [],
                backendName: "mlx-swift",
                heartbeatInterval: 60,
                publicKey: providerKeys.publicKeyBase64
            ),
            stats: AtomicProviderStats(),
            state: await loop.state,
            liveAPNsToken: { nil }
        )
        let handler = Task {
            await loop.runProtocolV2Handlers(
                coordinator: client,
                send: SendHandle(await client.outboundSender()),
                attempts: attempts,
                hooks: hooks
            )
        }

        do {
            #expect(await client.installProtocolV2RuntimeHandler())
            _ = await client.start()
            let registration = try #require(
                await mock.awaitFirstRegister(timeout: .seconds(5)))
            let generation = try #require(
                registration.providerProcessGeneration)
            #expect(generation != historicalGeneration)
            try await mock.pushRegisterAcknowledgement(
                providerID: providerID,
                providerProcessGeneration: generation,
                sessionEpoch: 1,
                protocolCapabilities: .current
            )
            try await waitForProviderLoopV2Session(client, epoch: 1)

            #expect(
                (try await attempts.paidAdmissionStatus()).paidAdmissionAllowed
                    == false)

            try await mock.pushV2CoordinatorReplayFence(
                providerID: providerID,
                providerProcessGeneration: historicalGeneration,
                throughSessionEpoch: 7,
                coordinatorRevision: 1,
                validSignature: false
            )
            try await Task.sleep(for: .milliseconds(100))
            #expect(
                (try await attempts.paidAdmissionStatus()).paidAdmissionAllowed
                    == false)

            let next = providerLoopV2Attempt(
                providerID: providerID,
                generation: generation,
                sessionEpoch: 1,
                request: 0x31,
                attempt: 0x32,
                reservation: 0x33,
                lease: 0x34
            )
            let request = Data(
                #"{"model":"model-a","messages":[{"role":"user","content":"fence"}],"stream":true,"max_tokens":4}"#
                    .utf8)
            _ = try await mock.pushV2Prepare(
                identity: next,
                model: "model-a",
                providerPublicKeyBase64: providerKeys.publicKeyBase64,
                chatRequestJSON: request
            )
            _ = try #require(
                try await mock.waitForSnapshot(timeout: .seconds(5)) {
                    $0.structuredErrors.contains(where: {
                        $0.identity == next && $0.errorClass == .capacity
                    })
                })

            try await mock.pushV2CoordinatorReplayFence(
                providerID: providerID,
                providerProcessGeneration: historicalGeneration,
                throughSessionEpoch: 7,
                coordinatorRevision: 2
            )
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !(try await attempts.paidAdmissionStatus()).paidAdmissionAllowed,
                ContinuousClock.now < deadline
            {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(
                (try await attempts.paidAdmissionStatus()).paidAdmissionAllowed)

            _ = try await mock.pushV2Prepare(
                identity: next,
                model: "model-a",
                providerPublicKeyBase64: providerKeys.publicKeyBase64,
                chatRequestJSON: request
            )
            _ = try #require(
                try await mock.waitForSnapshot(timeout: .seconds(5)) {
                    $0.prepared.contains(where: { $0.identity == next })
                })
        } catch {
            handler.cancel()
            await client.shutdown()
            await handler.value
            await mock.shutdown()
            throw error
        }

        handler.cancel()
        await client.shutdown()
        await handler.value
        await mock.shutdown()
    }

    @Test("v1 registration and encrypted inference remain unchanged without handler")
    func v1RemainsUnchanged() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "provider-loop-v1-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }

        let loop = try makeProviderLoopV2TestLoop(
            durableDirectory: directory)
        let providerKeys = await loop.keyPair
        let mock = MockCoordinator()
        let baseURL = try await mock.start()
        let client = CoordinatorClient(
            config: CoordinatorClientConfig(
                url: baseURL.mockProviderWebSocketURL(),
                hardware: providerLoopV2Hardware(),
                models: [],
                backendName: "mlx-swift",
                heartbeatInterval: 60,
                publicKey: providerKeys.publicKeyBase64
            ),
            stats: AtomicProviderStats(),
            state: await loop.state,
            liveAPNsToken: { nil }
        )
        let started = await client.start()

        do {
            let registration = try #require(
                await mock.awaitFirstRegister(timeout: .seconds(5)))
            #expect(registration.protocolCapabilities == nil)
            #expect(registration.providerProcessGeneration == nil)
            #expect(await client.protocolV2Session() == nil)
            #expect(!(await client.installProtocolV2RuntimeHandler()))

            let requestID = "legacy-request"
            let plaintext = Data(
                #"{"model":"model-a","messages":[{"role":"user","content":"v1"}],"stream":true}"#
                    .utf8)
            let inbound = Task {
                try await awaitProviderLoopV1Inference(
                    started.events,
                    timeout: .seconds(5)
                )
            }
            try await mock.pushInferenceRequest(
                requestId: requestID,
                providerPublicKeyBase64: providerKeys.publicKeyBase64,
                chatRequestJSON: plaintext
            )
            let captured = try await inbound.value
            #expect(captured.requestID == requestID)
            let senderPublicKey = try #require(captured.senderPublicKey)
            #expect(
                try providerKeys.decrypt(
                    senderPublicKey: senderPublicKey,
                    ciphertext: captured.ciphertext
                ) == plaintext
            )
        } catch {
            await client.shutdown()
            await mock.shutdown()
            throw error
        }

        await client.shutdown()
        await mock.shutdown()
    }
}

private struct ProviderLoopV1InboundCapture: Sendable {
    let requestID: String
    let ciphertext: Data
    let senderPublicKey: Data?
}

private func awaitProviderLoopV1Inference(
    _ events: AsyncStream<CoordinatorEvent>,
    timeout: Duration
) async throws -> ProviderLoopV1InboundCapture {
    try await withThrowingTaskGroup(
        of: ProviderLoopV1InboundCapture.self
    ) { group in
        group.addTask {
            for await event in events {
                if case .inferenceRequest(
                    let requestID,
                    let ciphertext,
                    let senderPublicKey
                ) = event {
                    return ProviderLoopV1InboundCapture(
                        requestID: requestID,
                        ciphertext: ciphertext,
                        senderPublicKey: senderPublicKey
                    )
                }
            }
            throw CancellationError()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw CancellationError()
        }
        let captured = try await group.next()
        group.cancelAll()
        return try #require(captured)
    }
}

private func makeProviderLoopV2TestLoop(
    durableDirectory: URL
) throws -> ProviderLoop {
    try ProviderLoop(
        config: ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/unused",
            hardware: providerLoopV2Hardware(),
            models: [],
            config: ProviderConfig(
                provider: ProviderSettings(
                    name: "protocol-v2-integration",
                    memoryReserveGB: 1
                ),
                backend: BackendSettings(
                    idleTimeoutMins: 0,
                    maxModelSlots: 1
                ),
                coordinator: CoordinatorSettings(
                    heartbeatIntervalSecs: 60
                )
            ),
            protocolV2DurableDirectory: durableDirectory
        ),
        purgeLegacyFiles: false,
        attestationSigner: nil
    )
}

private func makeDeterministicPreparedInference(
    message: V2Prepare,
    providerKeys: NodeKeyPair
) throws -> PreparedInference {
    guard
        try V2Prepare.digest(of: message.encryptedBody)
            == message.requestDigest
    else {
        throw PreparedLeaseError.conflictingDuplicate
    }
    let plaintext = try providerKeys.decryptPayload(message.encryptedBody)
    var openAIRequest = try ProviderLoop.decodeOpenAIRequest(plaintext)
    guard openAIRequest.model == message.model else {
        throw PreparedInferenceError.modelMismatch(
            expected: message.model,
            actual: openAIRequest.model
        )
    }
    openAIRequest.stream = true
    var streamOptions =
        openAIRequest.streamOptions ?? OpenAIStreamOptions()
    streamOptions.includeUsage = true
    openAIRequest.streamOptions = streamOptions
    guard
        let responsePublicKey = Data(
            base64Encoded: message.encryptedBody.ephemeralPublicKey),
        responsePublicKey.count == 32,
        responsePublicKey.base64EncodedString()
            == message.encryptedBody.ephemeralPublicKey
    else {
        throw V2PrepareValidationError.invalidEncryptedPayload
    }

    let translated = MultiModelBatchSchedulerEngine.translate(
        openAIRequest: openAIRequest,
        defaultMaxTokens: 4
    )
    let promptTokens = [101, 102]
    return try PreparedInference(
        identity: message.identity,
        requestDigest: message.requestDigest.bytes.base64EncodedString(),
        modelID: message.model,
        promptTokens: promptTokens,
        request: translated,
        streamRequest: openAIRequest,
        responsePublicKey: responsePublicKey,
        facts: PreparedInferenceFacts(
            decryptionComplete: true,
            renderingComplete: true,
            tokenizationComplete: true,
            promptTokens: promptTokens.count,
            maxOutputTokens: translated.max_tokens ?? 4
        )
    )
}

private func waitForProviderLoopV2Session(
    _ client: CoordinatorClient,
    epoch: UInt64
) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while await client.protocolV2Session()?.identity.sessionEpoch != epoch,
        ContinuousClock.now < deadline
    {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await client.protocolV2Session()?.identity.sessionEpoch == epoch)
}

private func waitForPendingTerminalCount(
    _ attempts: V2PreparedAttemptCoordinator,
    expected: Int
) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while await attempts.pendingTerminalCount() != expected,
        ContinuousClock.now < deadline
    {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await attempts.pendingTerminalCount() == expected)
}

private func providerLoopV2Attempt(
    providerID: ProviderID,
    generation: ProviderProcessGenerationID,
    sessionEpoch: UInt64,
    request: UInt8,
    attempt: UInt8,
    reservation: UInt8,
    lease: UInt8
) -> AttemptIdentity {
    AttemptIdentity(
        providerID: providerID,
        providerProcessGeneration: generation,
        sessionEpoch: sessionEpoch,
        requestID: providerLoopV2ID(request),
        attemptID: providerLoopV2ID(attempt),
        reservationID: providerLoopV2ID(reservation),
        leaseID: providerLoopV2ID(lease)
    )
}

private func providerLoopV2ID(_ byte: UInt8) -> ProtocolV2UUID {
    ProtocolV2UUID(bytes: Data(repeating: byte, count: 16))!
}

private func providerLoopV2Hardware() -> HardwareInfo {
    HardwareInfo(
        machineModel: "Mac16,5",
        chipName: "Apple M4 Max",
        chipFamily: .m4,
        chipTier: .max,
        memoryGb: 128,
        memoryAvailableGb: 124,
        cpuCores: CpuCores(
            total: 16,
            performance: 12,
            efficiency: 4
        ),
        gpuCores: 40,
        memoryBandwidthGbs: 546
    )
}
