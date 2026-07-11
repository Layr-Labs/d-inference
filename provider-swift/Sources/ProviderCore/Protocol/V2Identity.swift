import Foundation

public let protocolV1Major: UInt16 = 1
public let protocolV2Major: UInt16 = 2

/// A protocol identity represented as 16 raw UUID bytes.
///
/// JSON uses the same canonical lower-case UUID representation as the Rust
/// protocol crate. Decoding also accepts Rust's compact 32-hex-digit form.
public struct ProtocolV2UUID: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public static let nilID = ProtocolV2UUID(bytes: Data(repeating: 0, count: 16))!

    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count == 16 else { return nil }
        self.bytes = bytes
    }

    public init?(_ text: String) {
        let utf8 = Array(text.utf8)
        let canonical =
            utf8.count == 36
            && [8, 13, 18, 23].allSatisfy { utf8[$0] == UInt8(ascii: "-") }
            && utf8.enumerated().allSatisfy {
                [8, 13, 18, 23].contains($0.offset) || Self.hexNibble($0.element) != nil
            }
        let compact = utf8.count == 32 && utf8.allSatisfy { Self.hexNibble($0) != nil }
        guard canonical || compact else { return nil }

        let hex = utf8.filter { $0 != UInt8(ascii: "-") }
        guard hex.count == 32 else { return nil }
        var decoded = Data()
        decoded.reserveCapacity(16)
        for index in stride(from: 0, to: hex.count, by: 2) {
            guard let high = Self.hexNibble(hex[index]),
                let low = Self.hexNibble(hex[index + 1])
            else {
                return nil
            }
            decoded.append((high << 4) | low)
        }
        self.bytes = decoded
    }

    public static func random() -> ProtocolV2UUID {
        ProtocolV2UUID(UUID().uuidString)!
    }

    public var description: String {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-"
            + "\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
    }

    public static func < (lhs: ProtocolV2UUID, rhs: ProtocolV2UUID) -> Bool {
        lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let value = ProtocolV2UUID(text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "invalid protocol UUID text \(text.debugDescription)"
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"):
            byte - UInt8(ascii: "A") + 10
        default:
            nil
        }
    }
}

public typealias ProviderID = ProtocolV2UUID
public typealias ProviderProcessGenerationID = ProtocolV2UUID
public typealias ProcessGenerationID = ProviderProcessGenerationID
public typealias RequestID = ProtocolV2UUID
public typealias AttemptID = ProtocolV2UUID
public typealias ReservationID = ProtocolV2UUID
public typealias LeaseID = ProtocolV2UUID

/// The provider process identity is generated once and reused by every
/// CoordinatorClient created in this process, including reconnects.
public enum ProviderProcessIdentity {
    public static let generation = ProviderProcessGenerationID.random()
}

/// Capability flags advertised during registration.
public struct ProtocolCapabilities: Sendable, Equatable, Codable {
    public var protocolMajor: UInt16
    public var protocolMinor: UInt16
    public var minimumCompatibleMinor: UInt16
    public var preparedLeases: Bool
    public var startAuthorization: Bool
    public var structuredErrors: Bool
    public var startAck: Bool
    public var abortAck: Bool
    public var cancelAck: Bool
    public var durableTerminals: Bool
    public var modelLifecycleEvents: Bool
    public var binaryPayloadFrames: Bool
    public var coordinatorReplayFences: Bool

    public init(
        protocolMajor: UInt16,
        protocolMinor: UInt16,
        minimumCompatibleMinor: UInt16 = 0,
        preparedLeases: Bool = false,
        startAuthorization: Bool = false,
        structuredErrors: Bool = false,
        startAck: Bool = false,
        abortAck: Bool = false,
        cancelAck: Bool = false,
        durableTerminals: Bool = false,
        modelLifecycleEvents: Bool = false,
        binaryPayloadFrames: Bool = false,
        coordinatorReplayFences: Bool = false
    ) {
        self.protocolMajor = protocolMajor
        self.protocolMinor = protocolMinor
        self.minimumCompatibleMinor = minimumCompatibleMinor
        self.preparedLeases = preparedLeases
        self.startAuthorization = startAuthorization
        self.structuredErrors = structuredErrors
        self.startAck = startAck
        self.abortAck = abortAck
        self.cancelAck = cancelAck
        self.durableTerminals = durableTerminals
        self.modelLifecycleEvents = modelLifecycleEvents
        self.binaryPayloadFrames = binaryPayloadFrames
        self.coordinatorReplayFences = coordinatorReplayFences
    }

    /// The complete initial v2 contract implemented by this provider.
    public static let current = ProtocolCapabilities(
        protocolMajor: protocolV2Major,
        protocolMinor: 0,
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

    public var supportsV2: Bool {
        protocolMajor == protocolV2Major
            && minimumCompatibleMinor <= protocolMinor
            && preparedLeases
            && startAuthorization
            && structuredErrors
            && startAck
            && abortAck
            && cancelAck
            && durableTerminals
            && modelLifecycleEvents
            && binaryPayloadFrames
            && coordinatorReplayFences
    }

    /// Computes the common feature set over the overlap of both supported
    /// minor-version ranges. Provider semver is deliberately not consulted.
    public func negotiate(with peer: ProtocolCapabilities) -> ProtocolCapabilities? {
        let negotiatedMinimum = max(minimumCompatibleMinor, peer.minimumCompatibleMinor)
        let negotiatedMinor = min(protocolMinor, peer.protocolMinor)
        guard protocolMajor == peer.protocolMajor,
            minimumCompatibleMinor <= protocolMinor,
            peer.minimumCompatibleMinor <= peer.protocolMinor,
            negotiatedMinimum <= negotiatedMinor
        else {
            return nil
        }
        return ProtocolCapabilities(
            protocolMajor: protocolMajor,
            protocolMinor: negotiatedMinor,
            minimumCompatibleMinor: negotiatedMinimum,
            preparedLeases: preparedLeases && peer.preparedLeases,
            startAuthorization: startAuthorization && peer.startAuthorization,
            structuredErrors: structuredErrors && peer.structuredErrors,
            startAck: startAck && peer.startAck,
            abortAck: abortAck && peer.abortAck,
            cancelAck: cancelAck && peer.cancelAck,
            durableTerminals: durableTerminals && peer.durableTerminals,
            modelLifecycleEvents: modelLifecycleEvents && peer.modelLifecycleEvents,
            binaryPayloadFrames: binaryPayloadFrames && peer.binaryPayloadFrames,
            coordinatorReplayFences:
                coordinatorReplayFences && peer.coordinatorReplayFences
        )
    }

    enum CodingKeys: String, CodingKey {
        case protocolMajor = "protocol_major"
        case protocolMinor = "protocol_minor"
        case minimumCompatibleMinor = "minimum_compatible_minor"
        case preparedLeases = "prepared_leases"
        case startAuthorization = "start_authorization"
        case structuredErrors = "structured_errors"
        case startAck = "start_ack"
        case abortAck = "abort_ack"
        case cancelAck = "cancel_ack"
        case durableTerminals = "durable_terminals"
        case modelLifecycleEvents = "model_lifecycle_events"
        case binaryPayloadFrames = "binary_payload_frames"
        case coordinatorReplayFences = "coordinator_replay_fences"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try container.decode(UInt16.self, forKey: .protocolMajor)
        protocolMinor = try container.decode(UInt16.self, forKey: .protocolMinor)
        minimumCompatibleMinor =
            try container.decodeIfPresent(
                UInt16.self, forKey: .minimumCompatibleMinor) ?? 0
        preparedLeases = try container.decodeIfPresent(Bool.self, forKey: .preparedLeases) ?? false
        startAuthorization =
            try container.decodeIfPresent(
                Bool.self, forKey: .startAuthorization) ?? false
        structuredErrors = try container.decodeIfPresent(Bool.self, forKey: .structuredErrors) ?? false
        startAck = try container.decodeIfPresent(Bool.self, forKey: .startAck) ?? false
        abortAck = try container.decodeIfPresent(Bool.self, forKey: .abortAck) ?? false
        cancelAck = try container.decodeIfPresent(Bool.self, forKey: .cancelAck) ?? false
        durableTerminals =
            try container.decodeIfPresent(
                Bool.self, forKey: .durableTerminals) ?? false
        modelLifecycleEvents =
            try container.decodeIfPresent(
                Bool.self, forKey: .modelLifecycleEvents) ?? false
        binaryPayloadFrames =
            try container.decodeIfPresent(
                Bool.self, forKey: .binaryPayloadFrames) ?? false
        coordinatorReplayFences =
            try container.decodeIfPresent(
                Bool.self, forKey: .coordinatorReplayFences) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolMajor, forKey: .protocolMajor)
        try container.encode(protocolMinor, forKey: .protocolMinor)
        if minimumCompatibleMinor != 0 {
            try container.encode(minimumCompatibleMinor, forKey: .minimumCompatibleMinor)
        }
        try container.encodeIfTrue(preparedLeases, forKey: .preparedLeases)
        try container.encodeIfTrue(startAuthorization, forKey: .startAuthorization)
        try container.encodeIfTrue(structuredErrors, forKey: .structuredErrors)
        try container.encodeIfTrue(startAck, forKey: .startAck)
        try container.encodeIfTrue(abortAck, forKey: .abortAck)
        try container.encodeIfTrue(cancelAck, forKey: .cancelAck)
        try container.encodeIfTrue(durableTerminals, forKey: .durableTerminals)
        try container.encodeIfTrue(modelLifecycleEvents, forKey: .modelLifecycleEvents)
        try container.encodeIfTrue(binaryPayloadFrames, forKey: .binaryPayloadFrames)
        try container.encodeIfTrue(
            coordinatorReplayFences, forKey: .coordinatorReplayFences)
    }
}

public struct ProviderSessionIdentity: Sendable, Hashable, Codable {
    public var providerID: ProviderID
    public var processGeneration: ProviderProcessGenerationID
    public var sessionEpoch: UInt64

    public init(
        providerID: ProviderID,
        processGeneration: ProviderProcessGenerationID,
        sessionEpoch: UInt64
    ) {
        self.providerID = providerID
        self.processGeneration = processGeneration
        self.sessionEpoch = sessionEpoch
    }

    enum CodingKeys: String, CodingKey {
        case providerID = "provider_id"
        case processGeneration = "process_generation"
        case sessionEpoch = "session_epoch"
    }
}

public struct AttemptIdentity: Sendable, Equatable, Codable {
    public var providerID: ProviderID
    public var providerProcessGeneration: ProviderProcessGenerationID
    public var sessionEpoch: UInt64
    public var requestID: RequestID
    public var attemptID: AttemptID
    public var reservationID: ReservationID
    public var leaseID: LeaseID

    public init(
        providerID: ProviderID,
        providerProcessGeneration: ProviderProcessGenerationID,
        sessionEpoch: UInt64,
        requestID: RequestID,
        attemptID: AttemptID,
        reservationID: ReservationID,
        leaseID: LeaseID
    ) {
        self.providerID = providerID
        self.providerProcessGeneration = providerProcessGeneration
        self.sessionEpoch = sessionEpoch
        self.requestID = requestID
        self.attemptID = attemptID
        self.reservationID = reservationID
        self.leaseID = leaseID
    }

    public var providerSessionIdentity: ProviderSessionIdentity {
        ProviderSessionIdentity(
            providerID: providerID,
            processGeneration: providerProcessGeneration,
            sessionEpoch: sessionEpoch
        )
    }

    public func belongs(to session: ProviderSessionIdentity) -> Bool {
        providerSessionIdentity == session
    }

    enum CodingKeys: String, CodingKey {
        case providerID = "provider_id"
        case providerProcessGeneration = "provider_process_generation"
        case sessionEpoch = "session_epoch"
        case requestID = "request_id"
        case attemptID = "attempt_id"
        case reservationID = "reservation_id"
        case leaseID = "lease_id"
    }
}

extension KeyedEncodingContainer where Key == ProtocolCapabilities.CodingKeys {
    fileprivate mutating func encodeIfTrue(_ value: Bool, forKey key: Key) throws {
        if value {
            try encode(true, forKey: key)
        }
    }
}
