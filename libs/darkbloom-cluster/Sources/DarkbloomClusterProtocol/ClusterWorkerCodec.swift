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
            value["kind"] = "reserve"; value["reservation"] = try reservation(r)
        case .start: value["kind"] = "start"
        case .tokenDecision(let ordinal, let decision):
            value["kind"] = "tokenDecision"; value["ordinal"] = ordinal; value["decision"] = decision.rawValue
        case .cancel(let reason): value["kind"] = "cancel"; value["reason"] = reason.rawValue
        case .shutdown: value["kind"] = "shutdown"
        case .keepWarm(let ordinal): value["kind"] = "keepWarm"; value["ordinal"] = ordinal
        }
        return try encoded(value, maximum: ClusterWorkerLimits.commandBytes)
    }

    /// A rank-lease renewal line: outside the request sequence, so it carries
    /// no sequence and no request ID.
    public static func encode(_ renewal: ClusterWorkerLeaseRenewal) throws -> Data {
        try encoded(["version": ClusterWorkerLimits.version, "kind": "extendDeadline",
            "membershipEpoch": renewal.membershipEpoch.uuidString.lowercased(),
            "renewal": NSNumber(value: renewal.renewal), "ttlNanoseconds": NSNumber(value: renewal.ttlNanoseconds)],
            maximum: ClusterWorkerLimits.commandBytes)
    }

    /// The data-plane credential line (S16): the first line of a worker's
    /// control pipe, outside the request sequence. Base64 fields.
    public static func encode(_ trust: ClusterWorkerDataPlaneTrust) throws -> Data {
        try encoded(["version": ClusterWorkerLimits.version, "kind": "dataPlaneTrust",
            "membershipEpoch": trust.membershipEpoch.uuidString.lowercased(), "rank": trust.rank,
            "workerSigningKey": trust.workerSigningKey.base64EncodedString(),
            "workerCertificate": trust.workerCertificate.base64EncodedString(),
            "memberIdentity": trust.memberIdentity.base64EncodedString(),
            "peerPin": trust.peerPin.base64EncodedString()], maximum: 4096)
    }

    public static func decodeDataPlaneTrust(_ data: Data) throws -> ClusterWorkerDataPlaneTrust {
        var r = try reader(data, maximum: 4096)
        try workerRequire(try r.int("version") == ClusterWorkerLimits.version, "Unsupported worker protocol version")
        try workerRequire(try r.string("kind") == "dataPlaneTrust", "Expected the data-plane credential line")
        func bytes(_ key: String) throws -> Data {
            guard let value = Data(base64Encoded: try r.string(key)) else {
                throw ClusterWorkerProtocolError.invalid("Expected base64: " + key)
            }
            return value
        }
        let value = try ClusterWorkerDataPlaneTrust(membershipEpoch: r.uuid("membershipEpoch"), rank: r.int("rank"),
            workerSigningKey: bytes("workerSigningKey"), workerCertificate: bytes("workerCertificate"),
            memberIdentity: bytes("memberIdentity"), peerPin: bytes("peerPin"))
        try r.finish()
        return value
    }

    /// The prefix-SSD key line: after the data-plane credential (first when
    /// there is none), outside the request sequence. Base64 key.
    public static func encode(_ value: ClusterWorkerPrefixSSDKey) throws -> Data {
        try encoded(["version": ClusterWorkerLimits.version, "kind": "prefixSSDKey",
            "membershipEpoch": value.membershipEpoch.uuidString.lowercased(), "rank": value.rank,
            "key": value.key.base64EncodedString()], maximum: 4096)
    }

    public static func decodePrefixSSDKey(_ data: Data) throws -> ClusterWorkerPrefixSSDKey {
        var r = try reader(data, maximum: 4096)
        try workerRequire(try r.int("version") == ClusterWorkerLimits.version, "Unsupported worker protocol version")
        try workerRequire(try r.string("kind") == "prefixSSDKey", "Expected the prefix-SSD key line")
        guard let key = Data(base64Encoded: try r.string("key")) else {
            throw ClusterWorkerProtocolError.invalid("Expected base64: key")
        }
        let value = try ClusterWorkerPrefixSSDKey(membershipEpoch: r.uuid("membershipEpoch"), rank: r.int("rank"), key: key)
        try r.finish()
        return value
    }

    /// One control-pipe line: a lease renewal or a sequenced command.
    public static func decodeControl(_ data: Data) throws -> ClusterWorkerControlLine {
        var r = try reader(data, maximum: ClusterWorkerLimits.commandBytes)
        guard r.peekString("kind") == "extendDeadline" else { return .command(try decodeCommand(data)) }
        try workerRequire(try r.int("version") == ClusterWorkerLimits.version, "Unsupported worker protocol version")
        _ = try r.string("kind")
        let renewal = try ClusterWorkerLeaseRenewal(membershipEpoch: r.uuid("membershipEpoch"), renewal: r.uint("renewal"),
            ttlNanoseconds: r.uint("ttlNanoseconds"))
        try r.finish()
        return .extendDeadline(renewal)
    }

    public static func encode(_ frame: ClusterWorkerEventFrame) throws -> Data {
        try ClusterWorkerValidation.event(frame)
        var value = envelope(frame.membershipEpoch, frame.sequence, frame.requestID)
        switch frame.event {
        case .ready(let r): value["kind"] = "ready"; value["ready"] = ready(r)
        case .admitted(let bytes): value["kind"] = "admitted"; value["reservedBytes"] = bytes
        case .refused(let reason): value["kind"] = "refused"; value["reason"] = reason.rawValue
        case .committedToken(let ordinal, let token, let committed, let logprobs):
            value["kind"] = "committedToken"; value["ordinal"] = ordinal
            value["tokenID"] = token; value["committedTokens"] = committed
            if let logprobs { value["logprobs"] = Self.logprobs(logprobs) }
        case .promptCache(let reused, let stored):
            value["kind"] = "promptCache"; value["reusedTokens"] = reused; value["storedFrontiers"] = stored
        case .requestTelemetry(let t):
            value["kind"] = "requestTelemetry"; value["telemetry"] = telemetry(t)
        case .finished(let reason): value["kind"] = "finished"; value["reason"] = reason.rawValue
        case .failed(let reason): value["kind"] = "failed"; value["reason"] = reason.rawValue
        case .retired(let outcome): value["kind"] = "retired"; value["outcome"] = outcome.rawValue
        case .unavailable(let reason): value["kind"] = "unavailable"; value["reason"] = reason.rawValue
        case .shutdownComplete: value["kind"] = "shutdownComplete"
        case .keptWarm(let ordinal, let microseconds, let serving):
            value["kind"] = "keptWarm"; value["ordinal"] = ordinal; value["microseconds"] = microseconds
            if let serving { value["servingContextTokens"] = serving }
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
        case "keepWarm": command = .keepWarm(ordinal: try r.int("ordinal"))
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
        case "committedToken": event = .committedToken(ordinal: try r.int("ordinal"), tokenID: try r.int("tokenID"),
            committedTokens: try r.int("committedTokens"), logprobs: try r.optionalObject("logprobs").map(Self.logprobs))
        case "promptCache": event = .promptCache(reusedTokens: try r.int("reusedTokens"), storedFrontiers: try r.ints("storedFrontiers"))
        case "requestTelemetry": event = .requestTelemetry(try telemetry(r.object("telemetry")))
        case "finished": event = .finished(try r.enumeration("reason"))
        case "failed": event = .failed(try r.enumeration("reason"))
        case "retired": event = .retired(try r.enumeration("outcome"))
        case "unavailable": event = .unavailable(try r.enumeration("reason"))
        case "shutdownComplete": event = .shutdownComplete
        case "keptWarm": event = .keptWarm(ordinal: try r.int("ordinal"), microseconds: try r.int("microseconds"),
            servingContextTokens: try r.optionalInt("servingContextTokens"))
        default: throw ClusterWorkerProtocolError.invalid("Unknown worker event")
        }
        try r.finish()
        let frame = ClusterWorkerEventFrame(membershipEpoch: epoch, sequence: sequence, requestID: requestID, event: event)
        try ClusterWorkerValidation.event(frame); return frame
    }

    /// JSONSerialization autoreleases its writer, buffers and parsed objects. Frames are encoded and decoded per token on
    /// threads and dispatch queues that never drain a pool (rank 0 grew about 40 MB a minute under load, F18): each call
    /// drains its own. The result is retained by the Swift value it is bridged to.
    private static func drained<T>(_ body: () throws -> T) rethrows -> T { try ClusterAutorelease.drained(body) }
    private static func envelope(_ epoch: UUID, _ sequence: UInt64, _ request: UUID?) -> [String: Any] {
        var result: [String: Any] = ["version": ClusterWorkerLimits.version,
            "membershipEpoch": epoch.uuidString.lowercased(), "sequence": NSNumber(value: sequence)]
        if let request { result["requestID"] = request.uuidString.lowercased() }
        return result
    }
    private static func encoded(_ value: [String: Any], maximum: Int) throws -> Data {
        var data = try drained { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) }
        try workerRequire(data.count < maximum, "Worker record exceeds byte limit")
        data.append(10); return data
    }
    private static func reader(_ data: Data, maximum: Int) throws -> WorkerObject {
        try workerRequire(!data.isEmpty && data.count <= maximum && data.last == 10
            && !data.dropLast().contains(10), "Expected one bounded JSONL record")
        try validateClusterWorkerJSON(data)
        guard let object = try drained({ try JSONSerialization.jsonObject(with: data) as? [String: Any] }) else {
            throw ClusterWorkerProtocolError.invalid("Worker record must be an object")
        }
        return WorkerObject(object)
    }
    private static func header(_ r: inout WorkerObject) throws -> (UUID, UInt64, UUID?) {
        try workerRequire(try r.int("version") == ClusterWorkerLimits.version, "Unsupported worker protocol version")
        return try (r.uuid("membershipEpoch"), r.uint("sequence"), r.optionalUUID("requestID"))
    }
    private static func logprobs(_ l: ClusterWorkerTokenLogprobs) -> [String: Any] {
        ["logprobBits": Int(l.logprob.bitPattern), "topTokenIDs": l.top.map(\.tokenID),
         "topLogprobBits": l.top.map { Int($0.logprob.bitPattern) }]
    }
    private static func logprobs(_ object: [String: Any]) throws -> ClusterWorkerTokenLogprobs {
        var r = WorkerObject(object)
        let bits = try r.int("logprobBits"), tokens = try r.ints("topTokenIDs"), top = try r.ints("topLogprobBits")
        try workerRequire(tokens.count == top.count
            && ([bits] + top).allSatisfy({ (0...Int(UInt32.max)).contains($0) }), "Invalid token logprobs")
        try r.finish()
        return .init(logprob: Float(bitPattern: UInt32(bits)), top: zip(tokens, top).map {
            .init(tokenID: $0.0, logprob: Float(bitPattern: UInt32($0.1)))
        })
    }
    private static func telemetry(_ t: ClusterWorkerRequestTelemetry) -> [String: Any] {
        var result: [String: Any] = [:]
        if let value = t.handoffNanoseconds { result["handoffNanoseconds"] = NSNumber(value: value) }
        if let value = t.handoffBytes { result["handoffBytes"] = value }
        if let value = t.mtpDrafted { result["mtpDrafted"] = value }
        if let value = t.mtpAccepted { result["mtpAccepted"] = value }
        if let value = t.prefillNanoseconds { result["prefillNanoseconds"] = NSNumber(value: value) }
        return result
    }
    private static func telemetry(_ object: [String: Any]) throws -> ClusterWorkerRequestTelemetry {
        var r = WorkerObject(object)
        func optional<T>(_ key: String, _ read: (inout WorkerObject) throws -> T) throws -> T? {
            r.values[key] == nil ? nil : try read(&r)
        }
        let value = ClusterWorkerRequestTelemetry(
            handoffNanoseconds: try optional("handoffNanoseconds") { try $0.uint("handoffNanoseconds") },
            handoffBytes: try optional("handoffBytes") { try $0.int("handoffBytes") },
            mtpDrafted: try optional("mtpDrafted") { try $0.int("mtpDrafted") },
            mtpAccepted: try optional("mtpAccepted") { try $0.int("mtpAccepted") },
            prefillNanoseconds: try optional("prefillNanoseconds") { try $0.uint("prefillNanoseconds") })
        try r.finish()
        return value
    }
    private static func reservation(_ r: ClusterWorkerReservation) throws -> [String: Any] {
        var value: [String: Any] = ["profileID": r.profileID, "promptTokenIDs": r.promptTokenIDs, "stopTokenIDs": r.stopTokenIDs,
         "outputCount": r.outputCount, "chunkSize": r.chunkSize,
         "deadlineUptimeNanoseconds": NSNumber(value: r.deadlineUptimeNanoseconds), "capacityLimitBytes": r.capacityLimitBytes]
        // Greedy text has no field at all, so its bytes are unchanged.
        if let sampling = r.sampling { value["sampling"] = ClusterWorkerSamplingCodec.encode(sampling) }
        // The pair as placed has no field at all either.
        if let route = r.route { value["route"] = route.rawValue }
        if let media = r.stillImages {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let bytes = try encoder.encode(media)
            try workerRequire(bytes.count <= ClusterStillImages.maximumEnvelopeBytes, "Still-image envelope exceeds bound")
            value["stillImages"] = bytes.base64EncodedString()
        }
        if let media = r.mimoImages {
            let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
            let bytes = try encoder.encode(media)
            try workerRequire(bytes.count <= 135_000,"MiMo envelope exceeds bound")
            value["mimoImages"] = bytes.base64EncodedString()
        }
        return value
    }
    private static func reservation(_ object: [String: Any]) throws -> ClusterWorkerReservation {
        var r = WorkerObject(object)
        let sampling = r.values["sampling"] == nil ? nil : try ClusterWorkerSamplingCodec.decode(r.object("sampling"))
        var route: ClusterWorkerRoute?
        if r.values["route"] != nil {
            guard let value = ClusterWorkerRoute(rawValue: try r.string("route")) else { throw ClusterWorkerProtocolError.invalid("Unknown request route") }
            route = value
        }
        let stillImages: ClusterStillImages?
        if r.values["stillImages"] != nil {
            let encoded = try r.string("stillImages")
            guard encoded.utf8.count <= 180_000, let bytes = Data(base64Encoded: encoded),
                  bytes.count <= ClusterStillImages.maximumEnvelopeBytes else {
                throw ClusterWorkerProtocolError.invalid("Still-image envelope exceeds bound")
            }
            stillImages = try ClusterStillImages.decodeBounded(bytes)
        } else { stillImages = nil }
        let media: ClusterMiMoImages?
        if r.values["mimoImages"] != nil {
            let encoded = try r.string("mimoImages")
            guard encoded.utf8.count <= 180_000,
                  let bytes = Data(base64Encoded: encoded), bytes.count <= 135_000 else {
                throw ClusterWorkerProtocolError.invalid("MiMo envelope exceeds bound")
            }
            media = try ClusterMiMoImages.decodeBounded(bytes)
        } else { media = nil }
        let value = try ClusterWorkerReservation(profileID: r.string("profileID"), promptTokenIDs: r.ints("promptTokenIDs"),
            stopTokenIDs: r.ints("stopTokenIDs"), outputCount: r.int("outputCount"), chunkSize: r.int("chunkSize"),
            deadlineUptimeNanoseconds: r.uint("deadlineUptimeNanoseconds"), capacityLimitBytes: r.int("capacityLimitBytes"),
            sampling: sampling, route: route, mimoImages: media, stillImages: stillImages)
        try r.finish(); return value
    }
    private static func ready(_ r: ClusterWorkerReady) -> [String: Any] {
        var value = readyFields(r)
        if let d = r.dataPlane {
            value["dataPlane"] = ["protection": d.protection, "peerVerified": d.peerVerified,
                                  "transcriptSHA256": d.transcriptSHA256, "edgeID": d.edgeID]
        }
        return value
    }
    private static func readyFields(_ r: ClusterWorkerReady) -> [String: Any] {
        ["identity": ["membershipEpoch": r.identity.membershipEpoch.uuidString.lowercased(), "modelID": r.identity.modelID,
            "artifactSHA256": r.identity.artifactSHA256, "configurationSHA256": r.identity.configurationSHA256,
            "peers": r.identity.peers.map { ["id": $0.id, "buildSHA256": $0.buildSHA256] }],
         "rank": r.rank, "profile": ["id": r.profile.id, "vocabularySize": r.profile.vocabularySize,
            "maximumPromptTokens": r.profile.maximumPromptTokens, "maximumOutputTokens": r.profile.maximumOutputTokens,
            "maximumChunkTokens": r.profile.maximumChunkTokens, "maximumContextTokens": r.profile.maximumContextTokens],
         "executionPlanSHA256": r.executionPlanSHA256, "requestCapacityBytes": r.requestCapacityBytes]
            .merging(r.servingContextTokens.map { ["servingContextTokens": $0] } ?? [:]) { first, _ in first }
            .merging(r.linkProbe.map { ["linkProbe": linkProbe($0)] } ?? [:]) { first, _ in first }
    }
    private static func linkProbe(_ p: ClusterWorkerLinkProbe) -> [String: Any] {
        ["transport": p.transport, "keyed": p.keyed,
         "pointToPointSmallBytes": p.pointToPointSmallBytes, "pointToPointSmallMicroseconds": p.pointToPointSmallMicroseconds,
         "pointToPointLargeBytes": p.pointToPointLargeBytes, "pointToPointLargeMicroseconds": p.pointToPointLargeMicroseconds,
         "allSumSmallBytes": p.allSumSmallBytes, "allSumSmallMicroseconds": p.allSumSmallMicroseconds,
         "allSumLargeBytes": p.allSumLargeBytes, "allSumLargeMicroseconds": p.allSumLargeMicroseconds]
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
        var dataPlane: ClusterWorkerDataPlane?
        if r.values["dataPlane"] != nil {
            var d = WorkerObject(try r.object("dataPlane"))
            dataPlane = try ClusterWorkerDataPlane(protection: d.string("protection"), peerVerified: d.bool("peerVerified"),
                transcriptSHA256: d.string("transcriptSHA256"), edgeID: d.string("edgeID"))
            try d.finish()
        }
        var probe: ClusterWorkerLinkProbe?
        if r.values["linkProbe"] != nil {
            var l = WorkerObject(try r.object("linkProbe"))
            probe = try ClusterWorkerLinkProbe(transport: l.string("transport"), keyed: l.bool("keyed"),
                pointToPointSmallBytes: l.int("pointToPointSmallBytes"), pointToPointSmallMicroseconds: l.int("pointToPointSmallMicroseconds"),
                pointToPointLargeBytes: l.int("pointToPointLargeBytes"), pointToPointLargeMicroseconds: l.int("pointToPointLargeMicroseconds"),
                allSumSmallBytes: l.int("allSumSmallBytes"), allSumSmallMicroseconds: l.int("allSumSmallMicroseconds"),
                allSumLargeBytes: l.int("allSumLargeBytes"), allSumLargeMicroseconds: l.int("allSumLargeMicroseconds"))
            try l.finish()
        }
        let value = try ClusterWorkerReady(identity: identity, rank: r.int("rank"), profile: profile,
            executionPlanSHA256: r.string("executionPlanSHA256"), requestCapacityBytes: r.int("requestCapacityBytes"),
            dataPlane: dataPlane, servingContextTokens: r.optionalInt("servingContextTokens"), linkProbe: probe)
        try id.finish(); try p.finish(); try r.finish(); return value
    }
}

