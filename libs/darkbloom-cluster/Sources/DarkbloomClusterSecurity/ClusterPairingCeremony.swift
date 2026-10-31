import CryptoKit
import Foundation

/// What a person is shown about the other Mac beside the code. Read from its
/// attestation, which its Secure Enclave key signed; display only.
public struct ClusterPairingPeerPosture: Codable, Sendable, Equatable {
    public var chipName: String
    public var hardwareModel: String
    public var osVersion: String
    public var sipEnabled: Bool
    public var secureBootEnabled: Bool
    public var authenticatedRootEnabled: Bool

    public init(chipName: String, hardwareModel: String, osVersion: String, sipEnabled: Bool, secureBootEnabled: Bool,
                authenticatedRootEnabled: Bool) {
        self.chipName = chipName; self.hardwareModel = hardwareModel; self.osVersion = osVersion
        self.sipEnabled = sipEnabled; self.secureBootEnabled = secureBootEnabled
        self.authenticatedRootEnabled = authenticatedRootEnabled
    }
}

/// The other Mac as the ceremony knows it once its proof verified.
public struct ClusterPairingPeer: Sendable, Equatable {
    public let pin: String
    public let identityKey: Data
    public let name: String
    public let interface: String
    public let posture: ClusterPairingPeerPosture
}

/// One end's inputs. Closures, so the provider supplies its attestation and
/// its stored roster generations without this module knowing either format.
public struct ClusterPairingParticipant: Sendable {
    public var identity: any ClusterPairingIdentity
    /// Display name sent to the other Mac, such as "Mac Studio, Apple M3 Ultra". Never a host name.
    public var name: String
    /// The link interface this end uses, such as en7 or bridge0.
    public var interface: String
    /// This end's attestation for one ceremony's ephemeral X25519 key (opaque bytes).
    public var attestation: @Sendable (_ ephemeralKey: Data) throws -> Data
    /// The highest roster generation this end stored for a pairing with `peerPin` (0 when none).
    public var knownGeneration: @Sendable (_ peerPin: String) -> UInt64
    /// Listener only: the cluster label it proposes.
    public var clusterLabel: @Sendable (_ localPin: String, _ peerPin: String) -> String

    public init(identity: any ClusterPairingIdentity, name: String, interface: String,
                attestation: @escaping @Sendable (Data) throws -> Data,
                knownGeneration: @escaping @Sendable (String) -> UInt64 = { _ in 0 },
                clusterLabel: @escaping @Sendable (String, String) -> String = { ClusterPairingLabel.derived(pins: [$0, $1]) }) {
        self.identity = identity; self.name = name; self.interface = interface; self.attestation = attestation
        self.knownGeneration = knownGeneration; self.clusterLabel = clusterLabel
    }
}

/// The checks this module cannot make alone.
public struct ClusterPairingHooks: Sendable {
    /// The peer's attestation must be signed by `identityKey` and bind
    /// `ephemeralKey`; returns what to show, nil when it does not verify.
    public var verifyAttestation: @Sendable (_ attestation: Data, _ identityKey: Data, _ ephemeralKey: Data) -> ClusterPairingPeerPosture?
    /// The roster's canonical bytes (darkbloom-platform `ClusterRoster.Canonical`),
    /// members in ascending pin order.
    public var rosterCanonical: @Sendable (_ clusterID: String, _ generation: UInt64,
                                           _ members: [(pin: String, identityKey: Data)]) throws -> Data

    public init(verifyAttestation: @escaping @Sendable (Data, Data, Data) -> ClusterPairingPeerPosture?,
                rosterCanonical: @escaping @Sendable (String, UInt64, [(pin: String, identityKey: Data)]) throws -> Data) {
        self.verifyAttestation = verifyAttestation; self.rosterCanonical = rosterCanonical
    }
}

/// One roster member as the coordinator's registration carries it.
public struct ClusterPairingRosterMember: Codable, Sendable, Equatable {
    public let pin: String
    /// Standard base64 of the 65-byte uncompressed point.
    public let sePublicKey: String
    /// Standard base64 of the DER signature over SHA-256 of the roster's canonical bytes.
    public let signature: String

    enum CodingKeys: String, CodingKey {
        case pin
        case sePublicKey = "se_public_key"
        case signature
    }
}

/// A finished ceremony, before it is stored. The link edge secret stays inside
/// this module: the store writes it to an owner-only file and nothing prints it.
public struct ClusterPairingOutcome: Sendable, CustomStringConvertible {
    public let role: ClusterPairingRole
    public let localPin: String
    public let localIdentityKey: Data
    public let localInterface: String
    public let peer: ClusterPairingPeer
    public let clusterID: String
    public let generation: UInt64
    /// In ascending pin order, both signatures verified.
    public let rosterMembers: [ClusterPairingRosterMember]
    public let rosterCanonical: Data
    public let transcriptSHA256: Data
    public let code: String
    public let linkEpoch: UUID
    let edgeSecret: Data

    public var description: String {
        "ClusterPairingOutcome(cluster \(clusterID), generation \(generation), peer \(peer.pin.prefix(16)), secret redacted)"
    }

    /// SHA-256 of the roster's canonical bytes: what both members register.
    public var rosterSHA256: String { Data(SHA256.hash(data: rosterCanonical)).map { String(format: "%02x", $0) }.joined() }
}

/// What the driver of a session does next.
public enum ClusterPairingStep: Sendable {
    case send(ClusterPairingMessage)
    /// Show the code and ask the person; answer with `decide(accept:)`.
    case showCode(code: String, peer: ClusterPairingPeer)
    /// The other Mac's person answered (the session already acted on it).
    case peerDecided(accepted: Bool)
    /// Store the pin, the roster and the edge secret; answer with `localPersisted(_:)`.
    case persist(ClusterPairingOutcome)
    /// Undo what `persist` stored: the other Mac did not finish.
    case rollback(ClusterPairingOutcome)
    case completed(ClusterPairingOutcome)
    case failed(ClusterPairingError)
}

/// One end of one ceremony, as a state machine with no thread, clock or
/// socket: the driver feeds it messages, the person's answer and the store's
/// result, and carries out the steps it returns. A failure is final.
public struct ClusterPairingSession: Sendable {
    enum Phase: Sendable, Equatable {
        case start, offered, answered, proving, deciding, countersigning, persisting, committing, done, failed
    }

    public let role: ClusterPairingRole
    private let participant: ClusterPairingParticipant
    private let hooks: ClusterPairingHooks
    private let localKey: Data
    private let localPin: String
    private var phase: Phase = .start
    private let ephemeral = Curve25519.KeyAgreement.PrivateKey()
    private var nonce = Data()
    private var attestation = Data()
    private var generation: UInt64 = 0

    // The other end's values, as received.
    private var peerKey = Data()
    private var peerEphemeral = Data()
    private var peerName = ""
    private var peerInterface = ""
    private var peerNonce = Data()
    private var peerAttestation = Data()
    private var peerGeneration: UInt64 = 0
    private var commitment = Data()
    private var clusterID = ""
    private var posture: ClusterPairingPeerPosture?

    private var transcript = Data()
    private var confirmKey: SymmetricKey?
    private var edgeSecret = Data()
    private var code = ""
    private var peerProved = false
    private var localDecision: Bool?
    private var peerDecision: Bool?
    private var rosterBytes = Data()
    private var localSignature = Data()
    private var outcome: ClusterPairingOutcome?
    private var persisted = false
    private var peerCommitted = false

    public init(role: ClusterPairingRole, participant: ClusterPairingParticipant, hooks: ClusterPairingHooks) throws {
        let key = participant.identity.identityPublicKey
        guard ClusterPairingPin.isIdentityKey(key),
              ClusterPairingMessage.printable(participant.name, limit: ClusterPairingPolicy.maximumNameBytes),
              ClusterPairingMessage.printable(participant.interface, limit: ClusterPairingPolicy.maximumInterfaceBytes) else {
            throw ClusterPairingError.identityUnavailable
        }
        self.role = role; self.participant = participant; self.hooks = hooks
        localKey = key; localPin = ClusterPairingPin.of(identityKey: key)
        nonce = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    /// Whether the code has been shown (a listener refuses a second offer from then on).
    public var codeShown: Bool { [.deciding, .countersigning, .persisting, .committing, .done].contains(phase) }
    public var isFinished: Bool { phase == .done || phase == .failed }
    /// Whether this end stored the pairing and has not rolled it back.
    public var hasPersisted: Bool { persisted && phase != .failed }

    /// Connector: the offer that opens the ceremony.
    public mutating func start() -> [ClusterPairingStep] {
        guard role == .connector, phase == .start else { return fail(.unexpectedMessage) }
        do { attestation = try participant.attestation(ephemeral.publicKey.rawRepresentation) } catch { return fail(.identityUnavailable) }
        var offer = ClusterPairingMessage(kind: .offer)
        offer.version = ClusterPairingPolicy.protocolVersion; offer.name = participant.name; offer.interface = participant.interface
        offer.identityKey = localKey; offer.ephemeralKey = ephemeral.publicKey.rawRepresentation
        commitment = ClusterPairingDerivation.commitment(identityKey: localKey, ephemeralKey: ephemeral.publicKey.rawRepresentation, nonce: nonce)
        offer.commitment = commitment
        phase = .offered
        return [.send(offer)]
    }

    /// One message from the other end, already decoded and shape-checked.
    public mutating func receive(_ message: ClusterPairingMessage) -> [ClusterPairingStep] {
        guard !isFinished else { return [] }
        do {
            switch (message.kind, role, phase) {
            case (.abort, _, _):
                // Once the code is on screen, only an abort made with the agreed key counts: anyone on
                // the link can send an untagged one, and it must not undo a confirmed or stored pairing.
                // Before that, an untagged abort costs no more than a lost link.
                if codeShown, let key = confirmKey {
                    guard let tag = message.tag, ClusterPairingDerivation.isValidTag(tag, kind: .abort, role: role.peer,
                        transcript: transcript, payload: Data((message.reason ?? "").utf8), key: key) else { return [] }
                }
                return peerAborted(message.reason ?? "protocol")
            case (.refused, .connector, .offered): return refused(message)
            case (.offer, .listener, .start): return try offered(message)
            case (.answer, .connector, .offered): return try answered(message)
            case (.reveal, .listener, .answered): return try revealed(message)
            case (.proof, _, .proving): return try proved(message)
            case (.decision, _, .deciding): return try decided(message)
            case (.countersign, _, .countersigning): return try countersigned(message)
            case (.committed, _, .persisting), (.committed, _, .committing): return try committed(message)
            default: return fail(.unexpectedMessage)
            }
        } catch let error as ClusterPairingError {
            return fail(error)
        } catch {
            return fail(.malformedMessage)
        }
    }

    /// The person's answer to the code on this Mac.
    public mutating func decide(accept: Bool) -> [ClusterPairingStep] {
        guard phase == .deciding, localDecision == nil, let key = confirmKey else { return [] }
        localDecision = accept
        var decision = ClusterPairingMessage(kind: .decision)
        decision.accept = accept
        decision.tag = ClusterPairingDerivation.tag(kind: .decision, role: role, transcript: transcript,
            payload: Data([accept ? 1 : 0]), key: key)
        var steps: [ClusterPairingStep] = [.send(decision)]
        guard accept else {
            phase = .failed
            steps.append(.failed(.declinedLocally))
            return steps
        }
        if peerDecision == true { steps += bothAccepted() }
        return steps
    }

    /// The store's answer to `persist`.
    public mutating func localPersisted(_ success: Bool) -> [ClusterPairingStep] {
        guard phase == .persisting, let key = confirmKey, let outcome else { return [] }
        guard success else {
            phase = .failed
            return [.send(abortMessage(ClusterPairingError.persistenceFailed.wireReason)), .failed(.persistenceFailed)]
        }
        persisted = true
        phase = .committing
        var message = ClusterPairingMessage(kind: .committed)
        message.tag = ClusterPairingDerivation.tag(kind: .committed, role: role, transcript: transcript, payload: Data(), key: key)
        var steps: [ClusterPairingStep] = [.send(message)]
        if peerCommitted {
            phase = .done
            steps.append(.completed(outcome))
        }
        return steps
    }

    /// The driver ends the ceremony: the code expired, the link was lost, or the person quit.
    public mutating func fail(_ error: ClusterPairingError) -> [ClusterPairingStep] {
        guard !isFinished else { return [] }
        var steps = [ClusterPairingStep]()
        if phase != .start { steps.append(.send(abortMessage(error.wireReason))) }
        if persisted, let outcome { steps.append(.rollback(outcome)) }
        phase = .failed
        steps.append(.failed(error))
        return steps
    }

    // MARK: - Messages

    private mutating func offered(_ m: ClusterPairingMessage) throws -> [ClusterPairingStep] {
        guard m.version == ClusterPairingPolicy.protocolVersion else { throw ClusterPairingError.unsupportedVersion }
        guard let key = m.identityKey, let eph = m.ephemeralKey, let commit = m.commitment, let name = m.name,
              let interface = m.interface else { throw ClusterPairingError.malformedMessage }
        guard key != localKey else { throw ClusterPairingError.selfPairing }
        peerKey = key; peerEphemeral = eph; commitment = commit; peerName = name; peerInterface = interface
        let peerPin = ClusterPairingPin.of(identityKey: key)
        do { attestation = try participant.attestation(ephemeral.publicKey.rawRepresentation) } catch { throw ClusterPairingError.identityUnavailable }
        generation = participant.knownGeneration(peerPin)
        clusterID = participant.clusterLabel(localPin, peerPin)
        guard ClusterPairingLabel.isValid(clusterID) else { throw ClusterPairingError.rosterInvalid }
        var answer = ClusterPairingMessage(kind: .answer)
        answer.version = ClusterPairingPolicy.protocolVersion; answer.name = participant.name; answer.interface = participant.interface
        answer.identityKey = localKey; answer.ephemeralKey = ephemeral.publicKey.rawRepresentation; answer.nonce = nonce
        answer.attestation = attestation; answer.clusterID = clusterID; answer.knownGeneration = generation
        phase = .answered
        return [.send(answer)]
    }

    private mutating func answered(_ m: ClusterPairingMessage) throws -> [ClusterPairingStep] {
        guard m.version == ClusterPairingPolicy.protocolVersion else { throw ClusterPairingError.unsupportedVersion }
        guard let key = m.identityKey, let eph = m.ephemeralKey, let peerNonce = m.nonce, let peerAttestation = m.attestation,
              let label = m.clusterID, let peerGeneration = m.knownGeneration, let name = m.name,
              let interface = m.interface else { throw ClusterPairingError.malformedMessage }
        guard key != localKey else { throw ClusterPairingError.selfPairing }
        peerKey = key; peerEphemeral = eph; self.peerNonce = peerNonce; self.peerAttestation = peerAttestation
        clusterID = label; self.peerGeneration = peerGeneration; peerName = name; peerInterface = interface
        generation = participant.knownGeneration(ClusterPairingPin.of(identityKey: key))
        guard let verified = hooks.verifyAttestation(peerAttestation, key, eph) else { throw ClusterPairingError.attestationInvalid }
        posture = verified
        try agree()
        var reveal = ClusterPairingMessage(kind: .reveal)
        reveal.nonce = nonce; reveal.attestation = attestation; reveal.knownGeneration = generation
        phase = .proving
        return [.send(reveal), .send(try proof())]
    }

    private mutating func revealed(_ m: ClusterPairingMessage) throws -> [ClusterPairingStep] {
        guard let peerNonce = m.nonce, let peerAttestation = m.attestation, let peerGeneration = m.knownGeneration else {
            throw ClusterPairingError.malformedMessage
        }
        let expected = ClusterPairingDerivation.commitment(identityKey: peerKey, ephemeralKey: peerEphemeral, nonce: peerNonce)
        guard Self.constantTimeEqual(expected, commitment) else { throw ClusterPairingError.commitmentMismatch }
        self.peerNonce = peerNonce; self.peerAttestation = peerAttestation; self.peerGeneration = peerGeneration
        guard let verified = hooks.verifyAttestation(peerAttestation, peerKey, peerEphemeral) else { throw ClusterPairingError.attestationInvalid }
        posture = verified
        try agree()
        phase = .proving
        return [.send(try proof())]
    }

    private mutating func proved(_ m: ClusterPairingMessage) throws -> [ClusterPairingStep] {
        guard let signature = m.signature, !peerProved else { throw ClusterPairingError.malformedMessage }
        let message = ClusterPairingDerivation.proofMessage(role: role.peer, transcript: transcript)
        guard Self.verify(signature: signature, message: message, key: peerKey) else { throw ClusterPairingError.proofInvalid }
        peerProved = true
        phase = .deciding
        guard let posture else { throw ClusterPairingError.attestationInvalid }
        let peer = ClusterPairingPeer(pin: ClusterPairingPin.of(identityKey: peerKey), identityKey: peerKey, name: peerName,
            interface: peerInterface, posture: posture)
        return [.showCode(code: code, peer: peer)]
    }

    private mutating func decided(_ m: ClusterPairingMessage) throws -> [ClusterPairingStep] {
        guard let accept = m.accept, let tag = m.tag, peerDecision == nil, let key = confirmKey else { throw ClusterPairingError.malformedMessage }
        guard ClusterPairingDerivation.isValidTag(tag, kind: .decision, role: role.peer, transcript: transcript,
                                                  payload: Data([accept ? 1 : 0]), key: key) else { throw ClusterPairingError.tagInvalid }
        peerDecision = accept
        var steps: [ClusterPairingStep] = [.peerDecided(accepted: accept)]
        guard accept else {
            phase = .failed
            steps.append(.failed(.declinedByPeer))
            return steps
        }
        if localDecision == true { steps += bothAccepted() }
        return steps
    }

    private mutating func bothAccepted() -> [ClusterPairingStep] {
        guard let key = confirmKey else { return fail(.malformedMessage) }
        let final = max(generation, peerGeneration) + 1
        let members = [(pin: localPin, identityKey: localKey), (pin: ClusterPairingPin.of(identityKey: peerKey), identityKey: peerKey)]
            .sorted { $0.pin < $1.pin }
        do {
            rosterBytes = try hooks.rosterCanonical(clusterID, final, members)
            localSignature = try participant.identity.pairingSignature(for: rosterBytes)
        } catch { return fail(.rosterInvalid) }
        guard Self.verify(signature: localSignature, message: rosterBytes, key: localKey) else { return fail(.identityUnavailable) }
        generation = final
        var message = ClusterPairingMessage(kind: .countersign)
        message.signature = localSignature
        message.tag = ClusterPairingDerivation.tag(kind: .countersign, role: role, transcript: transcript, payload: localSignature, key: key)
        phase = .countersigning
        return [.send(message)]
    }

    private mutating func countersigned(_ m: ClusterPairingMessage) throws -> [ClusterPairingStep] {
        guard let signature = m.signature, let tag = m.tag, let key = confirmKey, let posture else { throw ClusterPairingError.malformedMessage }
        guard ClusterPairingDerivation.isValidTag(tag, kind: .countersign, role: role.peer, transcript: transcript,
                                                  payload: signature, key: key) else { throw ClusterPairingError.tagInvalid }
        guard Self.verify(signature: signature, message: rosterBytes, key: peerKey) else { throw ClusterPairingError.rosterInvalid }
        let peerPin = ClusterPairingPin.of(identityKey: peerKey)
        let members = [
            ClusterPairingRosterMember(pin: localPin, sePublicKey: localKey.base64EncodedString(), signature: localSignature.base64EncodedString()),
            ClusterPairingRosterMember(pin: peerPin, sePublicKey: peerKey.base64EncodedString(), signature: signature.base64EncodedString()),
        ].sorted { $0.pin < $1.pin }
        let finished = ClusterPairingOutcome(role: role, localPin: localPin, localIdentityKey: localKey,
            localInterface: participant.interface,
            peer: ClusterPairingPeer(pin: peerPin, identityKey: peerKey, name: peerName, interface: peerInterface, posture: posture),
            clusterID: clusterID, generation: generation, rosterMembers: members, rosterCanonical: rosterBytes,
            transcriptSHA256: transcript, code: code, linkEpoch: ClusterPairingDerivation.linkEpoch(transcript: transcript),
            edgeSecret: edgeSecret)
        outcome = finished
        phase = .persisting
        return [.persist(finished)]
    }

    private mutating func committed(_ m: ClusterPairingMessage) throws -> [ClusterPairingStep] {
        guard let tag = m.tag, let key = confirmKey, !peerCommitted else { throw ClusterPairingError.malformedMessage }
        guard ClusterPairingDerivation.isValidTag(tag, kind: .committed, role: role.peer, transcript: transcript,
                                                  payload: Data(), key: key) else { throw ClusterPairingError.tagInvalid }
        peerCommitted = true
        guard persisted, let outcome else { return [] }
        phase = .done
        return [.completed(outcome)]
    }

    private mutating func peerAborted(_ reason: String) -> [ClusterPairingStep] {
        let error: ClusterPairingError
        switch reason {
        case "declined": error = .declinedByPeer
        case "expired": error = .expired
        case "locked_out": error = .peerLockedOut(untilEpochSeconds: 0)
        case "unsupported_version": error = .unsupportedVersion
        default: error = .peerAborted
        }
        var steps = [ClusterPairingStep]()
        if persisted, let outcome { steps.append(.rollback(outcome)) }
        phase = .failed
        steps.append(.failed(error))
        return steps
    }

    private mutating func refused(_ m: ClusterPairingMessage) -> [ClusterPairingStep] {
        phase = .failed
        switch m.reason {
        case "locked_out": return [.failed(.peerLockedOut(untilEpochSeconds: m.retryAfterEpochSeconds ?? 0))]
        case "rate_limited": return [.failed(.rateLimited)]
        case "busy": return [.failed(.busy)]
        case "unsupported_version": return [.failed(.unsupportedVersion)]
        default: return [.failed(.peerAborted)]
        }
    }

    // MARK: - Derivations

    /// The transcript, the code and the keys, once both ends' values are known.
    private mutating func agree() throws {
        let connector = role == .connector
        let inputs = ClusterPairingDerivation.TranscriptInputs(
            connectorIdentity: connector ? localKey : peerKey,
            connectorEphemeral: connector ? ephemeral.publicKey.rawRepresentation : peerEphemeral,
            commitment: commitment,
            connectorName: connector ? participant.name : peerName,
            connectorInterface: connector ? participant.interface : peerInterface,
            listenerIdentity: connector ? peerKey : localKey,
            listenerEphemeral: connector ? peerEphemeral : ephemeral.publicKey.rawRepresentation,
            listenerNonce: connector ? peerNonce : nonce,
            listenerName: connector ? peerName : participant.name,
            listenerInterface: connector ? peerInterface : participant.interface,
            listenerAttestation: connector ? peerAttestation : attestation,
            clusterID: clusterID,
            listenerGeneration: connector ? peerGeneration : generation,
            connectorNonce: connector ? nonce : peerNonce,
            connectorAttestation: connector ? attestation : peerAttestation,
            connectorGeneration: connector ? generation : peerGeneration)
        transcript = ClusterPairingDerivation.transcript(inputs)
        let keys = try ClusterPairingDerivation.keys(privateKey: ephemeral, peerEphemeral: peerEphemeral, transcript: transcript)
        confirmKey = keys.confirm; edgeSecret = keys.edgeSecret
        code = ClusterPairingDerivation.code(transcript: transcript)
    }

    /// An abort, tagged once the keys are agreed.
    private func abortMessage(_ reason: String) -> ClusterPairingMessage {
        var abort = ClusterPairingMessage(kind: .abort)
        abort.reason = reason
        if let key = confirmKey {
            abort.tag = ClusterPairingDerivation.tag(kind: .abort, role: role, transcript: transcript, payload: Data(reason.utf8), key: key)
        }
        return abort
    }

    private func proof() throws -> ClusterPairingMessage {
        var message = ClusterPairingMessage(kind: .proof)
        do {
            message.signature = try participant.identity.pairingSignature(for: ClusterPairingDerivation.proofMessage(role: role, transcript: transcript))
        } catch { throw ClusterPairingError.identityUnavailable }
        return message
    }

    static func verify(signature: Data, message: Data, key: Data) -> Bool {
        guard let publicKey = try? P256.Signing.PublicKey(x963Representation: key),
              let parsed = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
        return publicKey.isValidSignature(parsed, for: message)
    }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
