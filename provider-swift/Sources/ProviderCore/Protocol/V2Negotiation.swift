import Foundation

/// Explicit server response to registration. A client remains on v1 unless
/// `protocol_capabilities` negotiates the complete v2 base contract.
public struct V2RegisterAcknowledgement: Sendable, Equatable, Codable {
    public var providerID: ProviderID
    public var providerProcessGeneration: ProviderProcessGenerationID
    public var sessionEpoch: UInt64
    public var protocolCapabilities: ProtocolCapabilities?
    public var coordinatorReplayFencePublicKey: String?

    public init(
        providerID: ProviderID,
        providerProcessGeneration: ProviderProcessGenerationID,
        sessionEpoch: UInt64,
        protocolCapabilities: ProtocolCapabilities? = nil,
        coordinatorReplayFencePublicKey: String? = nil
    ) {
        self.providerID = providerID
        self.providerProcessGeneration = providerProcessGeneration
        self.sessionEpoch = sessionEpoch
        self.protocolCapabilities = protocolCapabilities
        self.coordinatorReplayFencePublicKey = coordinatorReplayFencePublicKey
    }

    enum CodingKeys: String, CodingKey {
        case providerID = "provider_id"
        case providerProcessGeneration = "provider_process_generation"
        case sessionEpoch = "session_epoch"
        case protocolCapabilities = "protocol_capabilities"
        case coordinatorReplayFencePublicKey =
            "coordinator_replay_fence_public_key"
    }
}

public struct V2NegotiatedSession: Sendable, Equatable {
    public var identity: ProviderSessionIdentity
    public var capabilities: ProtocolCapabilities
    public var coordinatorReplayFencePublicKey: Data

    public init(
        identity: ProviderSessionIdentity,
        capabilities: ProtocolCapabilities,
        coordinatorReplayFencePublicKey: Data
    ) {
        self.identity = identity
        self.capabilities = capabilities
        self.coordinatorReplayFencePublicKey = coordinatorReplayFencePublicKey
    }

    public func replayFenceVerifier() throws
        -> P256CoordinatorReplayFenceProofVerifier
    {
        try P256CoordinatorReplayFenceProofVerifier(
            rawRepresentation: coordinatorReplayFencePublicKey)
    }
}

public enum V2SessionEvent: Sendable, Equatable {
    case negotiated(V2NegotiatedSession)
    case ended(V2NegotiatedSession)
}

public enum V2NegotiationError: Error, Sendable, Equatable {
    case negotiationDisabled
    case commandBeforeNegotiation
    case incompatibleCapabilities
    case processGenerationMismatch
    case providerIDMismatch
    case sessionEpochReplay(actual: UInt64, highest: UInt64)
    case duplicateRegisterAcknowledgement
    case identityMismatch
    case staleSession
    case capabilityNotNegotiated
    case invalidInboundFrameKind(V2BinaryFrameKind)
    case invalidOutboundFrameKind(V2BinaryFrameKind)
    case invalidCoordinatorReplayFencePublicKey
    case minorVersionMismatch(actual: UInt16, expected: UInt16)
    case binaryProtocol(V2ProtocolError)
}

/// Per-WebSocket negotiation state. Process generation is stable across resets;
/// provider ID and session epoch are accepted only from an explicit register ACK.
public struct V2NegotiationState: Sendable, Equatable {
    /// nil means the runtime handler is not integrated and v2 must not be
    /// advertised or accepted.
    public let localCapabilities: ProtocolCapabilities?
    public let processGeneration: ProviderProcessGenerationID
    public private(set) var session: V2NegotiatedSession?
    public private(set) var acknowledgedProviderID: ProviderID?
    public private(set) var highestAcknowledgedSessionEpoch: UInt64?
    private var acknowledgementAcceptedForConnection: Bool

    public init(
        localCapabilities: ProtocolCapabilities? = .current,
        processGeneration: ProviderProcessGenerationID = ProviderProcessIdentity.generation
    ) {
        self.localCapabilities = localCapabilities
        self.processGeneration = processGeneration
        self.session = nil
        self.acknowledgedProviderID = nil
        self.highestAcknowledgedSessionEpoch = nil
        self.acknowledgementAcceptedForConnection = false
    }

    public mutating func resetForReconnect() {
        session = nil
        acknowledgementAcceptedForConnection = false
    }

    /// An ACK without capabilities is an explicit v1 selection, not an error.
    @discardableResult
    public mutating func accept(
        _ acknowledgement: V2RegisterAcknowledgement
    ) throws -> V2NegotiatedSession? {
        guard !acknowledgementAcceptedForConnection else {
            throw V2NegotiationError.duplicateRegisterAcknowledgement
        }
        guard acknowledgement.providerProcessGeneration == processGeneration else {
            throw V2NegotiationError.processGenerationMismatch
        }
        if let acknowledgedProviderID,
            acknowledgement.providerID != acknowledgedProviderID
        {
            throw V2NegotiationError.providerIDMismatch
        }
        if let highest = highestAcknowledgedSessionEpoch,
            acknowledgement.sessionEpoch <= highest
        {
            throw V2NegotiationError.sessionEpochReplay(
                actual: acknowledgement.sessionEpoch,
                highest: highest
            )
        }

        let negotiated: ProtocolCapabilities?
        if let peer = acknowledgement.protocolCapabilities {
            guard let localCapabilities else {
                throw V2NegotiationError.negotiationDisabled
            }
            guard let overlap = localCapabilities.negotiate(with: peer),
                overlap.supportsV2
            else {
                throw V2NegotiationError.incompatibleCapabilities
            }
            negotiated = overlap
        } else {
            negotiated = nil
        }

        guard let negotiated else {
            acknowledgedProviderID = acknowledgement.providerID
            highestAcknowledgedSessionEpoch = acknowledgement.sessionEpoch
            acknowledgementAcceptedForConnection = true
            session = nil
            return nil
        }

        let identity = ProviderSessionIdentity(
            providerID: acknowledgement.providerID,
            processGeneration: acknowledgement.providerProcessGeneration,
            sessionEpoch: acknowledgement.sessionEpoch
        )
        guard negotiated.coordinatorReplayFences,
            let encodedKey = acknowledgement.coordinatorReplayFencePublicKey,
            let verifier = try? P256CoordinatorReplayFenceProofVerifier(
                base64EncodedPublicKey: encodedKey)
        else {
            throw V2NegotiationError.invalidCoordinatorReplayFencePublicKey
        }
        let accepted = V2NegotiatedSession(
            identity: identity,
            capabilities: negotiated,
            coordinatorReplayFencePublicKey: verifier.publicKeyRawRepresentation
        )
        acknowledgedProviderID = acknowledgement.providerID
        highestAcknowledgedSessionEpoch = acknowledgement.sessionEpoch
        acknowledgementAcceptedForConnection = true
        session = accepted
        return accepted
    }

    public func validate(_ message: V2CoordinatorControlMessage) throws {
        guard let session else {
            throw V2NegotiationError.commandBeforeNegotiation
        }
        if case .coordinatorReplayFence(let proof) = message {
            guard session.capabilities.coordinatorReplayFences else {
                throw V2NegotiationError.capabilityNotNegotiated
            }
            // Replay fences are the signed exception to the live process/session
            // fence: after a provider restart, the current coordinator session must
            // be able to retire abort tombstones owned by an older process
            // generation. The accepted register-ACK key authenticates the complete
            // proof in the handler; negotiation only binds its stable provider ID.
            guard proof.providerID == session.identity.providerID.description else {
                throw V2NegotiationError.providerIDMismatch
            }
            return
        }
        if case .terminalAck(let acknowledgement) = message {
            guard session.capabilities.durableTerminals else {
                throw V2NegotiationError.capabilityNotNegotiated
            }
            // A replayed durable terminal intentionally carries its original
            // process generation and session epoch. Permit only the stable
            // provider-ID exception here; TerminalJournal remains the authority
            // that validates the complete historical identity and digest before
            // deleting anything.
            guard acknowledgement.identity.providerID == session.identity.providerID,
                acknowledgedProviderID == session.identity.providerID
            else {
                throw V2NegotiationError.providerIDMismatch
            }
            return
        }
        if case .queryAttempt(let query) = message {
            guard session.capabilities.attemptReconciliation else {
                throw V2NegotiationError.capabilityNotNegotiated
            }
            guard query.identity.providerID == session.identity.providerID,
                acknowledgedProviderID == session.identity.providerID,
                query.identity.sessionEpoch <= session.identity.sessionEpoch
            else {
                throw V2NegotiationError.providerIDMismatch
            }
            return
        }
        if case .start(let start) = message,
            start.identity.sessionEpoch < session.identity.sessionEpoch
        {
            guard session.capabilities.startAuthorization,
                session.capabilities.attemptReconciliation
            else {
                throw V2NegotiationError.capabilityNotNegotiated
            }
            // A same-process reconnect may resume an exact prepared lease from
            // the preceding socket epoch. V2PreparedAttemptCoordinator still
            // requires the complete historical identity to match its live
            // binding before it durably starts generation.
            guard start.identity.providerID == session.identity.providerID,
                start.identity.providerProcessGeneration
                    == session.identity.processGeneration
            else {
                throw V2NegotiationError.identityMismatch
            }
            return
        }
        guard let attemptIdentity = message.attemptIdentity,
            attemptIdentity.belongs(to: session.identity)
        else {
            throw V2NegotiationError.identityMismatch
        }
        switch message {
        case .prepare:
            guard session.capabilities.preparedLeases else {
                throw V2NegotiationError.capabilityNotNegotiated
            }
        case .start:
            guard session.capabilities.startAuthorization else {
                throw V2NegotiationError.capabilityNotNegotiated
            }
        case .queryAttempt:
            preconditionFailure("historical attempt query handled above")
        case .abort:
            guard session.capabilities.preparedLeases else {
                throw V2NegotiationError.capabilityNotNegotiated
            }
        case .cancel:
            // Cancellation is part of the base v2 attempt lifecycle. The
            // optional `cancel_ack` capability gates the provider response,
            // not the coordinator's ability to cancel an active attempt.
            break
        case .terminalAck:
            preconditionFailure("historical terminal ACK handled above")
        case .coordinatorReplayFence:
            preconditionFailure("coordinator replay fence handled above")
        }
    }

    public func validate(_ header: V2BinaryFrameHeader) throws {
        guard let session else {
            throw V2NegotiationError.commandBeforeNegotiation
        }
        guard session.capabilities.binaryPayloadFrames else {
            throw V2NegotiationError.capabilityNotNegotiated
        }
        do {
            try header.validateSession(
                session.identity,
                negotiatedMinor: session.capabilities.protocolMinor
            )
        } catch V2ProtocolError.identityMismatch {
            throw V2NegotiationError.identityMismatch
        } catch V2ProtocolError.minorVersionMismatch(let actual, let expected) {
            throw V2NegotiationError.minorVersionMismatch(
                actual: actual,
                expected: expected
            )
        } catch let error as V2ProtocolError {
            throw V2NegotiationError.binaryProtocol(error)
        } catch {
            throw V2NegotiationError.identityMismatch
        }
    }

    public func validateInboundBinary(_ header: V2BinaryFrameHeader) throws {
        try validate(header)
        guard header.kind == .preparePayload else {
            throw V2NegotiationError.invalidInboundFrameKind(header.kind)
        }
    }

    public func validateOutboundBinary(_ header: V2BinaryFrameHeader) throws {
        try validate(header)
        guard header.kind == .responseChunk || header.kind == .terminalPayload else {
            throw V2NegotiationError.invalidOutboundFrameKind(header.kind)
        }
    }

    public func validate(_ message: V2ProviderControlMessage) throws {
        guard let session else {
            throw V2NegotiationError.commandBeforeNegotiation
        }
        switch message {
        case .prepared(let value):
            try validate(value.identity, session: session)
            guard session.capabilities.preparedLeases else {
                throw V2NegotiationError.capabilityNotNegotiated
            }
        case .startAck(let value):
            guard session.capabilities.startAck else {
                throw V2NegotiationError.capabilityNotNegotiated
            }
            if value.identity.sessionEpoch < session.identity.sessionEpoch {
                guard session.capabilities.attemptReconciliation else {
                    throw V2NegotiationError.capabilityNotNegotiated
                }
                guard value.identity.providerID == session.identity.providerID,
                    value.identity.providerProcessGeneration
                        == session.identity.processGeneration
                else {
                    throw V2NegotiationError.identityMismatch
                }
            } else {
                try validate(value.identity, session: session)
            }
        case .attemptStatus(let value):
            guard session.capabilities.attemptReconciliation else {
                throw V2NegotiationError.capabilityNotNegotiated
            }
            guard value.identity.providerID == session.identity.providerID,
                value.identity.sessionEpoch <= session.identity.sessionEpoch
            else {
                throw V2NegotiationError.identityMismatch
            }
        case .abortAck(let value):
            try validate(value.identity, session: session)
            guard session.capabilities.abortAck else {
                throw V2NegotiationError.capabilityNotNegotiated
            }
        case .cancelAck(let value):
            try validate(value.identity, session: session)
            guard session.capabilities.cancelAck else {
                throw V2NegotiationError.capabilityNotNegotiated
            }
        case .terminal(let value):
            try validate(value.identity, session: session)
            guard session.capabilities.durableTerminals else {
                throw V2NegotiationError.capabilityNotNegotiated
            }
        case .structuredError(let value):
            try validate(value.identity, session: session)
            guard session.capabilities.structuredErrors else {
                throw V2NegotiationError.capabilityNotNegotiated
            }
        case .modelReady(let value):
            guard value.identity == session.identity else {
                throw V2NegotiationError.identityMismatch
            }
            guard session.capabilities.modelLifecycleEvents else {
                throw V2NegotiationError.capabilityNotNegotiated
            }
        case .modelGone(let value):
            guard value.identity == session.identity else {
                throw V2NegotiationError.identityMismatch
            }
            guard session.capabilities.modelLifecycleEvents else {
                throw V2NegotiationError.capabilityNotNegotiated
            }
        case .replayFenceAck(let value):
            guard value.providerID == session.identity.providerID else {
                throw V2NegotiationError.providerIDMismatch
            }
            guard session.capabilities.coordinatorReplayFences else {
                throw V2NegotiationError.capabilityNotNegotiated
            }
        }
    }

    /// Historical replay is the sole outbound exception to the current
    /// process-generation/session fence. The terminal wrapper has already
    /// verified the canonical digest and provider/process-bound signature; the
    /// live ACK must still bind the same stable provider ID and negotiate
    /// durable terminals.
    public func validateHistoricalTerminal(
        _ replay: V2HistoricalTerminalReplay
    ) throws {
        guard let session else {
            throw V2NegotiationError.commandBeforeNegotiation
        }
        guard session.capabilities.durableTerminals else {
            throw V2NegotiationError.capabilityNotNegotiated
        }
        guard acknowledgedProviderID == session.identity.providerID,
            replay.terminal.identity.providerID == session.identity.providerID
        else {
            throw V2NegotiationError.providerIDMismatch
        }
    }

    /// A rejected historical terminal ACK needs a typed response carrying the
    /// same historical attempt identity. This is the only non-terminal outbound
    /// stale-session exception, and it is restricted to security errors for the
    /// stable provider ID.
    public func validateHistoricalStructuredError(
        _ error: V2StructuredError
    ) throws {
        guard let session else {
            throw V2NegotiationError.commandBeforeNegotiation
        }
        guard session.capabilities.structuredErrors else {
            throw V2NegotiationError.capabilityNotNegotiated
        }
        guard error.errorClass == .security else {
            throw V2NegotiationError.capabilityNotNegotiated
        }
        guard acknowledgedProviderID == session.identity.providerID,
            error.identity.providerID == session.identity.providerID
        else {
            throw V2NegotiationError.providerIDMismatch
        }
    }

    /// Revalidates a queued command against the current session immediately
    /// before a consumer receives it.
    public func validate(_ delivery: V2InboundCommand) throws {
        guard session == delivery.session else {
            throw V2NegotiationError.staleSession
        }
        try validate(delivery.command)
    }

    /// Revalidates a queued binary frame against the current session
    /// immediately before a consumer receives it.
    public func validate(_ delivery: V2InboundBinaryFrame) throws {
        guard session == delivery.session else {
            throw V2NegotiationError.staleSession
        }
        try validateInboundBinary(delivery.frame.header)
    }

    private func validate(
        _ identity: AttemptIdentity,
        session: V2NegotiatedSession
    ) throws {
        guard identity.belongs(to: session.identity) else {
            throw V2NegotiationError.identityMismatch
        }
    }
}

/// A negotiated command plus the exact session snapshot under which it was
/// accepted. Consumers receive it only after a second current-session check.
public struct V2InboundCommand: Sendable, Equatable {
    public let session: V2NegotiatedSession
    public let command: V2CoordinatorControlMessage

    public init(session: V2NegotiatedSession, command: V2CoordinatorControlMessage) {
        self.session = session
        self.command = command
    }
}

/// A structurally validated binary frame plus the exact session snapshot under
/// which it was accepted.
public struct V2InboundBinaryFrame: Sendable, Equatable {
    public let session: V2NegotiatedSession
    public let frame: V2BinaryFrame
    public let wire: Data

    public init(session: V2NegotiatedSession, frame: V2BinaryFrame, wire: Data) {
        self.session = session
        self.frame = frame
        self.wire = wire
    }
}

/// Async sequence that drops queued values whose session stopped being current
/// before consumption.
public struct V2SessionValidatedStream<Element: Sendable>: AsyncSequence, Sendable {
    public typealias AsyncIterator = Iterator

    private let stream: AsyncStream<Element>
    private let validator: @Sendable (Element) async -> Bool

    public init(
        stream: AsyncStream<Element>,
        validator: @escaping @Sendable (Element) async -> Bool
    ) {
        self.stream = stream
        self.validator = validator
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(base: stream.makeAsyncIterator(), validator: validator)
    }

    public struct Iterator: AsyncIteratorProtocol {
        fileprivate var base: AsyncStream<Element>.Iterator
        fileprivate let validator: @Sendable (Element) async -> Bool

        public mutating func next() async -> Element? {
            while let element = await base.next() {
                if await validator(element) {
                    return element
                }
            }
            return nil
        }
    }
}
