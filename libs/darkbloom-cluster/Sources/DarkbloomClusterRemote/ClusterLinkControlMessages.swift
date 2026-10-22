import Foundation

/// Typed control messages carried, encrypted, on one link edge. Every message
/// is delivered exactly once and in order while both processes live (it is
/// retransmitted across reconnects); a peer restart is reported instead.
///
/// Nothing control-like goes over RDMA (the owner's oMLX lesson: tiny RDMA
/// reductions gave corrupt headers and lost completions). Codable JSON inside
/// the authenticated record, decoded only after the record authenticates.
public enum ClusterLinkControlMessage: Sendable, Equatable {
    /// Rank or member lease renewal (S03: renew 5 s, TTL 30 s by default).
    case leaseRenew(ClusterLinkLeaseRenewal)
    /// Request reservation with the prompt (rank 0 to the other ranks).
    case reserve(ClusterLinkRequestReserve)
    case start(ClusterLinkRequestStart)
    /// A rank's report about a request: admitted, finished, retired, failed.
    case requestEvent(ClusterLinkRequestEvent)
    /// A small decision owned by one rank (the owner's `OC2B` relay).
    case decision(ClusterLinkDecision)
    /// Cancel or stop vote at a step boundary, with an epoch latch.
    case vote(ClusterLinkVote)
    /// Barrier arrival or release (the owner's `OC2R`; never a collective).
    case barrier(ClusterLinkBarrier)
    /// Both ends publish a digest of one decision and compare.
    case agreement(ClusterLinkAgreement)
    /// The other member's status, mirrored to the head.
    case status(ClusterLinkStatusMirror)
    /// Diagnostic echo answered by the probe responder.
    case probe(ClusterLinkProbeMessage)

    public var kind: String {
        switch self {
        case .leaseRenew: "leaseRenew"
        case .reserve: "reserve"
        case .start: "start"
        case .requestEvent: "requestEvent"
        case .decision: "decision"
        case .vote: "vote"
        case .barrier: "barrier"
        case .agreement: "agreement"
        case .status: "status"
        case .probe: "probe"
        }
    }

    /// The epoch a message names, when it names one; the channel refuses a
    /// message whose epoch is not the edge's.
    var epoch: UUID? {
        switch self {
        case .leaseRenew(let value): value.epoch
        case .reserve(let value): value.epoch
        case .start(let value): value.epoch
        case .requestEvent(let value): value.epoch
        case .decision(let value): value.epoch
        case .vote(let value): value.epoch
        case .barrier(let value): value.epoch
        case .agreement(let value): value.epoch
        case .status(let value): value.epoch
        case .probe: nil
        }
    }

    /// Structural bounds, checked after decoding and before delivery.
    func validate(maximumPromptTokens: Int) throws {
        func short(_ text: String, _ limit: Int = 128) throws {
            guard text.utf8.count <= limit, !text.utf8.contains(0) else { throw ClusterLinkControlError.invalidMessage }
        }
        switch self {
        case .leaseRenew(let value):
            guard value.ttlMilliseconds > 0, value.ttlMilliseconds <= 600_000 else { throw ClusterLinkControlError.invalidMessage }
        case .reserve(let value):
            guard value.promptTokens.count % 4 == 0, value.promptTokens.count / 4 <= maximumPromptTokens,
                  value.maximumOutputTokens > 0, value.maximumOutputTokens <= 1_048_576 else {
                throw ClusterLinkControlError.invalidMessage
            }
            try short(value.modelID, 256); try short(value.planSHA256, 64)
        case .start(let value):
            try short(value.mode, 64)
        case .requestEvent(let value):
            try short(value.detail, 256)
        case .decision(let value):
            guard value.bytes.count <= ClusterLinkDecision.maximumBytes else { throw ClusterLinkControlError.invalidMessage }
        case .vote(let value):
            try short(value.reason, 128)
        case .barrier(let value):
            try short(value.name, 128)
        case .agreement(let value):
            try short(value.topic, 128)
            guard value.digestSHA256.count == 32 else { throw ClusterLinkControlError.invalidMessage }
        case .status(let value):
            try short(value.detail, 256)
            if let model = value.modelID { try short(model, 256) }
            if let thermal = value.thermalState { try short(thermal, 16) }
            if let epoch = value.incidentEpoch { try short(epoch, 64) }
            if let incidents = value.incidents {
                guard incidents.count <= ClusterLinkStatusMirror.maximumIncidents else { throw ClusterLinkControlError.invalidMessage }
                for incident in incidents {
                    try short(incident.severity, 16); try short(incident.stateCode, 64)
                    if let code = incident.reasonCode { try short(code, 64) }
                    if let code = incident.guidanceCode { try short(code, 64) }
                    try short(incident.message, ClusterLinkIncidentSummary.maximumMessageBytes)
                }
            }
        case .probe(let value):
            guard value.padding.count <= 65_536 else { throw ClusterLinkControlError.invalidMessage }
        }
    }
}

public struct ClusterLinkLeaseRenewal: Codable, Sendable, Equatable {
    public var epoch: UUID
    public var leaseID: UUID
    public var renewal: UInt64
    public var ttlMilliseconds: UInt32
    public init(epoch: UUID, leaseID: UUID, renewal: UInt64, ttlMilliseconds: UInt32) {
        self.epoch = epoch; self.leaseID = leaseID; self.renewal = renewal; self.ttlMilliseconds = ttlMilliseconds
    }
}

public struct ClusterLinkRequestReserve: Codable, Sendable, Equatable {
    public var epoch: UUID
    public var requestID: UUID
    public var modelID: String
    public var planSHA256: String
    /// Prompt token IDs, little-endian Int32, packed (base64 in JSON).
    public var promptTokens: Data
    public var maximumOutputTokens: UInt32
    public var deadlineMilliseconds: UInt32
    public init(epoch: UUID, requestID: UUID, modelID: String, planSHA256: String, promptTokens: [Int32],
                maximumOutputTokens: UInt32, deadlineMilliseconds: UInt32) {
        self.epoch = epoch; self.requestID = requestID; self.modelID = modelID; self.planSHA256 = planSHA256
        var packed = Data(capacity: promptTokens.count * 4)
        for token in promptTokens { withUnsafeBytes(of: token.littleEndian) { packed.append(contentsOf: $0) } }
        self.promptTokens = packed
        self.maximumOutputTokens = maximumOutputTokens; self.deadlineMilliseconds = deadlineMilliseconds
    }
    public var promptTokenIDs: [Int32] {
        stride(from: 0, to: promptTokens.count - promptTokens.count % 4, by: 4).map { offset in
            let start = promptTokens.startIndex + offset
            let bytes = promptTokens[start..<start + 4]
            return bytes.reversed().reduce(Int32(0)) { $0 << 8 | Int32($1) }
        }
    }
}

public struct ClusterLinkRequestStart: Codable, Sendable, Equatable {
    public var epoch: UUID
    public var requestID: UUID
    /// Generation mode name (pipeline, phase split, ...), as the plan names it.
    public var mode: String
    public var maximumOutputTokens: UInt32
    public var seed: UInt64?
    public init(epoch: UUID, requestID: UUID, mode: String, maximumOutputTokens: UInt32, seed: UInt64? = nil) {
        self.epoch = epoch; self.requestID = requestID; self.mode = mode
        self.maximumOutputTokens = maximumOutputTokens; self.seed = seed
    }
}

public struct ClusterLinkRequestEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case admitted, finished, retired, failed }
    public var epoch: UUID
    public var requestID: UUID
    public var rank: UInt16
    public var kind: Kind
    public var detail: String
    public init(epoch: UUID, requestID: UUID, rank: UInt16, kind: Kind, detail: String = "") {
        self.epoch = epoch; self.requestID = requestID; self.rank = rank; self.kind = kind; self.detail = detail
    }
}

public struct ClusterLinkDecision: Codable, Sendable, Equatable {
    public static let maximumBytes = 256
    public var epoch: UUID
    public var requestID: UUID
    public var step: UInt64
    public var ownerRank: UInt16
    public var bytes: Data
    public init(epoch: UUID, requestID: UUID, step: UInt64, ownerRank: UInt16, bytes: Data) {
        self.epoch = epoch; self.requestID = requestID; self.step = step; self.ownerRank = ownerRank; self.bytes = bytes
    }
}

public struct ClusterLinkVote: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case cancel, stop }
    public var epoch: UUID
    public var requestID: UUID
    public var kind: Kind
    /// Per-cancel latch so a consumed vote cannot end the next request.
    public var latch: UInt64
    /// The step boundary at which the voter stops.
    public var step: UInt64
    public var reason: String
    public init(epoch: UUID, requestID: UUID, kind: Kind, latch: UInt64, step: UInt64, reason: String = "") {
        self.epoch = epoch; self.requestID = requestID; self.kind = kind; self.latch = latch; self.step = step; self.reason = reason
    }
}

public struct ClusterLinkBarrier: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable { case arrive, release }
    public var epoch: UUID
    public var name: String
    public var generation: UInt64
    public var rank: UInt16
    public var phase: Phase
    public init(epoch: UUID, name: String, generation: UInt64, rank: UInt16, phase: Phase) {
        self.epoch = epoch; self.name = name; self.generation = generation; self.rank = rank; self.phase = phase
    }
}

public struct ClusterLinkAgreement: Codable, Sendable, Equatable {
    public var epoch: UUID
    public var topic: String
    public var generation: UInt64
    public var rank: UInt16
    public var digestSHA256: Data
    public init(epoch: UUID, topic: String, generation: UInt64, rank: UInt16, digestSHA256: Data) {
        self.epoch = epoch; self.topic = topic; self.generation = generation; self.rank = rank; self.digestSHA256 = digestSHA256
    }
}

public struct ClusterLinkStatusMirror: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case idle, loading, ready, serving, draining, failed }
    public static let maximumIncidents = 4
    public var epoch: UUID
    public var rank: UInt16
    public var state: State
    public var modelID: String?
    public var activeRequestID: UUID?
    public var freeMemoryBytes: UInt64?
    public var wiredMemoryBytes: UInt64?
    public var linkReady: Bool
    public var detail: String
    // S24 additions, all optional: an older peer neither sends nor needs them.
    /// Strictly increasing per sender process; a receiver keeps the newest.
    public var sequence: UInt64?
    /// The sender's wall clock when it built the status, seconds since 1970.
    public var sentAt: Double?
    /// Seconds since the sending process started.
    public var uptimeSeconds: UInt64?
    /// `nominal`, `fair`, `serious` or `critical` (ProcessInfo.thermalState).
    public var thermalState: String?
    public var physicalMemoryBytes: UInt64?
    /// Requests this member's rank finished since it last became ready.
    public var requestsServed: UInt64?
    /// The sender's incident log epoch and its newest records (at most four).
    public var incidentEpoch: String?
    public var incidents: [ClusterLinkIncidentSummary]?

    public init(epoch: UUID, rank: UInt16, state: State, modelID: String? = nil, activeRequestID: UUID? = nil,
                freeMemoryBytes: UInt64? = nil, wiredMemoryBytes: UInt64? = nil, linkReady: Bool, detail: String = "",
                sequence: UInt64? = nil, sentAt: Double? = nil, uptimeSeconds: UInt64? = nil, thermalState: String? = nil,
                physicalMemoryBytes: UInt64? = nil, requestsServed: UInt64? = nil, incidentEpoch: String? = nil,
                incidents: [ClusterLinkIncidentSummary]? = nil) {
        self.epoch = epoch; self.rank = rank; self.state = state; self.modelID = modelID
        self.activeRequestID = activeRequestID; self.freeMemoryBytes = freeMemoryBytes
        self.wiredMemoryBytes = wiredMemoryBytes; self.linkReady = linkReady; self.detail = detail
        self.sequence = sequence; self.sentAt = sentAt; self.uptimeSeconds = uptimeSeconds
        self.thermalState = thermalState; self.physicalMemoryBytes = physicalMemoryBytes
        self.requestsServed = requestsServed; self.incidentEpoch = incidentEpoch; self.incidents = incidents
    }
}

/// One incident as a member mirrors it to the other: codes and a short,
/// already redacted message.
public struct ClusterLinkIncidentSummary: Codable, Sendable, Equatable {
    public static let maximumMessageBytes = 200
    public var seq: UInt64
    public var ts: Double
    public var severity: String
    public var stateCode: String
    public var reasonCode: String?
    public var guidanceCode: String?
    public var message: String
    public init(seq: UInt64, ts: Double, severity: String, stateCode: String, reasonCode: String?,
                guidanceCode: String?, message: String) {
        self.seq = seq; self.ts = ts; self.severity = severity; self.stateCode = stateCode
        self.reasonCode = reasonCode; self.guidanceCode = guidanceCode; self.message = message
    }
}

public struct ClusterLinkProbeMessage: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case echoRequest, echoReply
        /// Ask the responder to send `count` opaque frames of `bytes` back.
        case bulkRequest
        case bulkDone
    }
    public var kind: Kind
    public var nonce: UInt64
    public var count: UInt32
    public var bytes: UInt32
    public var padding: Data
    public init(kind: Kind, nonce: UInt64, count: UInt32 = 0, bytes: UInt32 = 0, padding: Data = Data()) {
        self.kind = kind; self.nonce = nonce; self.count = count; self.bytes = bytes; self.padding = padding
    }
}

extension ClusterLinkControlMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, leaseRenew, reserve, start, requestEvent, decision, vote, barrier, agreement, status, probe
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        // Exactly the kind key and its one payload key.
        guard container.allKeys.count == 2 else { throw ClusterLinkControlError.invalidMessage }
        switch kind {
        case "leaseRenew": self = .leaseRenew(try container.decode(ClusterLinkLeaseRenewal.self, forKey: .leaseRenew))
        case "reserve": self = .reserve(try container.decode(ClusterLinkRequestReserve.self, forKey: .reserve))
        case "start": self = .start(try container.decode(ClusterLinkRequestStart.self, forKey: .start))
        case "requestEvent": self = .requestEvent(try container.decode(ClusterLinkRequestEvent.self, forKey: .requestEvent))
        case "decision": self = .decision(try container.decode(ClusterLinkDecision.self, forKey: .decision))
        case "vote": self = .vote(try container.decode(ClusterLinkVote.self, forKey: .vote))
        case "barrier": self = .barrier(try container.decode(ClusterLinkBarrier.self, forKey: .barrier))
        case "agreement": self = .agreement(try container.decode(ClusterLinkAgreement.self, forKey: .agreement))
        case "status": self = .status(try container.decode(ClusterLinkStatusMirror.self, forKey: .status))
        case "probe": self = .probe(try container.decode(ClusterLinkProbeMessage.self, forKey: .probe))
        default: throw ClusterLinkControlError.invalidMessage
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .leaseRenew(let value): try container.encode(value, forKey: .leaseRenew)
        case .reserve(let value): try container.encode(value, forKey: .reserve)
        case .start(let value): try container.encode(value, forKey: .start)
        case .requestEvent(let value): try container.encode(value, forKey: .requestEvent)
        case .decision(let value): try container.encode(value, forKey: .decision)
        case .vote(let value): try container.encode(value, forKey: .vote)
        case .barrier(let value): try container.encode(value, forKey: .barrier)
        case .agreement(let value): try container.encode(value, forKey: .agreement)
        case .status(let value): try container.encode(value, forKey: .status)
        case .probe(let value): try container.encode(value, forKey: .probe)
        }
    }
}

/// Pure barrier state for one named barrier generation among known ranks:
/// release once every expected rank has arrived (rank 0 decides, then sends
/// `release` to the others).
public struct ClusterLinkBarrierTracker: Sendable, Equatable {
    public let name: String
    public let generation: UInt64
    public let expectedRanks: Set<UInt16>
    public private(set) var arrived: Set<UInt16> = []

    public init(name: String, generation: UInt64, expectedRanks: Set<UInt16>) {
        self.name = name; self.generation = generation; self.expectedRanks = expectedRanks
    }

    /// Records an arrival; true once all expected ranks have arrived. A rank
    /// outside the expected set, or another barrier's message, is refused.
    public mutating func arrive(_ message: ClusterLinkBarrier) throws -> Bool {
        guard message.name == name, message.generation == generation, message.phase == .arrive,
              expectedRanks.contains(message.rank) else { throw ClusterLinkControlError.invalidMessage }
        arrived.insert(message.rank)
        return arrived == expectedRanks
    }
}

/// Pure agreement check: every expected rank publishes one digest; the result
/// is agreed, still waiting, or the first rank whose digest differs.
public struct ClusterLinkAgreementTracker: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable { case waiting, agreed, mismatch(rank: UInt16) }
    public let topic: String
    public let generation: UInt64
    public let expectedRanks: Set<UInt16>
    public private(set) var digests: [UInt16: Data] = [:]

    public init(topic: String, generation: UInt64, expectedRanks: Set<UInt16>) {
        self.topic = topic; self.generation = generation; self.expectedRanks = expectedRanks
    }

    public mutating func record(_ message: ClusterLinkAgreement) throws -> Outcome {
        guard message.topic == topic, message.generation == generation, expectedRanks.contains(message.rank),
              message.digestSHA256.count == 32 else { throw ClusterLinkControlError.invalidMessage }
        if let previous = digests[message.rank], previous != message.digestSHA256 { return .mismatch(rank: message.rank) }
        digests[message.rank] = message.digestSHA256
        let ordered = digests.sorted { $0.key < $1.key }
        if let reference = ordered.first?.value, let differing = ordered.first(where: { $0.value != reference }) {
            return .mismatch(rank: differing.key)
        }
        return Set(digests.keys) == expectedRanks ? .agreed : .waiting
    }
}
