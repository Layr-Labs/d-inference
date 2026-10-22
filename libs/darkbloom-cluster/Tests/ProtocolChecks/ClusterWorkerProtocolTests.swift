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
        outputCount: output, chunkSize: 2, deadlineUptimeNanoseconds: deadline, capacityLimitBytes: 900, sampling: nil)
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
        var request: UUID? = command == .shutdown ? nil : id
        if case .keepWarm = command { request = nil }
        try session.accept(.init(membershipEpoch: epoch, sequence: commandSequence, requestID: request, command: command), now: now)
        commandSequence += 1
    }
    mutating func event(_ event: ClusterWorkerEvent, now: UInt64 = 10) throws {
        let request: UUID?
        switch event { case .ready, .unavailable, .shutdownComplete, .keptWarm: request = nil; default: request = id }
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
        try fullLengthOutput(); try roundTrips(); try malformedJSON(); try framing(); try lifecycle(); try refusals(); try replayAndDeadlines(); try receivingRank()
        try promptCache(); try servingContextAndGiveBack(); try sampling(); try lanes(); try laneCancellation()
        try tensorParallelModes()
        try logprobs()
        try nativeContext()
        print("{\"passed\":true,\"groups\":16,\"modelExecution\":false,\"localPipeIO\":true}")
    }

    /// Both ranks must accept and retain the requested 32K output budget.
    /// This exercises the real wire codec and session admission, not a client setting.
    static func fullLengthOutput() throws {
        let p = ClusterWorkerProfile(id: "long-output", vocabularySize: 512,
            maximumPromptTokens: 32_768, maximumOutputTokens: 32_768,
            maximumChunkTokens: 2048, maximumContextTokens: 65_536)
        for rank in 0...1 {
            var session = try ClusterWorkerSession(identity: identity, rank: rank, profile: p,
                executionPlanSHA256: ready.executionPlanSHA256)
            let r = ClusterWorkerReady(identity: identity, rank: rank, profile: p,
                executionPlanSHA256: ready.executionPlanSHA256, requestCapacityBytes: 1024,
                servingContextTokens: 65_536)
            let event = ClusterWorkerEventFrame(membershipEpoch: epoch, sequence: 0, requestID: nil, event: .ready(r))
            try session.accept(ClusterWorkerCodec.decodeEvent(ClusterWorkerCodec.encode(event)), now: 10)
            let reservation = ClusterWorkerReservation(profileID: p.id,
                promptTokenIDs: Array(repeating: 511, count: 32_768), stopTokenIDs: [],
                outputCount: 32_768, chunkSize: 2048, deadlineUptimeNanoseconds: 1000,
                capacityLimitBytes: 900, sampling: nil)
            let frame = ClusterWorkerCommandFrame(membershipEpoch: epoch, sequence: 0,
                requestID: requestID, command: .reserve(reservation))
            let decoded = try ClusterWorkerCodec.decodeCommand(ClusterWorkerCodec.encode(frame))
            try check(decoded == frame, "32K output reservation must not be truncated")
            try session.accept(decoded, now: 10)
        }
        for output in [0, ClusterWorkerLimits.wireOutputTokens + 1] {
            let invalid = ClusterWorkerReservation(profileID: p.id, promptTokenIDs: [1],
                stopTokenIDs: [], outputCount: output, chunkSize: 1,
                deadlineUptimeNanoseconds: 1000, capacityLimitBytes: 900, sampling: nil)
            try refuses { _ = try ClusterWorkerCodec.encode(ClusterWorkerCommandFrame(
                membershipEpoch: epoch, sequence: 0, requestID: requestID, command: .reserve(invalid))) }
        }
    }

    /// A model's native context crosses the wire: a 1,048,575-token prompt
    /// with the largest token IDs fits one command, both ranks' sessions admit
    /// it under a native profile (1,048,576 context, 65,536 output), and the
    /// serving context a rank's memory gate reports may be anything up to it.
    /// Beyond the wire's bounds is refused.
    static func nativeContext() throws {
        let p = ClusterWorkerProfile(id: "native-context", vocabularySize: 262_144,
            maximumPromptTokens: 1_048_575, maximumOutputTokens: 65_536,
            maximumChunkTokens: 2048, maximumContextTokens: 1_048_576)
        let prompt = Array(repeating: 262_143, count: 1_048_575)
        let reservation = ClusterWorkerReservation(profileID: p.id, promptTokenIDs: prompt,
            stopTokenIDs: Array(261_888..<262_144), outputCount: 1, chunkSize: 2048,
            deadlineUptimeNanoseconds: 1000, capacityLimitBytes: 900, sampling: nil)
        let frame = ClusterWorkerCommandFrame(membershipEpoch: epoch, sequence: UInt64(Int64.max) - 1,
            requestID: requestID, command: .reserve(reservation))
        let bytes = try ClusterWorkerCodec.encode(frame)
        try check(bytes.count <= ClusterWorkerLimits.commandBytes, "A native-context reservation fits one command")
        let decoded = try ClusterWorkerCodec.decodeCommand(bytes)
        try check(decoded == frame, "A native-context reservation round-trips")
        var lines = ClusterWorkerLineDecoder(commandStream: true), records: [Data] = []
        for start in stride(from: 0, to: bytes.count, by: ClusterWorkerLineDecoder.readChunkBytes) {
            records += try lines.append(bytes.subdata(in: start ..< min(bytes.count, start + ClusterWorkerLineDecoder.readChunkBytes)))
        }
        try check(records == [bytes], "A native-context command is one pipe record")
        for rank in 0...1 {
            var session = try ClusterWorkerSession(identity: identity, rank: rank, profile: p,
                executionPlanSHA256: ready.executionPlanSHA256)
            let r = ClusterWorkerReady(identity: identity, rank: rank, profile: p,
                executionPlanSHA256: ready.executionPlanSHA256, requestCapacityBytes: 1024,
                servingContextTokens: 700_000)
            try session.accept(ClusterWorkerCodec.decodeEvent(ClusterWorkerCodec.encode(ClusterWorkerEventFrame(
                membershipEpoch: epoch, sequence: 0, requestID: nil, event: .ready(r)))), now: 10)
            try session.accept(ClusterWorkerCodec.decodeCommand(ClusterWorkerCodec.encode(ClusterWorkerCommandFrame(
                membershipEpoch: epoch, sequence: 0, requestID: requestID, command: .reserve(reservation)))), now: 10)
        }
        let token = ClusterWorkerEventFrame(membershipEpoch: epoch, sequence: 0, requestID: requestID,
            event: .committedToken(ordinal: 0, tokenID: 1, committedTokens: 1_048_576))
        try check(try ClusterWorkerCodec.decodeEvent(ClusterWorkerCodec.encode(token)) == token, "The last native position")
        let warm = ClusterWorkerEventFrame(membershipEpoch: epoch, sequence: 0, requestID: nil,
            event: .keptWarm(ordinal: 1, microseconds: 1, servingContextTokens: 1_048_576))
        try check(try ClusterWorkerCodec.decodeEvent(ClusterWorkerCodec.encode(warm)) == warm, "A native serving context")
        let wide = ClusterWorkerProfile(id: "wide", vocabularySize: 512, maximumPromptTokens: 1_048_576,
            maximumOutputTokens: ClusterWorkerLimits.wireOutputTokens + 1, maximumChunkTokens: 2048,
            maximumContextTokens: 1_048_576)
        try refuses { _ = try ClusterWorkerCodec.encode(ClusterWorkerEventFrame(membershipEpoch: epoch, sequence: 0,
            requestID: nil, event: .ready(.init(identity: identity, rank: 0, profile: wide,
                executionPlanSHA256: ready.executionPlanSHA256, requestCapacityBytes: 1024)))) }
        let long = ClusterWorkerReservation(profileID: p.id, promptTokenIDs: Array(repeating: 1, count: 1_048_577),
            stopTokenIDs: [], outputCount: 1, chunkSize: 2048, deadlineUptimeNanoseconds: 1000,
            capacityLimitBytes: 900, sampling: nil)
        try refuses { _ = try ClusterWorkerCodec.encode(ClusterWorkerCommandFrame(membershipEpoch: epoch, sequence: 0,
            requestID: requestID, command: .reserve(long))) }
    }

    /// Round-2 fixes: the serving context travels in readiness and in every
    /// keep-warm answer; a refused reservation and a reservation given back
    /// before start (`cancel` then `retired(cancelled)`) both leave the worker
    /// idle and available for the next request.
    static func servingContextAndGiveBack() throws {
        let serving = ClusterWorkerReady(identity: identity, rank: 1, profile: profile,
            executionPlanSHA256: ready.executionPlanSHA256, requestCapacityBytes: 1024, servingContextTokens: 12)
        for event: ClusterWorkerEvent in [.ready(serving), .keptWarm(ordinal: 3, microseconds: 40, servingContextTokens: 12),
                                          .keptWarm(ordinal: 4, microseconds: 40)] {
            let frame = ClusterWorkerEventFrame(membershipEpoch: epoch, sequence: 1, requestID: nil, event: event)
            try check(try ClusterWorkerCodec.decodeEvent(ClusterWorkerCodec.encode(frame)) == frame, "Serving context round trip")
        }
        // Absent on the wire when nil: an older reader's records are unchanged.
        let plain = ClusterWorkerEventFrame(membershipEpoch: epoch, sequence: 1, requestID: nil, event: .ready(ready))
        try check(!String(decoding: try ClusterWorkerCodec.encode(plain), as: UTF8.self).contains("servingContext"),
            "A worker without a serving context writes none")
        for bad in [0, 21] {
            let value = ClusterWorkerReady(identity: identity, rank: 0, profile: profile,
                executionPlanSHA256: ready.executionPlanSHA256, requestCapacityBytes: 1024, servingContextTokens: bad)
            try refuses { _ = try ClusterWorkerCodec.encode(ClusterWorkerEventFrame(membershipEpoch: epoch, sequence: 0,
                requestID: nil, event: .ready(value))) }
        }
        // The link probe a tensor-parallel load measured travels in readiness;
        // absent when nil; refused when malformed.
        let probe = ClusterWorkerLinkProbe(transport: "jaccl", keyed: true, pointToPointSmallBytes: 64,
            pointToPointSmallMicroseconds: 18, pointToPointLargeBytes: 4 << 20, pointToPointLargeMicroseconds: 900,
            allSumSmallBytes: 20_480, allSumSmallMicroseconds: 31, allSumLargeBytes: 10_485_760, allSumLargeMicroseconds: 2_600)
        let probed = ClusterWorkerReady(identity: identity, rank: 0, profile: profile,
            executionPlanSHA256: ready.executionPlanSHA256, requestCapacityBytes: 1024, linkProbe: probe)
        let probedFrame = ClusterWorkerEventFrame(membershipEpoch: epoch, sequence: 1, requestID: nil, event: .ready(probed))
        try check(try ClusterWorkerCodec.decodeEvent(ClusterWorkerCodec.encode(probedFrame)) == probedFrame, "Link probe round trip")
        try check(!String(decoding: try ClusterWorkerCodec.encode(plain), as: UTF8.self).contains("linkProbe"),
            "A worker without a link probe writes none")
        for bad in [ClusterWorkerLinkProbe(transport: "jaccl", keyed: true, pointToPointSmallBytes: 64,
                        pointToPointSmallMicroseconds: 0, pointToPointLargeBytes: 4 << 20, pointToPointLargeMicroseconds: 900,
                        allSumSmallBytes: 20_480, allSumSmallMicroseconds: 31, allSumLargeBytes: 10_485_760, allSumLargeMicroseconds: 2_600),
                    ClusterWorkerLinkProbe(transport: "jaccl", keyed: true, pointToPointSmallBytes: 64,
                        pointToPointSmallMicroseconds: 18, pointToPointLargeBytes: 4 << 20, pointToPointLargeMicroseconds: 900,
                        allSumSmallBytes: 20_480, allSumSmallMicroseconds: 31, allSumLargeBytes: 20_480, allSumLargeMicroseconds: 2_600),
                    ClusterWorkerLinkProbe(transport: "carrier-pigeon", keyed: true, pointToPointSmallBytes: 64,
                        pointToPointSmallMicroseconds: 18, pointToPointLargeBytes: 4 << 20, pointToPointLargeMicroseconds: 900,
                        allSumSmallBytes: 20_480, allSumSmallMicroseconds: 31, allSumLargeBytes: 10_485_760, allSumLargeMicroseconds: 2_600)] {
            let value = ClusterWorkerReady(identity: identity, rank: 0, profile: profile,
                executionPlanSHA256: ready.executionPlanSHA256, requestCapacityBytes: 1024, linkProbe: bad)
            try refuses { _ = try ClusterWorkerCodec.encode(ClusterWorkerEventFrame(membershipEpoch: epoch, sequence: 0,
                requestID: nil, event: .ready(value))) }
        }
        // Refused for capacity: idle and available, the next reservation proceeds.
        var refused = try Conversation()
        try refused.command(.reserve(reservation()))
        try refused.event(.refused(.capacity))
        try check(refused.session.locallyAvailable && refused.session.activeRequestID == nil, "Capacity refusal keeps the worker")
        refused.id = UUID(); try refused.command(.reserve(reservation())); try refused.event(.admitted(reservedBytes: 512))
        // Given back before start: cancel, retired(cancelled), available again.
        var given = try Conversation()
        try given.command(.reserve(reservation())); try given.event(.admitted(reservedBytes: 512))
        try given.command(.cancel(.callerCancelled)); try given.event(.retired(.cancelled))
        try check(given.session.locallyAvailable && given.session.activeRequestID == nil && !given.session.protocolFailed,
            "A reservation given back before start keeps the worker")
        given.id = UUID(); try given.command(.reserve(reservation())); try given.event(.admitted(reservedBytes: 512))
        // A keep-warm answer may not claim more than the profile allows.
        var warm = try Conversation()
        try warm.command(.keepWarm(ordinal: 1))
        try warm.event(.keptWarm(ordinal: 1, microseconds: 1, servingContextTokens: 20))
        try warm.command(.keepWarm(ordinal: 2))
        try refuses { try warm.event(.keptWarm(ordinal: 2, microseconds: 1, servingContextTokens: 21)) }
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
            stopTokenIDs: Array(0..<256), outputCount: 1, chunkSize: 32768, deadlineUptimeNanoseconds: 1000, capacityLimitBytes: 1, sampling: nil)
        let frame = ClusterWorkerCommandFrame(membershipEpoch: epoch, sequence: 0, requestID: requestID, command: .reserve(boundary))
        try check(try ClusterWorkerCodec.decodeCommand(ClusterWorkerCodec.encode(frame)) == frame, "Bounded maximum token input")
        // A routed request: the route survives the codec; the pair as placed has no field at all.
        let base = reservation()
        let routed = ClusterWorkerReservation(profileID: base.profileID, promptTokenIDs: base.promptTokenIDs,
            stopTokenIDs: base.stopTokenIDs, outputCount: base.outputCount, chunkSize: base.chunkSize,
            deadlineUptimeNanoseconds: base.deadlineUptimeNanoseconds, capacityLimitBytes: base.capacityLimitBytes, sampling: base.sampling,
            route: .decodingRankAlone)
        let routedFrame = ClusterWorkerCommandFrame(membershipEpoch: epoch, sequence: 0, requestID: requestID, command: .reserve(routed))
        let routedBytes = try ClusterWorkerCodec.encode(routedFrame)
        try check(try ClusterWorkerCodec.decodeCommand(routedBytes) == routedFrame, "Routed reservation round trip")
        let plainBytes = try ClusterWorkerCodec.encode(ClusterWorkerCommandFrame(membershipEpoch: epoch, sequence: 0,
            requestID: requestID, command: .reserve(base)))
        try check(!String(decoding: plainBytes, as: UTF8.self).contains("route")
            && String(decoding: routedBytes, as: UTF8.self).contains("\"route\":\"decoding_rank_alone\""),
            "Only a routed reservation carries a route field")
        let unknown = String(decoding: routedBytes, as: UTF8.self).replacingOccurrences(of: "decoding_rank_alone", with: "both_ranks_alone")
        try check((try? ClusterWorkerCodec.decodeCommand(Data(unknown.utf8))) == nil, "An unknown route is refused")
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
    /// The prefix report: round trip, bounds, once and only before finish,
    /// never the whole prompt, on either rank.
    static func promptCache() throws {
        let report = ClusterWorkerEvent.promptCache(reusedTokens: 2, storedFrontiers: [1, 2])
        let frame = ClusterWorkerEventFrame(membershipEpoch: epoch, sequence: 0, requestID: requestID, event: report)
        try check(try ClusterWorkerCodec.decodeEvent(ClusterWorkerCodec.encode(frame)) == frame, "Prompt cache round trip")
        for bad in [ClusterWorkerEvent.promptCache(reusedTokens: 0, storedFrontiers: []),
                    .promptCache(reusedTokens: -1, storedFrontiers: [1]), .promptCache(reusedTokens: 1, storedFrontiers: [2, 1]),
                    .promptCache(reusedTokens: 1, storedFrontiers: Array(1...33))] {
            try refuses { _ = try ClusterWorkerCodec.encode(ClusterWorkerEventFrame(membershipEpoch: epoch, sequence: 0,
                requestID: requestID, event: bad)) }
        }
        var c = try Conversation(); try c.start()
        try c.event(.committedToken(ordinal: 0, tokenID: 12, committedTokens: 3))
        try c.command(.tokenDecision(ordinal: 0, decision: .proceed))
        try c.event(.committedToken(ordinal: 1, tokenID: 13, committedTokens: 4))
        try c.command(.tokenDecision(ordinal: 1, decision: .proceed))
        try c.event(.promptCache(reusedTokens: 2, storedFrontiers: [2]))
        try refuses { var again = c; try again.event(.promptCache(reusedTokens: 2, storedFrontiers: [2])) }
        try c.event(.finished(.length)); try c.event(.retired(.clean))
        // The whole prompt (3 tokens) is never reused: one token is always computed.
        var whole = try Conversation(); try whole.start()
        try whole.event(.committedToken(ordinal: 0, tokenID: 12, committedTokens: 3))
        try whole.command(.tokenDecision(ordinal: 0, decision: .proceed))
        try refuses { try whole.event(.promptCache(reusedTokens: 3, storedFrontiers: [])) }
        // Rank 0 reports only after a token decision; rank 1 while running.
        var early = try Conversation(); try early.start()
        try refuses { try early.event(.promptCache(reusedTokens: 1, storedFrontiers: [])) }
        var peer = try Conversation(rank: 1); try peer.start()
        try peer.event(.promptCache(reusedTokens: 2, storedFrontiers: [2])); try peer.event(.finished(.length))
        try peer.event(.retired(.clean))
    }
    /// Sampling: exact round trip of every value (float bit patterns, full
    /// 64-bit seed and stream), greedy reservations unchanged on the wire,
    /// canonical form only, and the resident profile's bounds.
    static func sampling() throws {
        let value = ClusterWorkerSampling(temperature: 0.7, topP: 0.95, topK: 20, minP: 0.05,
            repetitionPenalty: 1.1, repetitionContextSize: 64, frequencyPenalty: -0.25, presencePenalty: 0.5,
            seed: UInt64.max, stream: (1 << 63) | 12345,
            logitBias: [.init(tokenID: 3, bias: -100), .init(tokenID: 500, bias: 2.5)])
        let sampled = ClusterWorkerReservation(profileID: profile.id, promptTokenIDs: [1, 2, 3], stopTokenIDs: [],
            outputCount: 2, chunkSize: 2, deadlineUptimeNanoseconds: 1000, capacityLimitBytes: 900, sampling: value)
        let frame = ClusterWorkerCommandFrame(membershipEpoch: epoch, sequence: 0, requestID: requestID, command: .reserve(sampled))
        let decoded = try ClusterWorkerCodec.decodeCommand(ClusterWorkerCodec.encode(frame))
        try check(decoded == frame, "Sampling round trip")
        guard case .reserve(let back) = decoded.command, let s = back.sampling else { throw TestFailure(message: "Sampling lost") }
        try check(s.temperature.bitPattern == Float(0.7).bitPattern && s.seed == UInt64.max
            && s.stream == (1 << 63) | 12345 && s.logitBias[1].bias == 2.5, "Exact sampling values")
        // A greedy reservation carries no sampling field at all.
        let greedy = String(decoding: try ClusterWorkerCodec.encode(ClusterWorkerCommandFrame(membershipEpoch: epoch,
            sequence: 0, requestID: requestID, command: .reserve(reservation()))), as: UTF8.self)
        try check(!greedy.contains("sampling"), "Greedy reservation bytes unchanged")
        // Greedy with only a logit bias still needs the decoding rank's transform.
        let biasOnly = ClusterWorkerSampling(temperature: 0, topP: 1, topK: 0, minP: 0, repetitionPenalty: 1,
            repetitionContextSize: 64, frequencyPenalty: 0, presencePenalty: 0, seed: 1, stream: 2,
            logitBias: [.init(tokenID: 7, bias: 5)])
        try check(!biasOnly.isGreedyNoOp && !biasOnly.isStochastic && !biasOnly.admitsSpeculativeVerification, "Bias-only flags")
        try check(value.dependsOnHistory && !value.admitsSpeculativeVerification, "Penalties depend on history")
        func with(_ s: ClusterWorkerSampling) -> ClusterWorkerCommandFrame {
            .init(membershipEpoch: epoch, sequence: 0, requestID: requestID, command: .reserve(.init(profileID: profile.id,
                promptTokenIDs: [1, 2, 3], stopTokenIDs: [], outputCount: 2, chunkSize: 2, deadlineUptimeNanoseconds: 1000,
                capacityLimitBytes: 900, sampling: s)))
        }
        func variant(temperature: Float = 0.7, topK: Int = 20, context: Int = 64,
                     bias: [ClusterWorkerSampling.LogitBias] = []) -> ClusterWorkerSampling {
            .init(temperature: temperature, topP: 1, topK: topK, minP: 0, repetitionPenalty: 1,
                repetitionContextSize: context, frequencyPenalty: 0, presencePenalty: 0, seed: 1, stream: 2, logitBias: bias)
        }
        for bad in [variant(temperature: 0), variant(temperature: .nan), variant(temperature: .infinity),
                    variant(topK: -1), variant(topK: 262_145), variant(context: -1),
                    variant(bias: [.init(tokenID: 5, bias: 1), .init(tokenID: 4, bias: 1)]),
                    variant(bias: [.init(tokenID: 5, bias: 1), .init(tokenID: 5, bias: 2)]),
                    variant(bias: [.init(tokenID: 262_144, bias: 1)]),
                    variant(bias: [.init(tokenID: 1, bias: .nan)]),
                    variant(bias: (0..<4097).map { .init(tokenID: $0, bias: 1) })] {
            try refuses { _ = try ClusterWorkerCodec.encode(with(bad)) }
        }
        let raw = String(decoding: try ClusterWorkerCodec.encode(frame), as: UTF8.self)
        for mutation in [raw.replacingOccurrences(of: "\"topK\":20", with: "\"topK\":20,\"extra\":1"),
                         raw.replacingOccurrences(of: "\"seed\":\"ffffffffffffffff\"", with: "\"seed\":\"FFFFFFFFFFFFFFFF\""),
                         raw.replacingOccurrences(of: "\"seed\":\"ffffffffffffffff\"", with: "\"seed\":18446744073709551615"),
                         raw.replacingOccurrences(of: "\"logitBiasBits\":[", with: "\"logitBiasBits\":[1,"),
                         raw.replacingOccurrences(of: "\"temperatureBits\":\(Float(0.7).bitPattern)", with: "\"temperatureBits\":0.7")] {
            try check(mutation != raw, "Mutation applies")
            try refuses { _ = try ClusterWorkerCodec.decodeCommand(Data(mutation.utf8)) }
        }
        // The session holds a logit-bias token to the resident vocabulary.
        var c = try Conversation()
        try c.command(.reserve(.init(profileID: profile.id, promptTokenIDs: [1, 2, 3], stopTokenIDs: [],
            outputCount: 2, chunkSize: 2, deadlineUptimeNanoseconds: 1000, capacityLimitBytes: 900,
            sampling: variant(bias: [.init(tokenID: 512, bias: 1)]))))
        try refuses { try c.event(.admitted(reservedBytes: 800)) }
        var ok = try Conversation(); try ok.start(sampled)
    }
    /// A request asking for logprobs carries `topLogprobs`; each of its
    /// committed tokens carries exactly that many alternatives, and no other
    /// request's tokens carry any. Values travel bit-exact.
    static func logprobs() throws {
        let asks = ClusterWorkerSampling(temperature: 0, topP: 1, topK: 0, minP: 0, repetitionPenalty: 1,
            repetitionContextSize: 64, frequencyPenalty: 0, presencePenalty: 0, seed: 1, stream: 2, logitBias: [],
            topLogprobs: 2)
        // Greedy, yet the decoding rank must draw (and gather) with the product's sampler.
        try check(!asks.isGreedyNoOp && !asks.isStochastic && !asks.admitsSpeculativeVerification
            && asks.capturedLogprobs == 2, "Logprob flags")
        let value = ClusterWorkerReservation(profileID: profile.id, promptTokenIDs: [1, 2, 3], stopTokenIDs: [],
            outputCount: 2, chunkSize: 2, deadlineUptimeNanoseconds: 1000, capacityLimitBytes: 900, sampling: asks)
        let frame = ClusterWorkerCommandFrame(membershipEpoch: epoch, sequence: 0, requestID: requestID, command: .reserve(value))
        try check(try ClusterWorkerCodec.decodeCommand(ClusterWorkerCodec.encode(frame)) == frame, "topLogprobs round trip")
        // A request without logprobs keeps its exact bytes.
        let plain = ClusterWorkerSampling(temperature: 0.7, topP: 1, topK: 0, minP: 0, repetitionPenalty: 1,
            repetitionContextSize: 64, frequencyPenalty: 0, presencePenalty: 0, seed: 1, stream: 2, logitBias: [])
        let plainBytes = String(decoding: try ClusterWorkerCodec.encode(ClusterWorkerCommandFrame(membershipEpoch: epoch,
            sequence: 0, requestID: requestID, command: .reserve(.init(profileID: profile.id, promptTokenIDs: [1, 2, 3],
            stopTokenIDs: [], outputCount: 2, chunkSize: 2, deadlineUptimeNanoseconds: 1000, capacityLimitBytes: 900,
            sampling: plain)))), as: UTF8.self)
        try check(!plainBytes.contains("topLogprobs"), "No logprob field without logprobs")
        for bad in [21, -1] {
            let s = ClusterWorkerSampling(temperature: 0.7, topP: 1, topK: 0, minP: 0, repetitionPenalty: 1,
                repetitionContextSize: 64, frequencyPenalty: 0, presencePenalty: 0, seed: 1, stream: 2, logitBias: [],
                topLogprobs: bad)
            try refuses { _ = try ClusterWorkerCodec.encode(ClusterWorkerCommandFrame(membershipEpoch: epoch, sequence: 0,
                requestID: requestID, command: .reserve(.init(profileID: profile.id, promptTokenIDs: [1, 2, 3],
                stopTokenIDs: [], outputCount: 2, chunkSize: 2, deadlineUptimeNanoseconds: 1000, capacityLimitBytes: 900,
                sampling: s)))) }
        }
        let two = ClusterWorkerTokenLogprobs(logprob: -0.125, top: [.init(tokenID: 9, logprob: -0.125),
                                                                     .init(tokenID: 40, logprob: -.infinity)])
        let event = ClusterWorkerEventFrame(membershipEpoch: epoch, sequence: 3, requestID: requestID,
            event: .committedToken(ordinal: 0, tokenID: 9, committedTokens: 3, logprobs: two))
        let decoded = try ClusterWorkerCodec.decodeEvent(ClusterWorkerCodec.encode(event))
        try check(decoded == event, "Token logprobs round trip")
        guard case .committedToken(_, _, _, let back?) = decoded.event,
              back.logprob.bitPattern == Float(-0.125).bitPattern, back.top[1].logprob == -.infinity else {
            throw TestFailure(message: "Token logprobs are not bit-exact")
        }
        for bad in [ClusterWorkerTokenLogprobs(logprob: .nan, top: []), ClusterWorkerTokenLogprobs(logprob: 0.5, top: []),
                    ClusterWorkerTokenLogprobs(logprob: -1, top: [.init(tokenID: 262_144, logprob: -1)]),
                    ClusterWorkerTokenLogprobs(logprob: -1, top: (0..<21).map { .init(tokenID: $0, logprob: -1) })] {
            try refuses { _ = try ClusterWorkerCodec.encode(ClusterWorkerEventFrame(membershipEpoch: epoch, sequence: 3,
                requestID: requestID, event: .committedToken(ordinal: 0, tokenID: 9, committedTokens: 3, logprobs: bad))) }
        }
        // The session holds every token to the request's own count.
        var c = try Conversation(); try c.start(value)
        try refuses { try c.event(.committedToken(ordinal: 0, tokenID: 9, committedTokens: 3)) }
        var wrong = try Conversation(); try wrong.start(value)
        try refuses { try wrong.event(.committedToken(ordinal: 0, tokenID: 9, committedTokens: 3,
            logprobs: .init(logprob: -1, top: [.init(tokenID: 9, logprob: -1)]))) }
        var ok = try Conversation(); try ok.start(value)
        try ok.event(.committedToken(ordinal: 0, tokenID: 9, committedTokens: 3, logprobs: two))
        var none = try Conversation(); try none.start()
        try refuses { try none.event(.committedToken(ordinal: 0, tokenID: 9, committedTokens: 3, logprobs: two)) }
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

    /// Batch lanes: requests interleave, each keeps the one-request order;
    /// a full set of lanes, shutdown or keep-warm while busy are refused.
    static func lanes() throws {
        let a = UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!
        let b = UUID(uuidString: "dddddddd-1111-2222-3333-eeeeeeeeeeee")!
        let c = UUID(uuidString: "eeeeeeee-1111-2222-3333-ffffffffffff")!
        var session = try ClusterWorkerLaneSession(identity: identity, rank: 0, profile: profile,
            executionPlanSHA256: ready.executionPlanSHA256, lanes: 2)
        var commands: UInt64 = 0, events: UInt64 = 0
        func command(_ value: ClusterWorkerCommand, _ id: UUID?) throws {
            try session.accept(.init(membershipEpoch: epoch, sequence: commands, requestID: id, command: value), now: 10)
            commands += 1
        }
        func event(_ value: ClusterWorkerEvent, _ id: UUID?) throws {
            try session.accept(.init(membershipEpoch: epoch, sequence: events, requestID: id, event: value), now: 10)
            events += 1
        }
        try refuses { _ = try ClusterWorkerLaneSession(identity: identity, rank: 0, profile: profile,
            executionPlanSHA256: ready.executionPlanSHA256, lanes: 1) }
        try event(.ready(ready), nil)
        try command(.reserve(reservation(output: 3)), a); try event(.admitted(reservedBytes: 800), a)
        try command(.reserve(reservation(output: 2)), b); try event(.admitted(reservedBytes: 800), b)
        // Both lanes taken: a third reservation is a protocol error.
        var full = session
        try refuses { try full.accept(.init(membershipEpoch: epoch, sequence: commands, requestID: c,
            command: .reserve(reservation())), now: 10) }
        try command(.start, b); try command(.start, a)
        try check(Set(session.activeRequestIDs) == [a, b], "Both lanes are active")
        try event(.committedToken(ordinal: 0, tokenID: 7, committedTokens: 3), a)
        try event(.committedToken(ordinal: 0, tokenID: 8, committedTokens: 3), b)
        try check(session.awaitsDecision(a) && session.awaitsDecision(b), "Each lane awaits its own decision")
        // A second token before its decision, and a decision for the wrong ordinal, are refused.
        var early = session
        try refuses { try early.accept(.init(membershipEpoch: epoch, sequence: events, requestID: a,
            event: .committedToken(ordinal: 1, tokenID: 9, committedTokens: 4)), now: 10) }
        var wrong = session
        try refuses { try wrong.accept(.init(membershipEpoch: epoch, sequence: commands, requestID: a,
            command: .tokenDecision(ordinal: 1, decision: .proceed)), now: 10) }
        try command(.tokenDecision(ordinal: 0, decision: .proceed), b)
        try command(.tokenDecision(ordinal: 0, decision: .proceed), a)
        try event(.committedToken(ordinal: 1, tokenID: 9, committedTokens: 4), b)
        try command(.tokenDecision(ordinal: 1, decision: .proceed), b)
        // Lane b reached its output count: length, then clean retirement.
        try event(.finished(.length), b); try event(.retired(.clean), b)
        try check(session.activeRequestIDs == [a], "One lane left")
        var busy = session
        try refuses { try busy.accept(.init(membershipEpoch: epoch, sequence: commands, requestID: nil,
            command: .shutdown), now: 10) }
        var warm = session
        try refuses { try warm.accept(.init(membershipEpoch: epoch, sequence: commands, requestID: nil,
            command: .keepWarm(ordinal: 1)), now: 10) }
        // The freed lane takes a new request while lane a still runs (refused below for capacity).
        try command(.reserve(reservation()), c)
        try event(.committedToken(ordinal: 1, tokenID: 10, committedTokens: 4), a)
        try command(.tokenDecision(ordinal: 1, decision: .cleanStop), a)
        var wrongReason = session
        try refuses { try wrongReason.accept(.init(membershipEpoch: epoch, sequence: events, requestID: a,
            event: .finished(.length)), now: 10) }
        try event(.finished(.clientStop), a); try event(.retired(.clean), a)
        try event(.refused(.capacity), c)
        try check(session.activeRequestIDs.isEmpty, "Every lane retired")
        // A replayed request ID is refused even after it retired.
        var replay = session
        try refuses { try replay.accept(.init(membershipEpoch: epoch, sequence: commands, requestID: a,
            command: .reserve(reservation())), now: 10) }
        try command(.keepWarm(ordinal: 1), nil); try event(.keptWarm(ordinal: 1, microseconds: 5), nil)
        try command(.shutdown, nil); try event(.shutdownComplete, nil)
        try check(session.isShutdown, "Lane session shut down")
        // Rank 1 reports finish without tokens and without decisions.
        var peer = try ClusterWorkerLaneSession(identity: identity, rank: 1, profile: profile,
            executionPlanSHA256: ready.executionPlanSHA256, lanes: 4)
        try peer.accept(.init(membershipEpoch: epoch, sequence: 0, requestID: nil, event: .ready(.init(identity: identity,
            rank: 1, profile: profile, executionPlanSHA256: ready.executionPlanSHA256, requestCapacityBytes: 1024))), now: 10)
        try peer.accept(.init(membershipEpoch: epoch, sequence: 0, requestID: a, command: .reserve(reservation())), now: 10)
        try peer.accept(.init(membershipEpoch: epoch, sequence: 1, requestID: a, event: .admitted(reservedBytes: 800)), now: 10)
        try peer.accept(.init(membershipEpoch: epoch, sequence: 1, requestID: a, command: .start), now: 10)
        try peer.accept(.init(membershipEpoch: epoch, sequence: 2, requestID: a, event: .finished(.eos)), now: 10)
        try peer.accept(.init(membershipEpoch: epoch, sequence: 3, requestID: a, event: .retired(.clean)), now: 10)
        try check(peer.activeRequestIDs.isEmpty, "Rank 1 lane retired")
    }

    /// A started lane cancelled while others run retires as cancelled; the
    /// events it published before it read the cancel stay valid (they crossed
    /// it, as the owner service's mirror sees them), and a cancel that
    /// crosses a lane's own clean retirement changes nothing (no answer).
    static func laneCancellation() throws {
        let a = UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!
        let b = UUID(uuidString: "dddddddd-1111-2222-3333-eeeeeeeeeeee")!
        let stranger = UUID(uuidString: "eeeeeeee-1111-2222-3333-ffffffffffff")!
        var session = try ClusterWorkerLaneSession(identity: identity, rank: 0, profile: profile,
            executionPlanSHA256: ready.executionPlanSHA256, lanes: 2)
        var commands: UInt64 = 0, events: UInt64 = 0
        func command(_ value: ClusterWorkerCommand, _ id: UUID?, now: UInt64 = 10) throws {
            try session.accept(.init(membershipEpoch: epoch, sequence: commands, requestID: id, command: value), now: now)
            commands += 1
        }
        func event(_ value: ClusterWorkerEvent, _ id: UUID?) throws {
            try session.accept(.init(membershipEpoch: epoch, sequence: events, requestID: id, event: value), now: 10)
            events += 1
        }
        try event(.ready(ready), nil)
        for id in [a, b] {
            try command(.reserve(reservation(output: 3)), id); try event(.admitted(reservedBytes: 800), id)
            try command(.start, id)
        }
        try event(.committedToken(ordinal: 0, tokenID: 7, committedTokens: 3), a)
        try check(session.accepts(a, now: 10) && !session.isCancelled(a), "A running lane publishes")
        try check(!session.accepts(a, now: 1000), "A lane past its deadline publishes nothing more")
        try command(.tokenDecision(ordinal: 0, decision: .proceed), a)
        try command(.cancel(.callerCancelled), a)
        try check(session.isCancelled(a) && !session.accepts(a, now: 10), "A cancelled lane publishes nothing more")
        // A token the worker published before it read the cancel crossed it.
        try event(.committedToken(ordinal: 1, tokenID: 8, committedTokens: 4), a)
        var early = session
        try refuses { try early.accept(.init(membershipEpoch: epoch, sequence: events, requestID: a,
            event: .retired(.clean)), now: 10) }
        try event(.retired(.cancelled), a)
        // Lane b finishes; its owner's cancel crosses the finish, then its
        // clean retirement, and a later cancel changes nothing.
        try event(.committedToken(ordinal: 0, tokenID: 9, committedTokens: 3), b)
        try command(.tokenDecision(ordinal: 0, decision: .cleanStop), b)
        try event(.finished(.clientStop), b)
        try command(.cancel(.callerCancelled), b)
        try event(.retired(.clean), b)
        try command(.cancel(.callerCancelled), b)
        try check(!session.holds(b) && session.activeRequestIDs.isEmpty && !session.protocolFailed,
            "A cancel after its lane retired is a no-op")
        // A cancel for a request this session never held is still refused.
        var unknown = session
        try refuses { try unknown.accept(.init(membershipEpoch: epoch, sequence: commands, requestID: stranger,
            command: .cancel(.callerCancelled)), now: 10) }
        try command(.shutdown, nil); try event(.shutdownComplete, nil)
        try check(session.isShutdown, "Lane session shut down after a lane cancel")
    }

    /// Tensor parallel (`tensor_parallel_v1`) and its hybrid
    /// (`pipeline_prefill_tensor_decode_v1`): new closed cases after the four
    /// existing ones, their wire names fixed, the layer cuts each implies, the
    /// terms both ranks bind, and the qualification records that may carry them.
    static func tensorParallelModes() throws {
        try check(ClusterGenerationMode.allCases.map(\.rawValue) == ["pipeline_v1", "pipeline_compact_decode_v1",
            "phase_split_v1", "phase_split_mtp_v1", "tensor_parallel_v1", "pipeline_prefill_tensor_decode_v1", "pipeline_mtp_v1"],
            "tensor-parallel modes follow the existing four, then the pipeline's speculative rounds, in order, with fixed wire names")
        try check(ClusterGenerationMode.tensorParallel.usesTensorParallelDecode
            && ClusterGenerationMode.pipelinePrefillTensorDecode.usesTensorParallelDecode
            && !ClusterGenerationMode.phaseSplit.usesTensorParallelDecode && !ClusterGenerationMode.pipeline.usesTensorParallelDecode,
            "both tensor-parallel modes decode by tensor parallel; no other mode does")
        try check(!ClusterGenerationMode.tensorParallel.isPhaseSplit && !ClusterGenerationMode.pipelinePrefillTensorDecode.isPhaseSplit
            && !ClusterGenerationMode.tensorParallel.usesSpeculativeHead,
            "a tensor-parallel mode is not a phase split and runs no speculative head")
        try check(ClusterGenerationMode.tensorParallel.layerCutCount(ranks: 2) == 0
            && ClusterGenerationMode.pipelinePrefillTensorDecode.layerCutCount(ranks: 2) == 1
            && ClusterGenerationMode.pipeline.layerCutCount(ranks: 3) == 2,
            "tensor parallel cuts no layer range; the hybrid's prefill and every other mode cut ranks - 1 times")
        let terms = ClusterTensorParallelTerms.current
        try check(terms.partialsDType == "float32" && terms.shardRule == "kernel_aligned_heads_and_channels_v1"
            && terms.reduction == "sealed_all_gather_sum_v1" && terms.ranks == 2,
            "the bound terms: float32 partials, kernel-aligned shares of heads and channels, the sealed all-sum, two ranks")
        try check(terms.loadAgreementFields == ["cluster-tensor-parallel-v1", "float32", "kernel_aligned_heads_and_channels_v1",
            "sealed_all_gather_sum_v1", "2"], "the terms are bound into the load agreement field by field")
        var bf16 = terms; bf16.partialsDType = "bfloat16"
        try check(bf16.loadAgreementFields != terms.loadAgreementFields, "another partials dtype is another agreement")
        try check(ClusterGenerationMode.tensorParallel.tensorParallelTerms == terms
            && ClusterGenerationMode.pipelinePrefillTensorDecode.tensorParallelTerms == terms
            && ClusterGenerationMode.phaseSplit.tensorParallelTerms == nil, "only the tensor-parallel modes carry terms")
        func record(_ mode: String, cuts: [Int], layout: String? = nil) -> ClusterPairQualificationRecord {
            .init(runtimeModelID: "registered_qwen38_27b", artifactSHA256: String(repeating: "a", count: 64),
                ranks: [.init(rank: 0, chip: "Apple M3 Ultra", operatingSystem: "27.2"),
                        .init(rank: 1, chip: "Apple M5 Ultra", operatingSystem: "27.0.1")],
                cuts: cuts, generationMode: mode, prefillSchedule: "serial_v1", chunkTokens: 512, promptTokens: 1024,
                outputTokens: 128, transport: "jaccl", pairReportSHA256: String(repeating: "b", count: 64),
                pairReportCreatedUTC: "2026-10-14T05:00:00Z",
                comparisons: [.init(referenceChip: "Apple M3 Ultra", verdict: "exact", firstDivergenceIndex: nil,
                    gapInULPs: nil, nearTieThresholdULPs: 4, allowed: ["cut", "schedule", "profile"])],
                producer: "darkbloom-cluster-tp-check record", tensorParallelLayout: layout)
        }
        let layout = "plan=qwen_dense_heads_and_channels_v1;partials=float32;shares=equal"
        try check(record("tensor_parallel_v1", cuts: [], layout: layout).isConsistent, "a tensor-parallel record has no cut and is consistent")
        try check(!record("tensor_parallel_v1", cuts: [32], layout: layout).isConsistent, "a tensor-parallel record with a cut is not")
        try check(record("pipeline_prefill_tensor_decode_v1", cuts: [32], layout: layout).isConsistent, "a hybrid record has its prefill cut")
        try check(!record("pipeline_prefill_tensor_decode_v1", cuts: [], layout: layout).isConsistent, "a hybrid record without a cut is not")
        try check(!record("tensor_parallel_v1", cuts: []).isConsistent,
            "a tensor-parallel record must name its layout (plan, partials, shares): it qualifies that layout only")
        try check(!record("pipeline_v1", cuts: [32], layout: layout).isConsistent, "a pipeline record carries no tensor-parallel layout")
        let line = try record("pipeline_v1", cuts: [32]).encodedLine()
        try check(!line.contains("tensorParallelLayout"), "a record without a layout encodes as before (no new key)")
        let decoded = try ClusterPairQualificationRecord.decodeLines(try record("tensor_parallel_v1", cuts: [], layout: layout).encodedLine())
        try check(decoded.first?.tensorParallelLayout == layout && decoded.first?.isConsistent == true, "the layout round-trips")
        try check(!record("pipeline_v1", cuts: []).isConsistent && record("pipeline_v1", cuts: [32]).isConsistent,
            "a pipeline record still needs its cut")
    }
}
