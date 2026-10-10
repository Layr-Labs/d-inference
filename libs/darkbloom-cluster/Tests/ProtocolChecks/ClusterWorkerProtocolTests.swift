import Foundation
import DarkbloomClusterProtocol

private struct TestFailure: Error { let message: String }
private func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw TestFailure(message: message) }
}
private func refuses(_ body: () throws -> Void) throws {
    var rejected = false
    do { try body() } catch { rejected = true }
    try check(rejected, "Malformed input was accepted")
}
private let epoch = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
private let requestID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!
private let identity = ClusterWorkerIdentity(membershipEpoch: epoch, modelID: "example-model",
    artifactSHA256: String(repeating: "a", count: 64), configurationSHA256: String(repeating: "b", count: 64),
    peers: [.init(id: "first", buildSHA256: String(repeating: "c", count: 64)),
            .init(id: "second", buildSHA256: String(repeating: "d", count: 64))])
private let profile = ClusterWorkerProfile(id: "greedy-text", vocabularySize: 512,
    maximumPromptTokens: 16, maximumOutputTokens: 4, maximumChunkTokens: 8, maximumContextTokens: 20)
private let ready = ClusterWorkerReady(identity: identity, rank: 0, profile: profile,
    executionPlanSHA256: String(repeating: "e", count: 64), requestCapacityBytes: 1024)
private func reservation(output: Int = 2, stops: [Int] = [], deadline: UInt64 = 1000) -> ClusterWorkerReservation {
    .init(profileID: profile.id, promptTokenIDs: [1, 2, 3], stopTokenIDs: stops,
        outputCount: output, chunkSize: 2, deadlineUptimeNanoseconds: deadline, capacityLimitBytes: 900)
}
private struct Conversation {
    var session: ClusterWorkerSession
    var commandSequence: UInt64 = 0, eventSequence: UInt64 = 0
    var id = requestID
    init(rank: Int = 0) throws {
        session = try .init(identity: identity, rank: rank, profile: profile, executionPlanSHA256: ready.executionPlanSHA256)
        try event(.ready(.init(identity: identity, rank: rank, profile: profile,
            executionPlanSHA256: ready.executionPlanSHA256, requestCapacityBytes: ready.requestCapacityBytes)))
    }
    mutating func command(_ command: ClusterWorkerCommand, now: UInt64 = 10) throws {
        let request: UUID? = command == .shutdown ? nil : id
        try session.accept(.init(membershipEpoch: epoch, sequence: commandSequence, requestID: request, command: command), now: now)
        commandSequence += 1
    }
    mutating func event(_ event: ClusterWorkerEvent, now: UInt64 = 10) throws {
        let request: UUID?
        switch event { case .ready, .unavailable, .shutdownComplete: request = nil; default: request = id }
        try session.accept(.init(membershipEpoch: epoch, sequence: eventSequence, requestID: request, event: event), now: now)
        eventSequence += 1
    }
    mutating func start(_ value: ClusterWorkerReservation = reservation()) throws {
        try command(.reserve(value)); try event(.admitted(reservedBytes: 800)); try command(.start)
    }
}

@main
struct ClusterWorkerProtocolTests {
    static func main() throws {
        try roundTrips(); try malformedJSON(); try framing(); try lifecycle(); try refusals(); try replayAndDeadlines(); try receivingRank()
        print("{\"passed\":true,\"groups\":7,\"modelExecution\":false,\"localPipeIO\":true}")
    }
    static func roundTrips() throws {
        let commands: [ClusterWorkerCommand] = [.reserve(reservation()), .start,
            .tokenDecision(ordinal: 0, decision: .proceed), .tokenDecision(ordinal: 1, decision: .cleanStop),
            .cancel(.callerCancelled), .cancel(.deadline), .cancel(.peerFailure), .cancel(.runtimeError), .cancel(.outputFailure), .shutdown]
        for command in commands {
            let frame = ClusterWorkerCommandFrame(membershipEpoch: epoch, sequence: 0,
                requestID: command == .shutdown ? nil : requestID, command: command)
            try check(try ClusterWorkerCodec.decodeCommand(ClusterWorkerCodec.encode(frame)) == frame, "Command round trip")
        }
        let events: [ClusterWorkerEvent] = [.ready(ready), .admitted(reservedBytes: 10), .refused(.capacity),
            .committedToken(ordinal: 0, tokenID: 12, committedTokens: 3), .finished(.eos), .finished(.length),
            .finished(.clientStop), .failed(.peerFailure), .retired(.clean), .retired(.cancelled), .retired(.failed),
            .unavailable(.runtimeError), .shutdownComplete]
        for event in events {
            let id: UUID?
            switch event { case .ready, .unavailable, .shutdownComplete: id = nil; default: id = requestID }
            let frame = ClusterWorkerEventFrame(membershipEpoch: epoch, sequence: 0, requestID: id, event: event)
            try check(try ClusterWorkerCodec.decodeEvent(ClusterWorkerCodec.encode(frame)) == frame, "Event round trip")
        }
        let boundary = ClusterWorkerReservation(profileID: "large", promptTokenIDs: Array(repeating: 262143, count: 32767),
            stopTokenIDs: Array(0..<256), outputCount: 1, chunkSize: 32768, deadlineUptimeNanoseconds: 1000, capacityLimitBytes: 1)
        let frame = ClusterWorkerCommandFrame(membershipEpoch: epoch, sequence: 0, requestID: requestID, command: .reserve(boundary))
        try check(try ClusterWorkerCodec.decodeCommand(ClusterWorkerCodec.encode(frame)) == frame, "Bounded maximum token input")
    }
    static func malformedJSON() throws {
        let frame = ClusterWorkerCommandFrame(membershipEpoch: epoch, sequence: 0, requestID: requestID, command: .reserve(reservation()))
        let raw = String(decoding: try ClusterWorkerCodec.encode(frame), as: UTF8.self)
        let mutations = [raw.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"),
            raw.replacingOccurrences(of: "\"version\":1", with: "\"version\":true"),
            raw.replacingOccurrences(of: "\"version\":1", with: "\"version\":1.0"),
            raw.replacingOccurrences(of: "\"version\":1", with: "\"version\":1e0"),
            raw.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"version\":1"),
            raw.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"ver\\u0073ion\":1"),
            raw.replacingOccurrences(of: "\"outputCount\":2", with: "\"outputCount\":true"),
            raw.replacingOccurrences(of: "\"outputCount\":2", with: "\"outputCount\":0"),
            raw.replacingOccurrences(of: "\"outputCount\":2", with: "\"outputCount\":18446744073709551616"),
            raw.replacingOccurrences(of: "\"sequence\":0", with: "\"sequence\":-1"),
            raw.replacingOccurrences(of: "\"promptTokenIDs\":[1,2,3]", with: "\"promptTokenIDs\":[1,true,3]"),
            raw.replacingOccurrences(of: "\"stopTokenIDs\":[]", with: "\"stopTokenIDs\":[2,2]"),
            raw.replacingOccurrences(of: "\"stopTokenIDs\":[]", with: "\"stopTokenIDs\":[2,1]"),
            raw.replacingOccurrences(of: "\"profileID\":\"greedy-text\"", with: "\"profileID\":\"greedy-text\",\"extra\":0"),
            raw.replacingOccurrences(of: "\"kind\":\"reserve\"", with: "\"kind\":\"modelPayload\""),
            raw.replacingOccurrences(of: requestID.uuidString.lowercased(), with: requestID.uuidString),
            String(raw.dropLast()), raw + raw, "[]\n", "{\"version\":NaN}\n"]
        for value in mutations { try refuses { _ = try ClusterWorkerCodec.decodeCommand(Data(value.utf8)) } }
        let shutdown = "{\"kind\":\"shutdown\",\"membershipEpoch\":\"\(epoch.uuidString.lowercased())\",\"requestID\":null,\"sequence\":0,\"version\":1}\n"
        try refuses { _ = try ClusterWorkerCodec.decodeCommand(Data(shutdown.utf8)) }
        let deep = "{\"extra\":" + String(repeating: "[", count: 17) + "0" + String(repeating: "]", count: 17) + "}\n"
        try refuses { _ = try ClusterWorkerCodec.decodeCommand(Data(deep.utf8)) }
        try refuses { _ = try ClusterWorkerCodec.decodeEvent(Data([123,34,255,34,58,48,125,10])) }
    }
    static func framing() throws {
        let frame = ClusterWorkerEventFrame(membershipEpoch: epoch, sequence: 0, requestID: nil, event: .ready(ready))
        let raw = try ClusterWorkerCodec.encode(frame)
        var decoder = ClusterWorkerLineDecoder(commandStream: false), records: [Data] = []
        for byte in raw { records += try decoder.append(Data([byte])) }
        try check(records == [raw], "Fragmented frame")
        try decoder.finish(); try refuses { _ = try decoder.append(raw) }
        var coalesced = ClusterWorkerLineDecoder(commandStream: false)
        try check(try coalesced.append(raw + raw) == [raw, raw], "Coalesced frames")
        var truncated = ClusterWorkerLineDecoder(commandStream: false)
        _ = try truncated.append(raw.dropLast()); try refuses { try truncated.finish() }
        var oversized = ClusterWorkerLineDecoder(commandStream: false)
        try refuses { _ = try oversized.append(Data(repeating: 32, count: ClusterWorkerLimits.eventBytes + 1)) }
        try refuses { _ = try oversized.append(raw) }
        var empty = ClusterWorkerLineDecoder(commandStream: false)
        try refuses { _ = try empty.append(Data([10])) }
        let pipe = Pipe(); try pipe.fileHandleForWriting.write(contentsOf: raw)
        try pipe.fileHandleForWriting.close()
        var piped = ClusterWorkerLineDecoder(commandStream: false)
        let bytes = try pipe.fileHandleForReading.readToEnd() ?? Data()
        try check(try piped.append(bytes) == [raw], "Actual local pipe bytes")
        try piped.finish(); try pipe.fileHandleForReading.close()
    }
    static func lifecycle() throws {
        var c = try Conversation(); try c.start()
        try c.event(.committedToken(ordinal: 0, tokenID: 12, committedTokens: 3))
        try c.command(.tokenDecision(ordinal: 0, decision: .proceed))
        try c.event(.committedToken(ordinal: 1, tokenID: 13, committedTokens: 4))
        try c.command(.tokenDecision(ordinal: 1, decision: .proceed)); try c.event(.finished(.length))
        try check(c.session.lastLocalRetirementRequestID == nil && c.session.activeRequestID == requestID, "Finish is not retirement")
        try c.event(.retired(.clean)); try check(c.session.lastLocalRetirementRequestID == requestID, "Local retirement ACK")
        c.id = UUID(); try c.start(reservation(output: 3))
        try c.event(.committedToken(ordinal: 0, tokenID: 9, committedTokens: 3))
        try c.command(.tokenDecision(ordinal: 0, decision: .cleanStop)); try c.event(.finished(.clientStop)); try c.event(.retired(.clean))
        try check(c.session.locallyAvailable, "Clean stop preserves readiness")
        try c.command(.shutdown); try c.event(.shutdownComplete); try check(c.session.isShutdown, "Shutdown acknowledged")
        var eos = try Conversation(); try eos.start(reservation(output: 3, stops: [9]))
        try eos.event(.committedToken(ordinal: 0, tokenID: 9, committedTokens: 3))
        try eos.command(.tokenDecision(ordinal: 0, decision: .proceed)); try eos.event(.finished(.eos)); try eos.event(.retired(.clean))
        var cancelled = try Conversation(); try cancelled.command(.reserve(reservation())); try cancelled.event(.admitted(reservedBytes: 800))
        try cancelled.command(.cancel(.callerCancelled), now: 2000)
        try check(cancelled.session.activeRequestID == requestID && cancelled.session.lastLocalRetirementRequestID == nil, "Sent cancel is not ACK")
        try cancelled.event(.retired(.cancelled), now: 2000)
        var failed = try Conversation(); try failed.start(); try failed.event(.failed(.peerFailure))
        try failed.event(.retired(.failed)); try check(!failed.session.locallyAvailable, "Failure invalidates readiness")
        try failed.command(.shutdown); try failed.event(.shutdownComplete)
        var refused = try Conversation(); try refused.command(.reserve(reservation())); try refused.event(.refused(.capacity))
        try check(refused.session.activeRequestID == nil && refused.session.lastLocalRetirementRequestID == nil, "Refusal did not create a lease")
    }
    static func refusals() throws {
        for action in 0..<10 {
            var c = try Conversation(); try c.start()
            switch action {
            case 0: try refuses { try c.event(.retired(.clean)) }
            case 1: try refuses { try c.command(.shutdown) }
            case 2: try refuses { try c.event(.finished(.length)) }
            case 3: try refuses { try c.event(.committedToken(ordinal: 1, tokenID: 9, committedTokens: 4)) }
            case 4: try refuses { try c.event(.committedToken(ordinal: 0, tokenID: 512, committedTokens: 3)) }
            case 5: try refuses { try c.event(.committedToken(ordinal: 0, tokenID: 9, committedTokens: 4)) }
            case 6:
                try c.event(.committedToken(ordinal: 0, tokenID: 9, committedTokens: 3))
                try refuses { try c.event(.committedToken(ordinal: 1, tokenID: 10, committedTokens: 4)) }
            case 7:
                try c.event(.committedToken(ordinal: 0, tokenID: 9, committedTokens: 3))
                try refuses { try c.command(.tokenDecision(ordinal: 1, decision: .proceed)) }
            case 8:
                try c.command(.cancel(.deadline)); try refuses { try c.event(.retired(.clean)) }
            default:
                try c.event(.committedToken(ordinal: 0, tokenID: 9, committedTokens: 3))
                try c.command(.tokenDecision(ordinal: 0, decision: .cleanStop))
                try refuses { try c.event(.committedToken(ordinal: 1, tokenID: 10, committedTokens: 4)) }
            }
            try check(c.session.protocolFailed && !c.session.locallyAvailable, "Protocol refusal poisons transcript")
        }
    }
    static func replayAndDeadlines() throws {
        var stale = try Conversation()
        try refuses { try stale.session.accept(.init(membershipEpoch: epoch, sequence: 7, requestID: requestID, command: .reserve(reservation())), now: 10) }
        var wrongEpoch = try Conversation()
        try refuses { try wrongEpoch.session.accept(.init(membershipEpoch: UUID(), sequence: 0, requestID: requestID, command: .reserve(reservation())), now: 10) }
        var wrongRequest = try Conversation(); try wrongRequest.start()
        try refuses { try wrongRequest.session.accept(.init(membershipEpoch: epoch, sequence: 2, requestID: UUID(), command: .cancel(.callerCancelled)), now: 10) }
        var replay = try Conversation(); try replay.command(.reserve(reservation())); try replay.event(.refused(.capacity))
        try refuses { try replay.command(.reserve(reservation())) }
        var elapsed = try Conversation(); try elapsed.command(.reserve(reservation(deadline: 10)))
        try refuses { try elapsed.event(.admitted(reservedBytes: 800), now: 10) }
        var lateDecision = try Conversation(); try lateDecision.start(); try lateDecision.event(.committedToken(ordinal: 0, tokenID: 9, committedTokens: 3))
        try refuses { try lateDecision.command(.tokenDecision(ordinal: 0, decision: .proceed), now: 1000) }
        var ceiling = try Conversation(); try ceiling.command(.reserve(reservation()))
        try refuses { try ceiling.event(.admitted(reservedBytes: 901)) }
        var invalidated = try Conversation(); try invalidated.command(.reserve(reservation()))
        try invalidated.event(.unavailable(.peerFailure))
        try refuses { try invalidated.event(.admitted(reservedBytes: 800)) }
        var noAck = try Conversation(); try noAck.start(); var eof = ClusterWorkerLineDecoder(commandStream: false); try eof.finish()
        try check(noAck.session.activeRequestID == requestID && noAck.session.lastLocalRetirementRequestID == nil, "EOF cannot synthesize retirement")
    }
    static func receivingRank() throws {
        for reason: ClusterWorkerFinishReason in [.eos, .length, .clientStop] {
            var c = try Conversation(rank: 1); try c.start(); try c.event(.finished(reason))
            try check(c.session.lastLocalRetirementRequestID == nil, "Rank 1 finish is not retirement")
            try c.event(.retired(.clean)); try check(c.session.locallyAvailable, "Rank 1 native completion")
        }
        var token = try Conversation(rank: 1); try token.start()
        try refuses { try token.event(.committedToken(ordinal: 0, tokenID: 9, committedTokens: 3)) }
        var decision = try Conversation(rank: 1); try decision.start()
        try refuses { try decision.command(.tokenDecision(ordinal: 0, decision: .proceed)) }
        var early = try Conversation(rank: 1); try early.command(.reserve(reservation()))
        try early.event(.admitted(reservedBytes: 800)); try refuses { try early.event(.finished(.length)) }
        var cancelled = try Conversation(rank: 1); try cancelled.start()
        try cancelled.command(.cancel(.callerCancelled)); try refuses { try cancelled.event(.finished(.clientStop)) }
    }
}
