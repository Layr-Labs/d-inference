import Foundation
import CoreFoundation
import DarkbloomClusterProtocol

/// The SSH host is authenticated before these routing assertions are accepted.
/// Payloads are existing WorkerCodec objects; only reserve deadlines are translated.
struct OwnerWire: Sendable {
    let kind: String
    let epoch: UUID
    let lease: UUID
    let incarnation: UUID?
    let sequence: UInt64
    var clusterID: String?
    var launchID: UUID?
    var remaining: UInt64?
    var deliveryRemaining: UInt64?
    var payload: Data?
    var termination: ClusterOwnerTermination?
    var bootstrapProfile: ClusterOwnerBootstrapProfile?
    var bootstrapSequence: UInt64?
    var bootstrapBytes: Data?
    var nativeStart: Data?
    var nativeLocalDeadline: UInt64?
    /// S16: the worker's data-plane credential line, carried on the leader's
    /// authenticated owner route (SSH with a pinned host key, or the local
    /// pipe) and written as the worker's first input line. Never logged.
    var dataPlaneTrust: Data?

    /// Owner records cross the owner route once per token in each direction, from loops that never drain a pool (the
    /// owner's writer and reader, the worker owner's service and relay): each encode, decode and command builds its JSON
    /// in a pool of its own (round 6c case 5: rank 0 +20.6 and its worker owner +22.7 MiB a minute without it).
    func encoded(commandStream: Bool) throws -> Data { try ClusterAutorelease.drained { try encodedRecord(commandStream: commandStream) } }
    static func decode(_ data: Data, commandStream: Bool) throws -> Self { try ClusterAutorelease.drained { try decodeRecord(data, commandStream: commandStream) } }
    static func command(_ frame: ClusterWorkerCommandFrame, lease: UUID, incarnation: UUID,
                        sequence: UInt64, now: UInt64, deliveryDeadline: UInt64) throws -> Self {
        try ClusterAutorelease.drained {
            try commandRecord(frame, lease: lease, incarnation: incarnation, sequence: sequence, now: now, deliveryDeadline: deliveryDeadline)
        }
    }

    private func encodedRecord(commandStream: Bool) throws -> Data {
        var object: [String: Any] = ["version": 1, "kind": kind, "epoch": epoch.uuidString.lowercased(),
            "lease": lease.uuidString.lowercased(), "sequence": NSNumber(value: sequence)]
        if let incarnation { object["incarnation"] = incarnation.uuidString.lowercased() }
        if let clusterID { object["clusterID"] = clusterID }
        if let launchID { object["launchID"] = launchID.uuidString.lowercased() }
        if let remaining { object["remainingNanoseconds"] = NSNumber(value: remaining) }
        if let deliveryRemaining { object["deliveryRemainingNanoseconds"] = NSNumber(value: deliveryRemaining) }
        if let payload { object["worker"] = try JSONSerialization.jsonObject(with: payload) }
        if let bootstrapProfile { object["bootstrapProfile"] = bootstrapProfile.rawValue }
        if let bootstrapSequence { object["bootstrapSequence"] = NSNumber(value: bootstrapSequence) }
        if let bootstrapBytes { object["bootstrapBytes"] = bootstrapBytes.base64EncodedString() }
        if let nativeStart { object["nativeStart"] = nativeStart.base64EncodedString() }
        if let nativeLocalDeadline { object["nativeLocalDeadline"] = NSNumber(value: nativeLocalDeadline) }
        if let dataPlaneTrust { object["dataPlaneTrust"] = dataPlaneTrust.base64EncodedString() }
        if let termination {
            switch termination {
            case .launchFailed: object["termination"] = "launchFailed"
            case .neverLaunched: object["termination"] = "neverLaunched"
            case .exited(let status): object["termination"] = "exited"; object["status"] = status
            case .signalled(let signal): object["termination"] = "signalled"; object["status"] = signal
            }
        }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(10)
        _ = try Self.decode(data, commandStream: commandStream)
        return data
    }

    private static func decodeRecord(_ data: Data, commandStream: Bool) throws -> Self {
        try validateClusterWorkerEnvelope(data, commandStream: true) // Outer-only512KiB; embedded WorkerCodec retains its own bounds.
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw invalid("Owner object required") }
        func string(_ key: String) throws -> String {
            guard let value = object[key] as? String else { throw invalid("Owner string missing") }; return value
        }
        func uuid(_ key: String) throws -> UUID {
            let value = try string(key)
            guard let id = UUID(uuidString: value), id.uuidString.lowercased() == value else { throw invalid("Owner UUID differs") }; return id
        }
        func uint(_ key: String) throws -> UInt64 {
            guard let n = object[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  let value = UInt64(n.stringValue) else { throw invalid("Owner unsigned integer required") }; return value
        }
        guard try uint("version") == 1 else { throw invalid("Owner version differs") }
        let kind = try string("kind")
        let allowed = commandStream ? ["open", "command", "fence", "release", "bootstrapReply", "renew"] : ["hello", "event", "terminal", "released", "bootstrapRound"]
        guard allowed.contains(kind) else { throw invalid("Wrong owner message direction") }
        var keys: Set<String> = ["version", "kind", "epoch", "lease", "sequence"]
        let inc: UUID?
        if kind == "open" { inc = nil } else { inc = try uuid("incarnation"); keys.insert("incarnation") }
        var value = Self(kind: kind, epoch: try uuid("epoch"), lease: try uuid("lease"), incarnation: inc, sequence: try uint("sequence"))
        if ["open", "hello"].contains(kind), object["bootstrapProfile"] != nil {
            keys.insert("bootstrapProfile")
            guard let profile = ClusterOwnerBootstrapProfile(rawValue: try string("bootstrapProfile")) else { throw invalid("Unknown bootstrap profile") }
            value.bootstrapProfile = profile
        }
        switch kind {
        case "bootstrapRound", "bootstrapReply":
            keys.formUnion(["bootstrapSequence", "bootstrapBytes"])
            value.bootstrapSequence = try uint("bootstrapSequence")
            let encoded = try string("bootstrapBytes")
            let cap = kind == "bootstrapRound" ? 65_536 : 131_072
            guard encoded.utf8.count <= ((cap + 2) / 3) * 4, let bytes = Data(base64Encoded: encoded),
                  bytes.count > 0, bytes.count <= cap, bytes.base64EncodedString() == encoded,
                  value.bootstrapSequence! < UInt64(ClusterOwnerBootstrapProfile.maximumRounds) else { throw invalid("Bootstrap payload exceeds closed bounds") }
            value.bootstrapBytes = bytes
        case "open":
            keys.formUnion(["clusterID", "remainingNanoseconds"])
            value.clusterID = try string("clusterID")
            guard let label = value.clusterID, (1...128).contains(label.utf8.count), label.utf8.allSatisfy({ (33...126).contains($0) }) else { throw invalid("Cluster label differs") }
            value.remaining = try uint("remainingNanoseconds")
            if object["dataPlaneTrust"] != nil {
                keys.insert("dataPlaneTrust")
                let encoded = try string("dataPlaneTrust")
                guard encoded.utf8.count <= 5464, let line = Data(base64Encoded: encoded), line.base64EncodedString() == encoded,
                      let trust = try? ClusterWorkerCodec.decodeDataPlaneTrust(line), trust.membershipEpoch == value.epoch else {
                    throw invalid("Data-plane credential differs from its bound or epoch")
                }
                value.dataPlaneTrust = line
            }
            if value.bootstrapProfile?.carriesNativeStart == true {
                keys.insert("nativeStart")
                // Only the key-only development profile, opened by a local owner
                // on the same Mac, carries a local uptime deadline. The combined
                // profile may cross to another Mac, so it never does: its owner
                // bounds the bootstrap on its own clock.
                if value.bootstrapProfile == .nativeKeyPrelude {
                    keys.insert("nativeLocalDeadline")
                    value.nativeLocalDeadline = try uint("nativeLocalDeadline")
                    guard value.nativeLocalDeadline! > 0 else { throw invalid("Local native deadline is empty") }
                }
                let encoded = try string("nativeStart")
                guard encoded.utf8.count <= 4096, let start = Data(base64Encoded: encoded),
                      !start.isEmpty, start.count <= 3072, start.base64EncodedString() == encoded else {
                    throw invalid("Native public start exceeds its bound")
                }
                value.nativeStart = start
            }
        case "hello": keys.insert("launchID"); value.launchID = try uuid("launchID")
        case "renew":
            // A rank-lease renewal (S03): the owner's lease moves to this
            // duration after the frame arrives.
            keys.insert("remainingNanoseconds"); value.remaining = try uint("remainingNanoseconds")
            guard value.remaining! <= ClusterWorkerLease.maximumNanoseconds else { throw invalid("Lease renewal exceeds its bound") }
        case "command", "event":
            keys.insert("worker")
            if kind == "command" { keys.insert("deliveryRemainingNanoseconds"); value.deliveryRemaining = try uint("deliveryRemainingNanoseconds") }
            guard var worker = object["worker"] as? [String: Any] else { throw invalid("Worker object missing") }
            if kind == "command", worker["kind"] as? String == "reserve" {
                keys.insert("remainingNanoseconds"); value.remaining = try uint("remainingNanoseconds")
                guard var reservation = worker["reservation"] as? [String: Any], reservation["deadlineUptimeNanoseconds"] == nil else {
                    throw invalid("Remote reserve must not contain a host uptime")
                }
                reservation["deadlineUptimeNanoseconds"] = NSNumber(value: 1); worker["reservation"] = reservation
            }
            var encoded = try JSONSerialization.data(withJSONObject: worker, options: [.sortedKeys]); encoded.append(10)
            if kind == "command" { _ = try ClusterWorkerCodec.decodeCommand(encoded) }
            else { _ = try ClusterWorkerCodec.decodeEvent(encoded) }
            // Retain the validated reservation with a sentinel, never a foreign uptime.
            value.payload = encoded
        case "terminal":
            keys.formUnion(["launchID", "termination"]); value.launchID = try uuid("launchID")
            switch try string("termination") {
            case "launchFailed": value.termination = .launchFailed
            case "exited", "signalled":
                keys.insert("status")
                guard let status = object["status"] as? NSNumber, CFGetTypeID(status) != CFBooleanGetTypeID(),
                      let n = Int32(status.stringValue) else { throw invalid("Native termination status differs") }
                let signalled = try string("termination") == "signalled"
                guard !signalled || n > 0 else { throw invalid("Native signal differs") }
                value.termination = signalled ? .signalled(signal: n) : .exited(status: n)
            default: throw invalid("Unsupported native terminal")
            }
        default: break
        }
        for remaining in [value.remaining, value.deliveryRemaining].compactMap({ $0 }) {
            guard remaining > 0, remaining <= ClusterWorkerLimits.deadlineNanoseconds else { throw invalid("Owner duration outside bound") }
        }
        guard Set(object.keys) == keys else { throw invalid("Unexpected owner fields") }
        return value
    }

    private static func commandRecord(_ frame: ClusterWorkerCommandFrame, lease: UUID, incarnation: UUID,
                                      sequence: UInt64, now: UInt64, deliveryDeadline: UInt64) throws -> Self {
        var result = Self(kind: "command", epoch: frame.membershipEpoch, lease: lease, incarnation: incarnation, sequence: sequence)
        guard deliveryDeadline > now else { throw ClusterWorkerOwnerErrorProxy.deadline }
        result.deliveryRemaining = deliveryDeadline - now
        var payload = try ClusterWorkerCodec.encode(frame)
        if case .reserve(let reservation) = frame.command {
            guard reservation.deadlineUptimeNanoseconds > now else { throw ClusterWorkerOwnerErrorProxy.deadline }
            result.remaining = reservation.deadlineUptimeNanoseconds - now
            var worker = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
            var r = worker["reservation"] as! [String: Any]; r.removeValue(forKey: "deadlineUptimeNanoseconds"); worker["reservation"] = r
            payload = try JSONSerialization.data(withJSONObject: worker, options: [.sortedKeys]); payload.append(10)
        }
        result.payload = payload; return result
    }

    /// The leader's remaining request duration becomes a local deadline. It is
    /// not capped by the owner's lease, which the leader renews while the
    /// request runs; it must only start before the lease has lapsed.
    func localCommand(now: UInt64, lifetimeDeadline: UInt64) throws -> ClusterWorkerCommandFrame {
        guard kind == "command", let payload else { throw Self.invalid("No native command") }
        let frame = try ClusterWorkerCodec.decodeCommand(payload)
        guard frame.membershipEpoch == epoch else { throw Self.invalid("Inner epoch differs") }
        guard case .reserve(let r) = frame.command else { return frame }
        guard let remaining, now < lifetimeDeadline else { throw Self.invalid("Expired owner duration") }
        let end = now.addingReportingOverflow(remaining)
        guard !end.overflow else { throw Self.invalid("Owner duration overflow") }
        return .init(membershipEpoch: frame.membershipEpoch, sequence: frame.sequence, requestID: frame.requestID,
            command: .reserve(.init(profileID: r.profileID, promptTokenIDs: r.promptTokenIDs, stopTokenIDs: r.stopTokenIDs,
                outputCount: r.outputCount, chunkSize: r.chunkSize,
                deadlineUptimeNanoseconds: end.partialValue, capacityLimitBytes: r.capacityLimitBytes,
                sampling: r.sampling, route: r.route,mimoImages:r.mimoImages, stillImages:r.stillImages)))
    }
    static func invalid(_ reason: String) -> ClusterOwnerStateError { .invalid(reason) }
}

// Kept independent of Process's private fault bookkeeping.
enum ClusterWorkerOwnerErrorProxy: Error { case deadline, closed }
