import Foundation
import DarkbloomClusterProtocol

/// Distinct inference-control records on the authenticated member TLS socket.
/// Native traffic keys never leave A; these are not public key/mesh records.
/// Deadlines are fixed slack from the original membership lifetime, not a new
/// duration at receipt and not another Mac's uptime clock.
struct NativePairWorkerPacket: Sendable {
    enum Kind: UInt8, Sendable { case ready = 1, command = 2, event = 3
        var messageType: String {
            switch self { case .ready: "native_pair_worker_ready"; case .command: "native_pair_worker_command"
            case .event: "native_pair_worker_event" }
        }
    }
    static let maximumPayload = 16 * 1024
    let kind: Kind
    let transcript: Data
    let deliverySlack, generationSlack: UInt64
    let payload: Data
    init(kind: Kind, transcript: Data, deliverySlack: UInt64 = 0, generationSlack: UInt64 = 0, payload: Data) throws {
        guard transcript.count == 32, !transcript.allSatisfy({ $0 == 0 }), !payload.isEmpty,
              payload.count <= Self.maximumPayload,
              deliverySlack <= ClusterWorkerLimits.deadlineNanoseconds,
              generationSlack <= ClusterWorkerLimits.deadlineNanoseconds,
              kind == .command || (deliverySlack == 0 && generationSlack == 0) else { throw NativePairMemberError.binding }
        self.kind = kind; self.transcript = transcript; self.deliverySlack = deliverySlack
        self.generationSlack = generationSlack; self.payload = payload
    }
    var bytes: Data {
        var b = Data([68,66,78,87,1,kind.rawValue]); b.append(transcript)
        func append<T: FixedWidthInteger & UnsignedInteger>(_ n: T) {
            for shift in stride(from: T.bitWidth-8, through: 0, by: -8) { b.append(UInt8(truncatingIfNeeded: n >> shift)) }
        }
        append(deliverySlack); append(generationSlack); append(UInt32(payload.count)); b.append(payload); return b
    }
    init(_ b: Data, type: String, transcript: Data) throws {
        guard b.count >= 59, b.count <= 58 + Self.maximumPayload,
              b.prefix(5) == Data([68,66,78,87,1]), let kind = Kind(rawValue: b[5]),
              kind.messageType == type, b.subdata(in: 6..<38) == transcript else { throw NativePairMemberError.binding }
        func number(_ range: Range<Int>) -> UInt64 { b.subdata(in: range).reduce(0) { ($0 << 8) | UInt64($1) } }
        guard number(54..<58) == UInt64(b.count-58) else { throw NativePairMemberError.binding }
        try self.init(kind: kind, transcript: transcript, deliverySlack: number(38..<46),
            generationSlack: number(46..<54), payload: b.subdata(in: 58..<b.count))
    }
    static func command(_ frame: ClusterWorkerCommandFrame, transcript: Data,
                        lifetime: UInt64, deliveryDeadline: UInt64) throws -> Self {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deliveryDeadline > now, deliveryDeadline <= lifetime else { throw NativePairMemberError.deadline }
        var command = frame.command, generationSlack: UInt64 = 0
        if case .reserve(let r) = command {
            try requireExperiment(r)
            guard r.deadlineUptimeNanoseconds > now, r.deadlineUptimeNanoseconds <= lifetime else { throw NativePairMemberError.deadline }
            generationSlack = lifetime - r.deadlineUptimeNanoseconds
            command = .reserve(copy(r, deadline: 1)) // explicit wire sentinel; never a remote uptime
        }
        return try .init(kind: .command, transcript: transcript, deliverySlack: lifetime-deliveryDeadline,
            generationSlack: generationSlack, payload: ClusterWorkerCodec.encode(.init(membershipEpoch: frame.membershipEpoch,
                sequence: frame.sequence, requestID: frame.requestID, command: command)))
    }
    func localCommand(lifetime: UInt64, now: UInt64) throws -> (ClusterWorkerCommandFrame, UInt64) {
        guard kind == .command, lifetime > deliverySlack, lifetime-deliverySlack > now else { throw NativePairMemberError.deadline }
        let f = try ClusterWorkerCodec.decodeCommand(payload)
        var command = f.command
        if case .reserve(let r) = command {
            try Self.requireExperiment(r)
            guard r.deadlineUptimeNanoseconds == 1, lifetime > generationSlack, lifetime-generationSlack > now else { throw NativePairMemberError.deadline }
            command = .reserve(Self.copy(r, deadline: lifetime-generationSlack))
        } else if generationSlack != 0 { throw NativePairMemberError.binding }
        return (.init(membershipEpoch: f.membershipEpoch, sequence: f.sequence, requestID: f.requestID, command: command), lifetime-deliverySlack)
    }
    static func requireExperiment(_ r: ClusterWorkerReservation) throws {
        guard r.profileID == "registered_qwen35_9b_greedy_generation_v1", r.promptTokenIDs.count == 32,
              r.outputCount == 2, r.chunkSize == 16, r.stopTokenIDs.isEmpty else { throw NativePairMemberError.binding }
    }
    private static func copy(_ r: ClusterWorkerReservation, deadline: UInt64) -> ClusterWorkerReservation {
        .init(profileID: r.profileID, promptTokenIDs: r.promptTokenIDs, stopTokenIDs: r.stopTokenIDs,
            outputCount: r.outputCount, chunkSize: r.chunkSize, deadlineUptimeNanoseconds: deadline, capacityLimitBytes: r.capacityLimitBytes)
    }
}
