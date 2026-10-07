import Foundation
import CoreFoundation

/// Exactly one UTF-8 JSON object and LF. Unknown fields, duplicate keys, floating
/// metadata, Boolean-as-integer and null optional IDs are rejected.
public enum ClusterWorkerCodec {
    public static func encode(_ frame: ClusterWorkerCommandFrame) throws -> Data {
        try ClusterWorkerValidation.command(frame)
        var value = envelope(frame.membershipEpoch, frame.sequence, frame.requestID)
        switch frame.command {
        case .reserve(let r):
            value["kind"] = "reserve"; value["reservation"] = reservation(r)
        case .start: value["kind"] = "start"
        case .tokenDecision(let ordinal, let decision):
            value["kind"] = "tokenDecision"; value["ordinal"] = ordinal; value["decision"] = decision.rawValue
        case .cancel(let reason): value["kind"] = "cancel"; value["reason"] = reason.rawValue
        case .shutdown: value["kind"] = "shutdown"
        }
        return try encoded(value, maximum: ClusterWorkerLimits.commandBytes)
    }

    public static func encode(_ frame: ClusterWorkerEventFrame) throws -> Data {
        try ClusterWorkerValidation.event(frame)
        var value = envelope(frame.membershipEpoch, frame.sequence, frame.requestID)
        switch frame.event {
        case .ready(let r): value["kind"] = "ready"; value["ready"] = ready(r)
        case .admitted(let bytes): value["kind"] = "admitted"; value["reservedBytes"] = bytes
        case .refused(let reason): value["kind"] = "refused"; value["reason"] = reason.rawValue
        case .committedToken(let ordinal, let token, let committed):
            value["kind"] = "committedToken"; value["ordinal"] = ordinal
            value["tokenID"] = token; value["committedTokens"] = committed
        case .finished(let reason): value["kind"] = "finished"; value["reason"] = reason.rawValue
        case .failed(let reason): value["kind"] = "failed"; value["reason"] = reason.rawValue
        case .retired(let outcome): value["kind"] = "retired"; value["outcome"] = outcome.rawValue
        case .unavailable(let reason): value["kind"] = "unavailable"; value["reason"] = reason.rawValue
        case .shutdownComplete: value["kind"] = "shutdownComplete"
        }
        return try encoded(value, maximum: ClusterWorkerLimits.eventBytes)
    }

    public static func decodeCommand(_ data: Data) throws -> ClusterWorkerCommandFrame {
        var r = try reader(data, maximum: ClusterWorkerLimits.commandBytes)
        let (epoch, sequence, requestID) = try header(&r)
        let command: ClusterWorkerCommand
        switch try r.string("kind") {
        case "reserve": command = .reserve(try reservation(r.object("reservation")))
        case "start": command = .start
        case "tokenDecision": command = .tokenDecision(ordinal: try r.int("ordinal"), decision: try r.enumeration("decision"))
        case "cancel": command = .cancel(try r.enumeration("reason"))
        case "shutdown": command = .shutdown
        default: throw ClusterWorkerProtocolError.invalid("Unknown worker command")
        }
        try r.finish()
        let frame = ClusterWorkerCommandFrame(membershipEpoch: epoch, sequence: sequence, requestID: requestID, command: command)
        try ClusterWorkerValidation.command(frame); return frame
    }

    public static func decodeEvent(_ data: Data) throws -> ClusterWorkerEventFrame {
        var r = try reader(data, maximum: ClusterWorkerLimits.eventBytes)
        let (epoch, sequence, requestID) = try header(&r)
        let event: ClusterWorkerEvent
        switch try r.string("kind") {
        case "ready": event = .ready(try ready(r.object("ready")))
        case "admitted": event = .admitted(reservedBytes: try r.int("reservedBytes"))
        case "refused": event = .refused(try r.enumeration("reason"))
        case "committedToken": event = .committedToken(ordinal: try r.int("ordinal"), tokenID: try r.int("tokenID"), committedTokens: try r.int("committedTokens"))
        case "finished": event = .finished(try r.enumeration("reason"))
        case "failed": event = .failed(try r.enumeration("reason"))
        case "retired": event = .retired(try r.enumeration("outcome"))
        case "unavailable": event = .unavailable(try r.enumeration("reason"))
        case "shutdownComplete": event = .shutdownComplete
        default: throw ClusterWorkerProtocolError.invalid("Unknown worker event")
        }
        try r.finish()
        let frame = ClusterWorkerEventFrame(membershipEpoch: epoch, sequence: sequence, requestID: requestID, event: event)
        try ClusterWorkerValidation.event(frame); return frame
    }

    private static func envelope(_ epoch: UUID, _ sequence: UInt64, _ request: UUID?) -> [String: Any] {
        var result: [String: Any] = ["version": ClusterWorkerLimits.version,
            "membershipEpoch": epoch.uuidString.lowercased(), "sequence": NSNumber(value: sequence)]
        if let request { result["requestID"] = request.uuidString.lowercased() }
        return result
    }
    private static func encoded(_ value: [String: Any], maximum: Int) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        try workerRequire(data.count < maximum, "Worker record exceeds byte limit")
        data.append(10); return data
    }
    private static func reader(_ data: Data, maximum: Int) throws -> WorkerObject {
        try workerRequire(!data.isEmpty && data.count <= maximum && data.last == 10
            && !data.dropLast().contains(10), "Expected one bounded JSONL record")
        try validateClusterWorkerJSON(data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClusterWorkerProtocolError.invalid("Worker record must be an object")
        }
        return WorkerObject(object)
    }
    private static func header(_ r: inout WorkerObject) throws -> (UUID, UInt64, UUID?) {
        try workerRequire(try r.int("version") == ClusterWorkerLimits.version, "Unsupported worker protocol version")
        return try (r.uuid("membershipEpoch"), r.uint("sequence"), r.optionalUUID("requestID"))
    }
    private static func reservation(_ r: ClusterWorkerReservation) -> [String: Any] {
        ["profileID": r.profileID, "promptTokenIDs": r.promptTokenIDs, "stopTokenIDs": r.stopTokenIDs,
         "outputCount": r.outputCount, "chunkSize": r.chunkSize,
         "deadlineUptimeNanoseconds": NSNumber(value: r.deadlineUptimeNanoseconds), "capacityLimitBytes": r.capacityLimitBytes]
    }
    private static func reservation(_ object: [String: Any]) throws -> ClusterWorkerReservation {
        var r = WorkerObject(object)
        let value = try ClusterWorkerReservation(profileID: r.string("profileID"), promptTokenIDs: r.ints("promptTokenIDs"),
            stopTokenIDs: r.ints("stopTokenIDs"), outputCount: r.int("outputCount"), chunkSize: r.int("chunkSize"),
            deadlineUptimeNanoseconds: r.uint("deadlineUptimeNanoseconds"), capacityLimitBytes: r.int("capacityLimitBytes"))
        try r.finish(); return value
    }
    private static func ready(_ r: ClusterWorkerReady) -> [String: Any] {
        ["identity": ["membershipEpoch": r.identity.membershipEpoch.uuidString.lowercased(), "modelID": r.identity.modelID,
            "artifactSHA256": r.identity.artifactSHA256, "configurationSHA256": r.identity.configurationSHA256,
            "peers": r.identity.peers.map { ["id": $0.id, "buildSHA256": $0.buildSHA256] }],
         "rank": r.rank, "profile": ["id": r.profile.id, "vocabularySize": r.profile.vocabularySize,
            "maximumPromptTokens": r.profile.maximumPromptTokens, "maximumOutputTokens": r.profile.maximumOutputTokens,
            "maximumChunkTokens": r.profile.maximumChunkTokens, "maximumContextTokens": r.profile.maximumContextTokens],
         "executionPlanSHA256": r.executionPlanSHA256, "requestCapacityBytes": r.requestCapacityBytes]
    }
    private static func ready(_ object: [String: Any]) throws -> ClusterWorkerReady {
        var r = WorkerObject(object), id = WorkerObject(try r.object("identity")), p = WorkerObject(try r.object("profile"))
        let peers = try id.objects("peers").map { object -> ClusterWorkerPeer in
            var peer = WorkerObject(object)
            let result = try ClusterWorkerPeer(id: peer.string("id"), buildSHA256: peer.string("buildSHA256"))
            try peer.finish(); return result
        }
        let identity = try ClusterWorkerIdentity(membershipEpoch: id.uuid("membershipEpoch"), modelID: id.string("modelID"),
            artifactSHA256: id.string("artifactSHA256"), configurationSHA256: id.string("configurationSHA256"), peers: peers)
        let profile = try ClusterWorkerProfile(id: p.string("id"), vocabularySize: p.int("vocabularySize"),
            maximumPromptTokens: p.int("maximumPromptTokens"), maximumOutputTokens: p.int("maximumOutputTokens"),
            maximumChunkTokens: p.int("maximumChunkTokens"), maximumContextTokens: p.int("maximumContextTokens"))
        let value = try ClusterWorkerReady(identity: identity, rank: r.int("rank"), profile: profile,
            executionPlanSHA256: r.string("executionPlanSHA256"), requestCapacityBytes: r.int("requestCapacityBytes"))
        try id.finish(); try p.finish(); try r.finish(); return value
    }
}

