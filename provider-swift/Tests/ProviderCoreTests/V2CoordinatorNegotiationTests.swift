import CryptoKit
import Foundation
import Testing

@testable import ProviderCore

private let replayFenceTestKey = P256.Signing.PrivateKey()
private let replayFenceTestPublicKey =
    replayFenceTestKey.publicKey.rawRepresentation.base64EncodedString()

@Suite("CoordinatorClient protocol v2 negotiation")
struct V2CoordinatorNegotiationTests {
    @Test("commands are rejected until explicit compatible server ACK")
    func explicitNegotiation() throws {
        let generation = id(0x22)
        var state = V2NegotiationState(
            localCapabilities: .current,
            processGeneration: generation
        )
        let providerID = id(0x11)
        let identity = attempt(
            providerID: providerID,
            generation: generation,
            sessionEpoch: 9
        )
        let start = V2CoordinatorControlMessage.start(V2Start(identity: identity))

        #expect(throws: V2NegotiationError.commandBeforeNegotiation) {
            try state.validate(start)
        }

        let v1Ack = V2RegisterAcknowledgement(
            providerID: providerID,
            providerProcessGeneration: generation,
            sessionEpoch: 9
        )
        let v1Selection = try state.accept(v1Ack)
        #expect(v1Selection == nil)
        #expect(state.acknowledgedProviderID == providerID)
        #expect(throws: V2NegotiationError.commandBeforeNegotiation) {
            try state.validate(start)
        }

        state.resetForReconnect()
        #expect(
            throws: V2NegotiationError.invalidCoordinatorReplayFencePublicKey
        ) {
            _ = try state.accept(
                V2RegisterAcknowledgement(
                    providerID: providerID,
                    providerProcessGeneration: generation,
                    sessionEpoch: 10,
                    protocolCapabilities: .current
                ))
        }
        let accepted = try state.accept(
            V2RegisterAcknowledgement(
                providerID: providerID,
                providerProcessGeneration: generation,
                sessionEpoch: 10,
                protocolCapabilities: .current,
                coordinatorReplayFencePublicKey: replayFenceTestPublicKey
            ))
        let session = try #require(accepted)
        #expect(session.capabilities.protocolMajor == 2)
        #expect(session.capabilities.protocolMinor == 0)
        try state.validate(
            .start(
                V2Start(
                    identity: attempt(
                        providerID: providerID,
                        generation: generation,
                        sessionEpoch: 10
                    ))))
        try state.validate(
            .start(
                V2Start(
                    identity: attempt(
                        providerID: providerID,
                        generation: generation,
                        sessionEpoch: 9
                    ))))
        #expect(throws: V2NegotiationError.identityMismatch) {
            try state.validate(
                .start(
                    V2Start(
                        identity: attempt(
                            providerID: providerID,
                            generation: id(0x23),
                            sessionEpoch: 9
                        ))))
        }
        try state.validate(
            V2ProviderControlMessage.startAck(
                V2StartAck(
                    identity: attempt(
                        providerID: providerID,
                        generation: generation,
                        sessionEpoch: 9
                    )
                )))
        #expect(throws: V2NegotiationError.identityMismatch) {
            try state.validate(
                V2ProviderControlMessage.startAck(
                    V2StartAck(
                        identity: attempt(
                            providerID: providerID,
                            generation: id(0x23),
                            sessionEpoch: 9
                        )
                    )))
        }
    }

    @Test("minor ranges and every identity fence are enforced")
    func overlapAndIdentityFences() throws {
        let generation = id(0x22)
        let providerID = id(0x11)
        var state = V2NegotiationState(
            localCapabilities: ProtocolCapabilities(
                protocolMajor: 2,
                protocolMinor: 3,
                minimumCompatibleMinor: 1,
                preparedLeases: true,
                startAuthorization: true,
                structuredErrors: true,
                startAck: true,
                abortAck: true,
                cancelAck: true,
                durableTerminals: true,
                modelLifecycleEvents: true,
                binaryPayloadFrames: true,
                coordinatorReplayFences: true
            ),
            processGeneration: generation
        )
        let disjoint = ProtocolCapabilities(
            protocolMajor: 2,
            protocolMinor: 8,
            minimumCompatibleMinor: 6,
            preparedLeases: true,
            startAuthorization: true,
            durableTerminals: true
        )
        #expect(throws: V2NegotiationError.incompatibleCapabilities) {
            _ = try state.accept(
                V2RegisterAcknowledgement(
                    providerID: providerID,
                    providerProcessGeneration: generation,
                    sessionEpoch: 9,
                    protocolCapabilities: disjoint
                ))
        }

        let peer = ProtocolCapabilities(
            protocolMajor: 2,
            protocolMinor: 2,
            minimumCompatibleMinor: 0,
            preparedLeases: true,
            startAuthorization: true,
            structuredErrors: true,
            startAck: true,
            abortAck: true,
            cancelAck: true,
            durableTerminals: true,
            modelLifecycleEvents: true,
            binaryPayloadFrames: true,
            coordinatorReplayFences: true
        )
        _ = try state.accept(
            V2RegisterAcknowledgement(
                providerID: providerID,
                providerProcessGeneration: generation,
                sessionEpoch: 9,
                protocolCapabilities: peer,
                coordinatorReplayFencePublicKey: replayFenceTestPublicKey
            ))
        #expect(state.session?.capabilities.protocolMinor == 2)
        #expect(state.session?.capabilities.minimumCompatibleMinor == 1)
        #expect(state.session?.capabilities.cancelAck == true)

        try state.validate(
            .cancel(
                V2Cancel(
                    identity: attempt(
                        providerID: providerID,
                        generation: generation,
                        sessionEpoch: 9
                    ))))
        try state.validate(
            V2ProviderControlMessage.cancelAck(
                V2CancelAck(
                    identity: attempt(
                        providerID: providerID,
                        generation: generation,
                        sessionEpoch: 9
                    )
                )))

        let fields: [(String, (inout AttemptIdentity) -> Void)] = [
            ("provider_id", { $0.providerID = id(0x90) }),
            ("generation", { $0.providerProcessGeneration = id(0x91) }),
            ("session_epoch", { $0.sessionEpoch += 1 }),
        ]
        for (name, mutate) in fields {
            var wrong = attempt(
                providerID: providerID,
                generation: generation,
                sessionEpoch: 9
            )
            mutate(&wrong)
            do {
                try state.validate(.start(V2Start(identity: wrong)))
                Issue.record("accepted mismatched \(name)")
            } catch V2NegotiationError.identityMismatch {
                // Expected.
            }
        }

        let validHeader = try binaryHeader(
            providerID: providerID,
            generation: generation,
            sessionEpoch: 9,
            minor: 2
        )
        try state.validate(validHeader)

        let expectedAttempt = attempt(
            providerID: providerID,
            generation: generation,
            sessionEpoch: 9
        )
        let headerFields: [(String, (inout V2BinaryFrameHeader) -> Void)] = [
            ("provider_id", { $0.providerID = id(0x90) }),
            ("generation", { $0.providerProcessGeneration = id(0x91) }),
            ("session_epoch", { $0.sessionEpoch += 1 }),
            ("request_id", { $0.requestID = id(0x92) }),
            ("attempt_id", { $0.attemptID = id(0x93) }),
            ("reservation_id", { $0.reservationID = id(0x94) }),
            ("lease_id", { $0.leaseID = id(0x95) }),
        ]
        for (name, mutate) in headerFields {
            var wrongHeader = validHeader
            mutate(&wrongHeader)
            do {
                try wrongHeader.validateIdentity(expectedAttempt)
                Issue.record("accepted mismatched binary \(name)")
            } catch V2ProtocolError.identityMismatch {
                // Expected.
            }
        }

        var wrongHeader = validHeader
        wrongHeader.providerID = id(0x90)
        #expect(throws: V2NegotiationError.identityMismatch) {
            try state.validate(wrongHeader)
        }

        var wrongMinor = validHeader
        wrongMinor.minor = 3
        #expect(
            throws: V2NegotiationError.minorVersionMismatch(
                actual: 3,
                expected: 2
            )
        ) {
            try state.validate(wrongMinor)
        }
    }

    @Test("replay fence permits historical generation but binds provider and ACK key")
    func replayFenceSignatureBinding() throws {
        #expect(
            try CoordinatorReplayFenceProof.signingDigest(
                proofID: id(0x99).description,
                providerID: id(0x11).description,
                providerProcessGeneration: id(0x22).description,
                throughSessionEpoch: 7,
                coordinatorRevision: 42
            ).bytes.base64EncodedString()
                == "cvIixyrwtQ8/CkkhmH2F0NKOAYG3ULxOxjuZ0wC6eSs="
        )
        let providerID = id(0x11)
        let generation = id(0x22)
        var state = V2NegotiationState(
            localCapabilities: .current,
            processGeneration: generation
        )
        let session = try #require(
            state.accept(
                V2RegisterAcknowledgement(
                    providerID: providerID,
                    providerProcessGeneration: generation,
                    sessionEpoch: 7,
                    protocolCapabilities: .current,
                    coordinatorReplayFencePublicKey: replayFenceTestPublicKey
                )))
        let proofID = id(0xAA).description
        let digest = try CoordinatorReplayFenceProof.signingDigest(
            proofID: proofID,
            providerID: providerID.description,
            providerProcessGeneration: generation.description,
            throughSessionEpoch: 6,
            coordinatorRevision: 9
        )
        let valid = try CoordinatorReplayFenceProof(
            proofID: proofID,
            providerID: providerID.description,
            providerProcessGeneration: generation.description,
            throughSessionEpoch: 6,
            coordinatorRevision: 9,
            proofDigest: digest,
            coordinatorSignature: try replayFenceTestKey.signature(
                for: digest.bytes
            ).derRepresentation
        )
        try state.validate(.coordinatorReplayFence(valid))
        let wire = try ProviderProtocolCodec.encodeCoordinatorMessageString(
            .coordinatorReplayFence(valid))
        #expect(
            try ProviderProtocolCodec.decodeCoordinatorMessage(
                from: wire,
                negotiatedV2Session: true
            ) == .coordinatorReplayFence(valid)
        )
        var tamperedWire = try #require(
            JSONSerialization.jsonObject(with: Data(wire.utf8))
                as? [String: Any]
        )
        tamperedWire["through_session_epoch"] = 7
        let tamperedData = try JSONSerialization.data(withJSONObject: tamperedWire)
        do {
            _ = try ProviderProtocolCodec.decodeCoordinatorMessage(
                from: tamperedData,
                negotiatedV2Session: true
            )
            Issue.record("accepted replay-fence fields not bound by proof_digest")
        } catch {
            // Expected: decoding re-runs canonical digest validation.
        }
        #expect(
            try session.replayFenceVerifier()
                .verifyCoordinatorReplayFenceProof(valid)
        )

        let historicalGeneration = id(0x33)
        let historicalDigest = try CoordinatorReplayFenceProof.signingDigest(
            proofID: id(0xAC).description,
            providerID: providerID.description,
            providerProcessGeneration: historicalGeneration.description,
            throughSessionEpoch: 99,
            coordinatorRevision: 11
        )
        let historical = try CoordinatorReplayFenceProof(
            proofID: id(0xAC).description,
            providerID: providerID.description,
            providerProcessGeneration: historicalGeneration.description,
            throughSessionEpoch: 99,
            coordinatorRevision: 11,
            proofDigest: historicalDigest,
            coordinatorSignature: try replayFenceTestKey.signature(
                for: historicalDigest.bytes
            ).derRepresentation
        )
        // A current register-ACK key may safely fence a previous process
        // generation; neither generation nor epoch is compared to the live
        // session before the complete proof signature is checked.
        try state.validate(.coordinatorReplayFence(historical))
        #expect(
            try session.replayFenceVerifier()
                .verifyCoordinatorReplayFenceProof(historical)
        )

        let wrongProvider = id(0x44)
        let wrongProviderDigest = try CoordinatorReplayFenceProof.signingDigest(
            proofID: id(0xAD).description,
            providerID: wrongProvider.description,
            providerProcessGeneration: historicalGeneration.description,
            throughSessionEpoch: 99,
            coordinatorRevision: 12
        )
        let signedWrongProvider = try CoordinatorReplayFenceProof(
            proofID: id(0xAD).description,
            providerID: wrongProvider.description,
            providerProcessGeneration: historicalGeneration.description,
            throughSessionEpoch: 99,
            coordinatorRevision: 12,
            proofDigest: wrongProviderDigest,
            coordinatorSignature: try replayFenceTestKey.signature(
                for: wrongProviderDigest.bytes
            ).derRepresentation
        )
        #expect(throws: V2NegotiationError.providerIDMismatch) {
            try state.validate(.coordinatorReplayFence(signedWrongProvider))
        }

        let invalid = try CoordinatorReplayFenceProof(
            proofID: id(0xAB).description,
            providerID: providerID.description,
            providerProcessGeneration: generation.description,
            throughSessionEpoch: 7,
            coordinatorRevision: 10,
            proofDigest: try CoordinatorReplayFenceProof.signingDigest(
                proofID: id(0xAB).description,
                providerID: providerID.description,
                providerProcessGeneration: generation.description,
                throughSessionEpoch: 7,
                coordinatorRevision: 10
            ),
            coordinatorSignature: Data([1, 2, 3])
        )
        try state.validate(.coordinatorReplayFence(invalid))
        #expect(
            try !session.replayFenceVerifier()
                .verifyCoordinatorReplayFenceProof(invalid)
        )
    }

    @Test("register ACK and controls tolerate unknown additive fields")
    func additiveFields() throws {
        let ack = try ProviderProtocolCodec.decodeCoordinatorMessage(
            from: #"""
                {
                  "type":"register_ack",
                  "provider_id":"11111111-1111-1111-1111-111111111111",
                  "provider_process_generation":"22222222-2222-2222-2222-222222222222",
                  "session_epoch":9,
                  "protocol_capabilities":{
                    "protocol_major":2,
                    "protocol_minor":0,
                    "prepared_leases":true,
                    "start_authorization":true,
                    "structured_errors":true,
                    "start_ack":true,
                    "abort_ack":true,
                    "cancel_ack":true,
                    "durable_terminals":true,
                    "model_lifecycle_events":true,
                    "binary_payload_frames":true,
                    "coordinator_replay_fences":true,
                    "future_capability":{"enabled":true}
                  },
                  "coordinator_replay_fence_public_key":"\#(replayFenceTestPublicKey)",
                  "future_ack":42
                }
                """#)
        guard case .registerAck(let value) = ack else {
            Issue.record("expected register ACK")
            return
        }
        #expect(value.providerID == id(0x11))
        #expect(value.providerProcessGeneration == id(0x22))
        #expect(value.protocolCapabilities?.supportsV2 == true)
    }

    @Test("CoordinatorClient generation is stable across reconnect registrations")
    func processGenerationStability() async throws {
        let config = CoordinatorClientConfig(
            url: "wss://example.test/v1/providers/ws",
            hardware: hardware(),
            models: [],
            backendName: "mlx_swift_lm"
        )
        let client = CoordinatorClient(
            config: config,
            stats: AtomicProviderStats(),
            state: ProviderState(),
            liveAPNsToken: { nil }
        )
        #expect(await client.installProtocolV2RuntimeHandler())
        let first = await client.processGeneration()
        let second = await client.processGeneration()
        #expect(second == first)
        #expect(first == ProviderProcessIdentity.generation)

        for _ in 0..<2 {
            let registration = try CoordinatorClientCodec.encodeRegistration(
                from: config,
                protocolCapabilities: .current,
                providerProcessGeneration: await client.processGeneration()
            )
            let object = try #require(
                JSONSerialization.jsonObject(with: registration) as? [String: Any])
            #expect(object["provider_process_generation"] as? String == first.description)
            #expect(object["version"] != nil)
        }
    }

    @Test("client emits only validated negotiated commands")
    func clientCommandStream() async throws {
        let providerID = id(0x11)
        let config = CoordinatorClientConfig(
            url: "wss://example.test/v1/providers/ws",
            hardware: hardware(),
            models: [],
            backendName: "mlx_swift_lm"
        )
        let client = CoordinatorClient(
            config: config,
            stats: AtomicProviderStats(),
            state: ProviderState(),
            liveAPNsToken: { nil }
        )
        #expect(await client.installProtocolV2RuntimeHandler())
        let generation = await client.processGeneration()
        let stream = await client.protocolV2Commands()
        var iterator = stream.makeAsyncIterator()
        let validStart = CoordinatorMessage.start(
            V2Start(
                identity: attempt(
                    providerID: providerID,
                    generation: generation,
                    sessionEpoch: 9
                )))

        // The same command is ignored before the explicit registration ACK.
        await client.handleIncomingText(
            try ProviderProtocolCodec.encodeCoordinatorMessageString(validStart))

        let ack = CoordinatorMessage.registerAck(
            V2RegisterAcknowledgement(
                providerID: providerID,
                providerProcessGeneration: generation,
                sessionEpoch: 9,
                protocolCapabilities: .current,
                coordinatorReplayFencePublicKey: replayFenceTestPublicKey
            ))
        let ackText = try ProviderProtocolCodec.encodeCoordinatorMessageString(ack)
        await client.handleIncomingText(ackText)

        let wrongGeneration = CoordinatorMessage.start(
            V2Start(
                identity: attempt(
                    providerID: providerID,
                    generation: id(0x99),
                    sessionEpoch: 9
                )))
        await client.handleIncomingText(
            try ProviderProtocolCodec.encodeCoordinatorMessageString(wrongGeneration))
        await client.handleIncomingText(
            try ProviderProtocolCodec.encodeCoordinatorMessageString(validStart))

        let received = await iterator.next()
        #expect(received?.command == CoordinatorClientCodec.v2ControlMessage(from: validStart))
        await client.shutdown()
    }

    @Test("client defaults to byte-compatible v1 registration until handler is enabled")
    func runtimeHandlerGate() async throws {
        let config = CoordinatorClientConfig(
            url: "wss://example.test/v1/providers/ws",
            hardware: hardware(),
            models: [],
            backendName: "mlx_swift_lm"
        )
        let defaultClient = CoordinatorClient(
            config: config,
            stats: AtomicProviderStats(),
            state: ProviderState(),
            liveAPNsToken: { nil }
        )
        let enabledClient = CoordinatorClient(
            config: config,
            stats: AtomicProviderStats(),
            state: ProviderState(),
            liveAPNsToken: { nil }
        )
        #expect(await enabledClient.installProtocolV2RuntimeHandler())
        #expect(await defaultClient.v2Negotiation.localCapabilities == nil)
        #expect(await enabledClient.v2Negotiation.localCapabilities == .current)

        let legacyRegistration = try CoordinatorClientCodec.encodeRegistration(from: config)
        let object = try #require(
            JSONSerialization.jsonObject(with: legacyRegistration) as? [String: Any])
        #expect(object["protocol_capabilities"] == nil)
        #expect(object["provider_process_generation"] == nil)

        let disabledGeneration = await defaultClient.processGeneration()
        await defaultClient.handleIncomingText(
            try ProviderProtocolCodec.encodeCoordinatorMessageString(
                .registerAck(
                    V2RegisterAcknowledgement(
                        providerID: id(0x11),
                        providerProcessGeneration: disabledGeneration,
                        sessionEpoch: 1,
                        protocolCapabilities: .current,
                        coordinatorReplayFencePublicKey: replayFenceTestPublicKey
                    )
                ))
        )
        #expect(await defaultClient.protocolV2Session() == nil)
        #expect(await defaultClient.acknowledgedProviderID() == nil)
        await defaultClient.shutdown()
        await enabledClient.shutdown()
    }

    @Test("ACK generation, provider identity, duplicate, and replay fences are strict")
    func acknowledgementReplayAndIdentityFences() throws {
        let providerID = id(0x11)
        let generation = id(0x22)
        var state = V2NegotiationState(
            localCapabilities: .current,
            processGeneration: generation
        )
        #expect(throws: V2NegotiationError.processGenerationMismatch) {
            _ = try state.accept(
                V2RegisterAcknowledgement(
                    providerID: providerID,
                    providerProcessGeneration: id(0x99),
                    sessionEpoch: 1,
                    protocolCapabilities: .current,
                    coordinatorReplayFencePublicKey: replayFenceTestPublicKey
                ))
        }

        let first = V2RegisterAcknowledgement(
            providerID: providerID,
            providerProcessGeneration: generation,
            sessionEpoch: 1,
            protocolCapabilities: .current,
            coordinatorReplayFencePublicKey: replayFenceTestPublicKey
        )
        _ = try state.accept(first)
        #expect(state.acknowledgedProviderID == providerID)
        #expect(throws: V2NegotiationError.duplicateRegisterAcknowledgement) {
            _ = try state.accept(first)
        }

        state.resetForReconnect()
        #expect(throws: V2NegotiationError.sessionEpochReplay(actual: 1, highest: 1)) {
            _ = try state.accept(first)
        }
        #expect(throws: V2NegotiationError.providerIDMismatch) {
            _ = try state.accept(
                V2RegisterAcknowledgement(
                    providerID: id(0x33),
                    providerProcessGeneration: generation,
                    sessionEpoch: 2,
                    protocolCapabilities: .current,
                    coordinatorReplayFencePublicKey: replayFenceTestPublicKey
                ))
        }
    }

    @Test("queued commands from a prior session are rejected at consumption")
    func reconnectQueuedFrameRejection() async throws {
        let providerID = id(0x11)
        let config = CoordinatorClientConfig(
            url: "wss://example.test/v1/providers/ws",
            hardware: hardware(),
            models: [],
            backendName: "mlx_swift_lm"
        )
        let client = CoordinatorClient(
            config: config,
            stats: AtomicProviderStats(),
            state: ProviderState(),
            liveAPNsToken: { nil }
        )
        #expect(await client.installProtocolV2RuntimeHandler())
        let generation = await client.processGeneration()
        var iterator = await client.protocolV2Commands().makeAsyncIterator()
        var binaryIterator = await client.protocolV2BinaryFrames().makeAsyncIterator()

        for epoch in [UInt64(1), UInt64(2)] {
            if epoch > 1 {
                await client.resetV2NegotiationForReconnect()
            }
            await client.handleIncomingText(
                try ProviderProtocolCodec.encodeCoordinatorMessageString(
                    .registerAck(
                        V2RegisterAcknowledgement(
                            providerID: providerID,
                            providerProcessGeneration: generation,
                            sessionEpoch: epoch,
                            protocolCapabilities: .current,
                            coordinatorReplayFencePublicKey: replayFenceTestPublicKey
                        ))
                ))
            await client.handleIncomingText(
                try ProviderProtocolCodec.encodeCoordinatorMessageString(
                    .start(
                        V2Start(
                            identity: attempt(
                                providerID: providerID,
                                generation: generation,
                                sessionEpoch: epoch
                            )))
                ))
            let binaryWire = try V2BinaryFrame(
                header: binaryHeader(
                    providerID: providerID,
                    generation: generation,
                    sessionEpoch: epoch,
                    minor: 0
                ),
                ciphertext: Data()
            ).encode()
            await client.handleIncomingBinary(binaryWire)
        }

        let received = await iterator.next()
        #expect(received?.session.identity.sessionEpoch == 2)
        #expect(received?.command.attemptIdentity?.sessionEpoch == 2)
        let receivedBinary = await binaryIterator.next()
        #expect(receivedBinary?.session.identity.sessionEpoch == 2)
        #expect(receivedBinary?.frame.header.sessionEpoch == 2)
        await client.shutdown()
    }

    @Test("session lifecycle overflow shuts the client down fail-closed")
    func sessionLifecycleOverflowFailsClosed() async throws {
        let providerID = id(0x11)
        let client = CoordinatorClient(
            config: CoordinatorClientConfig(
                url: "wss://example.test/v1/providers/ws",
                hardware: hardware(),
                models: [],
                backendName: "mlx_swift_lm"
            ),
            stats: AtomicProviderStats(),
            state: ProviderState(),
            liveAPNsToken: { nil }
        )
        #expect(await client.installProtocolV2RuntimeHandler())
        let generation = await client.processGeneration()
        await client.handleIncomingText(
            try ProviderProtocolCodec.encodeCoordinatorMessageString(
                .registerAck(
                    V2RegisterAcknowledgement(
                        providerID: providerID,
                        providerProcessGeneration: generation,
                        sessionEpoch: 1,
                        protocolCapabilities: .current,
                        coordinatorReplayFencePublicKey: replayFenceTestPublicKey
                    ))))
        let session = V2NegotiatedSession(
            identity: ProviderSessionIdentity(
                providerID: providerID,
                processGeneration: generation,
                sessionEpoch: 1
            ),
            capabilities: .current,
            coordinatorReplayFencePublicKey:
                replayFenceTestKey.publicKey.rawRepresentation
        )
        var overflowed = false
        for _ in 0...CoordinatorClient.v2SessionEventBufferCapacity {
            if !(await client.publishV2SessionEvent(.negotiated(session))) {
                overflowed = true
                break
            }
        }
        #expect(overflowed)
        #expect(client.shutdownRequested)
    }

    @Test("command and binary overflow fail closed and stale queues clean on reconnect")
    func inboundOverflowFailsSessionClosed() async throws {
        let providerID = id(0x11)
        let client = CoordinatorClient(
            config: CoordinatorClientConfig(
                url: "wss://example.test/v1/providers/ws",
                hardware: hardware(),
                models: [],
                backendName: "mlx_swift_lm"
            ),
            stats: AtomicProviderStats(),
            state: ProviderState(),
            liveAPNsToken: { nil }
        )
        #expect(await client.installProtocolV2RuntimeHandler())
        let generation = await client.processGeneration()
        var commands = await client.protocolV2Commands().makeAsyncIterator()
        var binaries = await client.protocolV2BinaryFrames().makeAsyncIterator()

        func acknowledge(_ epoch: UInt64) async throws {
            await client.handleIncomingText(
                try ProviderProtocolCodec.encodeCoordinatorMessageString(
                    .registerAck(
                        V2RegisterAcknowledgement(
                            providerID: providerID,
                            providerProcessGeneration: generation,
                            sessionEpoch: epoch,
                            protocolCapabilities: .current,
                            coordinatorReplayFencePublicKey: replayFenceTestPublicKey
                        ))))
        }

        try await acknowledge(1)
        for _ in 0...CoordinatorClient.v2CommandBufferCapacity {
            await client.handleIncomingText(
                try ProviderProtocolCodec.encodeCoordinatorMessageString(
                    .start(
                        V2Start(
                            identity: attempt(
                                providerID: providerID,
                                generation: generation,
                                sessionEpoch: 1
                            )))))
        }
        #expect(await client.protocolV2Session() == nil)

        try await acknowledge(2)
        let epoch2Start = V2Start(
            identity: attempt(
                providerID: providerID,
                generation: generation,
                sessionEpoch: 2
            ))
        await client.handleIncomingText(
            try ProviderProtocolCodec.encodeCoordinatorMessageString(
                .start(epoch2Start)))
        #expect((await commands.next())?.command == .start(epoch2Start))

        let epoch2Wire = try V2BinaryFrame(
            header: binaryHeader(
                providerID: providerID,
                generation: generation,
                sessionEpoch: 2,
                minor: 0
            ),
            ciphertext: Data()
        ).encode()
        for _ in 0...CoordinatorClient.v2BinaryBufferCapacity {
            await client.handleIncomingBinary(epoch2Wire)
        }
        #expect(await client.protocolV2Session() == nil)

        try await acknowledge(3)
        let epoch3Wire = try V2BinaryFrame(
            header: binaryHeader(
                providerID: providerID,
                generation: generation,
                sessionEpoch: 3,
                minor: 0
            ),
            ciphertext: Data()
        ).encode()
        await client.handleIncomingBinary(epoch3Wire)
        #expect((await binaries.next())?.session.identity.sessionEpoch == 3)
        await client.shutdown()
    }

    @Test("historical terminal replay and ACK rejection use narrow stale exceptions")
    func historicalTerminalReplayFence() throws {
        let providerID = id(0x11)
        let currentGeneration = id(0x22)
        var state = V2NegotiationState(
            localCapabilities: .current,
            processGeneration: currentGeneration
        )
        _ = try state.accept(
            V2RegisterAcknowledgement(
                providerID: providerID,
                providerProcessGeneration: currentGeneration,
                sessionEpoch: 9,
                protocolCapabilities: .current,
                coordinatorReplayFencePublicKey: replayFenceTestPublicKey
            ))

        let terminal = try historicalTerminal(
            providerID: providerID,
            generation: id(0x77),
            sessionEpoch: 2
        )
        let replay = try V2HistoricalTerminalReplay(terminal: terminal) {
            provider, generation, digest, signature in
            provider == providerID
                && generation == id(0x77)
                && digest == terminal.terminalDigest
                && signature == Data([1, 2, 3])
        }
        try state.validateHistoricalTerminal(replay)
        try state.validate(
            V2CoordinatorControlMessage.terminalAck(
                V2TerminalAck(
                    identity: terminal.identity,
                    terminalDigest: terminal.terminalDigest,
                    disposition: .settled
                )))
        try state.validateHistoricalStructuredError(
            V2StructuredError(
                identity: terminal.identity,
                errorClass: .security,
                message: "terminal acknowledgement conflict"
            ))
        #expect(throws: V2NegotiationError.capabilityNotNegotiated) {
            try state.validateHistoricalStructuredError(
                V2StructuredError(
                    identity: terminal.identity,
                    errorClass: .fault
                ))
        }
        #expect(throws: V2NegotiationError.identityMismatch) {
            try state.validate(V2ProviderControlMessage.terminal(terminal))
        }
        #expect(throws: V2NegotiationError.identityMismatch) {
            try state.validate(
                V2ProviderControlMessage.startAck(
                    V2StartAck(
                        identity: terminal.identity
                    )))
        }
    }

    @Test("shared cancel discriminator is selected only by negotiated context")
    func contextualCancelDecode() throws {
        let wire = #"""
            {
              "type":"cancel",
              "request_id":"33333333-3333-3333-3333-333333333333",
              "attempt_id":"44444444-4444-4444-4444-444444444444",
              "provider_id":"11111111-1111-1111-1111-111111111111",
              "provider_process_generation":"22222222-2222-2222-2222-222222222222",
              "session_epoch":9,
              "reservation_id":"55555555-5555-5555-5555-555555555555",
              "lease_id":"66666666-6666-6666-6666-666666666666",
              "future_v1_field":true
            }
            """#
        let legacy = try ProviderProtocolCodec.decodeCoordinatorMessage(from: wire)
        guard case .cancel(let cancel) = legacy else {
            Issue.record("additive v1 cancel was upgraded without negotiation")
            return
        }
        #expect(cancel.requestId == "33333333-3333-3333-3333-333333333333")

        let negotiated = try ProviderProtocolCodec.decodeCoordinatorMessage(
            from: wire,
            negotiatedV2Session: true
        )
        guard case .v2Cancel(let cancel) = negotiated else {
            Issue.record("negotiated cancel did not decode as v2")
            return
        }
        #expect(cancel.identity.attemptID == id(0x44))
    }

    @Test("start is single-shot and successful registration resets reconnect backoff")
    func lifecycleFences() async {
        let client = CoordinatorClient(
            config: CoordinatorClientConfig(
                url: "%zz",
                hardware: hardware(),
                models: [],
                backendName: "mlx_swift_lm"
            ),
            stats: AtomicProviderStats(),
            state: ProviderState(),
            liveAPNsToken: { nil }
        )
        _ = await client.start()
        _ = await client.start()
        #expect(await client.runLoopLaunchCount == 1)

        _ = await client.nextReconnectDelay()
        let escalated = await client.nextReconnectDelay()
        await client.markRegistrationSucceeded()
        let reset = await client.nextReconnectDelay()
        #expect(escalated >= 1)
        #expect(reset <= 1)
        await client.shutdown()
    }

    @Test("outbound router is bounded and detached while disconnected")
    func boundedOutboundRouter() async {
        let router = OutboundRouter()
        let (stream, continuation) = AsyncStream<OutboundMessage>.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        let activation = router.activate(continuation)
        #expect(router.yield(.inferenceAccepted(requestId: "first")) == .enqueued)
        #expect(router.yield(.inferenceAccepted(requestId: "second")) == .droppedBufferFull)
        router.deactivate(activation)
        #expect(router.yield(.inferenceAccepted(requestId: "third")) == .droppedDisconnected)
        var iterator = stream.makeAsyncIterator()
        if let message = await iterator.next(),
            case .inferenceAccepted(let requestID) = message
        {
            #expect(requestID == "first")
        } else {
            Issue.record("first bounded message was not retained")
        }
    }

    @Test("safe binary API validates session and writes a WebSocket binary frame")
    func binaryOutboundTransport() async throws {
        let mock = MockCoordinator()
        let baseURL = try await mock.start()
        defer { Task { await mock.shutdown() } }
        let client = CoordinatorClient(
            config: CoordinatorClientConfig(
                url: baseURL.mockProviderWebSocketURL(),
                hardware: hardware(),
                models: [],
                backendName: "mlx_swift_lm",
                heartbeatInterval: 60
            ),
            stats: AtomicProviderStats(),
            state: ProviderState(),
            liveAPNsToken: { nil }
        )
        #expect(await client.installProtocolV2RuntimeHandler())
        _ = await client.start()
        defer { Task { await client.shutdown() } }
        let registration = try #require(
            await mock.awaitFirstRegister(timeout: .seconds(5)))
        let generation = try #require(registration.providerProcessGeneration)
        let providerID = id(0x11)
        try await mock.pushRegisterAcknowledgement(
            providerID: providerID,
            providerProcessGeneration: generation,
            sessionEpoch: 1,
            protocolCapabilities: .current
        )

        let senderSecret = Data((1...32).map(UInt8.init))
        let recipient = try NodeKeyPair(rawSecret: Data((101...132).map(UInt8.init)))
        let wire = try V2FrameCrypto.seal(
            senderPrivateKey: senderSecret,
            recipientPublicKey: recipient.publicKeyBytes,
            header: V2BinaryFrameHeader(
                kind: .responseChunk,
                flags: .finalFrame,
                minor: 0,
                providerID: providerID,
                providerProcessGeneration: generation,
                sessionEpoch: 1,
                requestID: id(0x33),
                attemptID: id(0x44),
                reservationID: id(0x55),
                leaseID: id(0x66),
                nonce: Data(repeating: 0x77, count: 24),
                rollingDigest: Data(repeating: 0x88, count: 32),
                sequence: 1
            ),
            plaintext: Data("chunk".utf8)
        )

        // Wait until the ACK has reached the actor before attempting the write.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await client.protocolV2Session() == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await client.protocolV2Session() != nil)
        try await client.sendProtocolV2BinaryFrame(wire)
        let snapshot = try await mock.waitForSnapshot(timeout: .seconds(5)) {
            $0.binaryFrames == [wire]
        }
        #expect(snapshot?.binaryFrames == [wire])
    }

    @Test("mock coordinator round-trips register ACK encrypted prepare and start")
    func mockPrepareStartRoundTrip() async throws {
        let mock = MockCoordinator()
        let baseURL = try await mock.start()
        defer { Task { await mock.shutdown() } }
        let providerKeys = NodeKeyPair.generate()
        let client = CoordinatorClient(
            config: CoordinatorClientConfig(
                url: baseURL.mockProviderWebSocketURL(),
                hardware: hardware(),
                models: [],
                backendName: "mlx_swift_lm",
                heartbeatInterval: 60,
                publicKey: providerKeys.publicKeyBase64
            ),
            stats: AtomicProviderStats(),
            state: ProviderState(),
            liveAPNsToken: { nil }
        )
        #expect(await client.installProtocolV2RuntimeHandler())
        _ = await client.start()
        defer { Task { await client.shutdown() } }

        let registration = try #require(
            await mock.awaitFirstRegister(timeout: .seconds(5)))
        let generation = try #require(registration.providerProcessGeneration)
        let providerID = id(0x11)
        let identity = attempt(
            providerID: providerID,
            generation: generation,
            sessionEpoch: 1
        )
        var commands = await client.protocolV2Commands().makeAsyncIterator()
        try await mock.pushRegisterAcknowledgement(
            providerID: providerID,
            providerProcessGeneration: generation,
            sessionEpoch: 1,
            protocolCapabilities: .current
        )
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await client.protocolV2Session() == nil,
            ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await client.protocolV2Session() != nil)

        let plaintext = Data(
            #"{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":true}"#
                .utf8)
        _ = try await mock.pushV2Prepare(
            identity: identity,
            model: "model-a",
            providerPublicKeyBase64: providerKeys.publicKeyBase64,
            chatRequestJSON: plaintext
        )
        let prepareDelivery = try #require(await commands.next())
        guard case .prepare(let prepare) = prepareDelivery.command else {
            Issue.record("expected encrypted prepare")
            return
        }
        #expect(try providerKeys.decryptPayload(prepare.encryptedBody) == plaintext)
        #expect(try V2Prepare.digest(of: prepare.encryptedBody) == prepare.requestDigest)
        #expect(mock.snapshot().binaryFrames.isEmpty)

        try await mock.pushV2Start(identity: identity)
        let startDelivery = try #require(await commands.next())
        #expect(startDelivery.command == .start(V2Start(identity: identity)))
        #expect(mock.snapshot().binaryFrames.isEmpty)
    }
}

private func id(_ byte: UInt8) -> ProtocolV2UUID {
    ProtocolV2UUID(bytes: Data(repeating: byte, count: 16))!
}

private func attempt(
    providerID: ProviderID,
    generation: ProviderProcessGenerationID,
    sessionEpoch: UInt64
) -> AttemptIdentity {
    AttemptIdentity(
        providerID: providerID,
        providerProcessGeneration: generation,
        sessionEpoch: sessionEpoch,
        requestID: id(0x33),
        attemptID: id(0x44),
        reservationID: id(0x55),
        leaseID: id(0x66)
    )
}

private func historicalTerminal(
    providerID: ProviderID,
    generation: ProviderProcessGenerationID,
    sessionEpoch: UInt64
) throws -> V2ProviderTerminal {
    var terminal = V2ProviderTerminal(
        identity: attempt(
            providerID: providerID,
            generation: generation,
            sessionEpoch: sessionEpoch
        ),
        outcome: .completed,
        promptTokens: 3,
        completionTokens: 2,
        responseHash: ProtocolV2Digest(bytes: Data(repeating: 0x77, count: 32))!,
        finalGeneratedTokens: 2,
        rollingDigest: ProtocolV2Digest(bytes: Data(repeating: 0x88, count: 32))!,
        model: "model-a",
        signature: V2TerminalSignature(bytes: Data([1, 2, 3]))
    )
    terminal.terminalDigest = try terminal.computedDigest()
    return terminal
}

private func hardware() -> HardwareInfo {
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

private func binaryHeader(
    providerID: ProviderID,
    generation: ProviderProcessGenerationID,
    sessionEpoch: UInt64,
    minor: UInt16
) throws -> V2BinaryFrameHeader {
    try V2BinaryFrameHeader(
        kind: .preparePayload,
        flags: .empty,
        minor: minor,
        providerID: providerID,
        providerProcessGeneration: generation,
        sessionEpoch: sessionEpoch,
        requestID: id(0x33),
        attemptID: id(0x44),
        reservationID: id(0x55),
        leaseID: id(0x66),
        nonce: Data(repeating: 0x77, count: 24),
        rollingDigest: Data(repeating: 0x88, count: 32),
        sequence: 0
    )
}

private func collectSessionEvents(
    _ stream: AsyncStream<V2SessionEvent>,
    count: Int,
    timeout: Duration
) async throws -> [V2SessionEvent] {
    try await withThrowingTaskGroup(of: [V2SessionEvent].self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            var events: [V2SessionEvent] = []
            while events.count < count, let event = await iterator.next() {
                events.append(event)
            }
            return events
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw CancellationError()
        }
        let result = try await group.next()
        group.cancelAll()
        return try #require(result)
    }
}
