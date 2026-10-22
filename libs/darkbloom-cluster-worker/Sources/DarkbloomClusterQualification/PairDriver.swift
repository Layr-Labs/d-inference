import CryptoKit
import Darwin
import DarkbloomClusterProcess
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
import Foundation

/// Runs one request on a two-rank pair: rank 0 on this Mac, rank 1 on the
/// second Mac, each reached through a command that carries the worker's
/// standard streams. The request protocol itself is the library's
/// `ClusterWorkerPair` and `ClusterWorkerRequest`.
///
/// Order of work: inspect both sides and refuse unless the worker and its
/// Metal library are byte-identical; launch rank 0, then rank 1; wait for both
/// to report ready; reserve, start and relay rank 0's committed tokens; shut
/// both down; collect each rank's evidence; count worker processes left.
///
/// A worker launched here is never signalled. On any failure the request is
/// cancelled, each worker's input is closed, and the driver waits for the
/// processes to end by themselves, at most until the lifetime they were given.
public struct PairDriver: Sendable {
    public let configuration: PairConfiguration
    public var log: @Sendable (String) -> Void = { _ in }
    public var decode: (@Sendable ([Int]) -> String?)?

    public init(configuration: PairConfiguration) { self.configuration = configuration }

    struct Inspection: Equatable {
        var worker = "", metallib = "", chip = "", os = ""
        var running = -1, guardMarkers = 0
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private let done = DispatchSemaphore(value: 0)
        private var tokens: [Int] = [], stamps: [UInt64] = []
        private var finish: String?, failure: String?
        private var concluded: UInt64?
        private(set) var reused: Int?
        private(set) var stored: [Int] = []
        private let first: @Sendable () -> Void
        private let stopAfter: Int?
        init(stopAfter: Int? = nil, first: @escaping @Sendable () -> Void) { self.stopAfter = stopAfter; self.first = first }
        func record(_ event: ClusterWorkerRequestEvent) -> Bool {
            lock.lock(); defer { lock.unlock() }
            switch event {
            case .token(let id, _):
                tokens.append(id); stamps.append(DispatchTime.now().uptimeNanoseconds)
                if tokens.count == 1 { first() }
                // false is the owner's clean stop: no further token is wanted.
                return stopAfter.map { tokens.count < $0 } ?? true
            case .finished(let reason):
                finish = reason.rawValue; concluded = DispatchTime.now().uptimeNanoseconds; done.signal(); return false
            case .failed(let message): failure = message; done.signal(); return false
            case .promptCache(let tokens, let frontiers): reused = tokens; stored = frontiers; return true
            case .telemetry: return true
            }
        }
        func wait(until deadline: UInt64) -> Bool { done.wait(timeout: .init(uptimeNanoseconds: deadline)) == .success }
        var snapshot: (tokens: [Int], stamps: [UInt64], finish: String?, failure: String?, concluded: UInt64?) {
            lock.lock(); defer { lock.unlock() }; return (tokens, stamps, finish, failure, concluded)
        }
    }

    /// Lines the runtime writes for its launcher. They carry a rank, a request
    /// ID, byte counts and durations, and nothing else.
    static let runtimeLinePrefixes = ["darkbloom-resident-load-v1 ", "darkbloom-phase-split-v1 ", "darkbloom-resident-release-v1 ",
        "darkbloom-mimo-resident-load-v1 ", "darkbloom-mimo-request-v1 ", "darkbloom-mimo-resident-release-v1 ",
        "darkbloom-mimo-step-v1 ", "darkbloom-forced-exit-v1 ", "darkbloom-orphan-wired-v1 ", "darkbloom-stage-residency-v1 ",
        "darkbloom-resident-context-v1 ", "darkbloom-resident-request-v1 ", "darkbloom-speculative-head-v1 ",
        "darkbloom-data-plane-v1 ", "darkbloom-data-plane-exchange-v1 ", "darkbloom-data-plane-tamper-v1 ",
        "darkbloom-data-plane-status-v1 ", "darkbloom-request-refused-v1 ", "darkbloom-serving-context-v1 ",
        "darkbloom-stage-loaded-range-v1 ", "darkbloom-prefix-v1 ", "darkbloom-prefix-ssd-v1 ",
        // Tensor parallel: the load (plan, shares, sealed all-sum), each request, the link probe and the collective wait.
        "darkbloom-tensor-parallel-load-v1 ", "darkbloom-tensor-parallel-request-v1 ", "darkbloom-link-probe-v1 ",
        "darkbloom-collective-sync-v1 "]
    /// The two workers' credential lines for one run (S16).
    static func dataPlaneLines(_ c: PairConfiguration) throws -> [Data?] {
        let identities = [P256.Signing.PrivateKey(), P256.Signing.PrivateKey()]
        let stranger = P256.Signing.PrivateKey()
        return try (0...1).map { rank -> Data? in
            let pin = ClusterDataPlanePin((rank == c.wrongPinRank ? stranger : identities[1 - rank]).publicKey)
            let credential = try ClusterDataPlaneCredential.issue(identity: identities[rank], epoch: c.membershipEpoch,
                rank: rank, peerPin: pin)
            let fields = credential.wireFields
            return try ClusterWorkerCodec.encode(ClusterWorkerDataPlaneTrust(membershipEpoch: c.membershipEpoch, rank: rank,
                workerSigningKey: fields.workerSigningKey, workerCertificate: fields.workerCertificate,
                memberIdentity: fields.memberIdentity, peerPin: fields.peerPin))
        }
    }

    /// A key file's 32 bytes: raw, or 64 hex characters with surrounding whitespace.
    static func prefixSSDKey(_ bytes: Data) -> Data? {
        if bytes.count == 32 { return bytes }
        let text = Array(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard text.count == 64 else { return nil }
        var key = Data(capacity: 32)
        for index in stride(from: 0, to: 64, by: 2) {
            guard let byte = UInt8(String(decoding: text[index..<index + 2], as: UTF8.self), radix: 16) else { return nil }
            key.append(byte)
        }
        return key
    }

    /// S16: the two ranks' last data-plane status lines agree when each
    /// direction's sealed records, bytes and send generation equal the peer's
    /// opened records, bytes and receive generation. Nil unless both ranks
    /// wrote one (a plaintext plane, or a rank that failed before its status).
    static func dataPlaneRecordAgreement(_ lines: [[String]]) -> (agree: Bool, rotations: Int)? {
        let prefix = "darkbloom-data-plane-status-v1 "
        let names = ["sealed_records", "opened_records", "sealed_bytes", "opened_bytes", "send_generation", "receive_generation"]
        guard lines.count == 2 else { return nil }
        var status: [[String: UInt64]] = []
        for (rank, rankLines) in lines.enumerated() {
            guard let line = rankLines.last(where: { $0.hasPrefix(prefix) }) else { return nil }
            var fields: [String: UInt64] = [:]
            for pair in line.dropFirst(prefix.count).split(separator: " ") {
                let parts = pair.split(separator: "=", omittingEmptySubsequences: false)
                guard parts.count == 2, let value = UInt64(parts[1]) else { return nil }
                fields[String(parts[0])] = value
            }
            guard fields["rank"] == UInt64(rank), names.allSatisfy({ fields[$0] != nil }) else { return nil }
            status.append(fields)
        }
        let agree = (0...1).allSatisfy { rank in
            let own = status[rank], peer = status[1 - rank]
            return own["sealed_records"] == peer["opened_records"] && own["sealed_bytes"] == peer["opened_bytes"]
                && own["send_generation"] == peer["receive_generation"] && own["active"] == 1
        }
        let rotations = status.reduce(UInt64(0)) { $0 + $1["send_generation"]! }
        return (agree, Int(clamping: rotations))
    }

    static func runtimeLines(_ diagnostics: String) -> [String] {
        diagnostics.split(separator: "\n").map(String.init).filter { line in
            runtimeLinePrefixes.contains { line.hasPrefix($0) }
                && line.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || [32, 45, 61, 95].contains($0) }
        }
    }

    public func run() -> PairReport {
        let c = configuration
        let redact = PairRedactor(sensitive: c.sensitive + [c.coordinator])
        var ranks = (0...1).map { PairRankReport(role: c.roles[$0], rank: $0) }
        var timing = PairTiming(note: "Driver clock, from the start command to rank 0's committed-token events; "
            + "includes control and transport. A recording worker also captures the final row and state digests, "
            + "so these are not serving timings."
            + (c.localRank == 0 ? "" : " Rank 0 ran on the second Mac, so every event timed here crossed the remote transport first.")
            + (c.workerTransport == PairConfiguration.jacclTransport ? ""
                : " Both ranks ran on one Mac over a loopback socket: not RDMA and not a pair timing."))
        var identity: QualificationIdentity?
        var hashesEqual: Bool?, metallibEqual: Bool?
        var endpoints: [PairWorkerEndpoint] = []
        var repetitionsAgree: Bool?

        func finish(_ outcome: String, _ failure: String?, evidence: QualificationEvidence? = nil,
                    ranksAgree: Bool? = nil) -> PairReport {
            if let failure { log("pair-check: \(outcome): \(redact(failure))") }
            // Withdraw whatever is still running, then wait for it to end by itself.
            for endpoint in endpoints where endpoint.launched && !endpoint.nativeCleanupObserved && !endpoint.shutdownCommandSent {
                endpoint.requestNativeCleanup()
            }
            let limit = (endpoints.map(\.localLifetimeDeadlineUptimeNanoseconds).max() ?? 0) + 20_000_000_000
            for (rank, endpoint) in endpoints.enumerated() {
                if endpoint.launched && !endpoint.nativeCleanupObserved {
                    log("pair-check: waiting for \(ranks[rank].role) to exit by itself")
                }
                let seen = endpoint.waitForExit(until: limit)
                ranks[rank].launched = endpoint.launched
                ranks[rank].readyObserved = endpoint.readyObserved
                ranks[rank].readySeconds = endpoint.readySeconds
                ranks[rank].requestCapacityBytes = endpoint.requestCapacityBytes
                ranks[rank].admitted = endpoint.admitted; ranks[rank].refusal = endpoint.refusal
                ranks[rank].events = endpoint.events
                ranks[rank].shutdownCommandSent = endpoint.shutdownCommandSent
                ranks[rank].shutdownCompleteObserved = endpoint.shutdownCompleteObserved
                ranks[rank].leaseRenewalsSent = endpoint.renewalsSent
                ranks[rank].keepWarmExchanges = endpoint.keepWarmAnswered
                if let plane = endpoint.dataPlane {
                    ranks[rank].dataPlane = plane.protection; ranks[rank].peerVerified = plane.peerVerified
                    ranks[rank].dataPlaneTranscriptSHA256 = plane.transcriptSHA256
                }
                ranks[rank].exitObserved = endpoint.launched && seen && endpoint.termination != nil
                if let termination = endpoint.termination {
                    if termination.signalled { ranks[rank].exitSignal = termination.status }
                    else { ranks[rank].exitStatus = termination.status }
                }
                let lines = Self.runtimeLines(endpoint.diagnosticTail)
                if !lines.isEmpty { ranks[rank].runtimeLines = lines }
                // The runtime's own lines are kept above; the rest is redacted free text.
                let other = endpoint.diagnosticTail.split(separator: "\n").map(String.init)
                    .filter { !lines.contains($0) }.joined(separator: "\n")
                let tail = redact(other)
                if !tail.isEmpty { ranks[rank].diagnostics = String(tail.suffix(2000)) }
            }
            // Count workers from this path on each side, whatever happened above.
            var left: [Int?] = [nil, nil]
            if hashesEqual != nil {
                for rank in 0...1 {
                    let fields = (try? helper(rank, c.runningScript(rank), seconds: 30)).map { Self.fields($0) } ?? [:]
                    left[rank] = fields["running"].flatMap { Int($0) }
                    ranks[rank].workerProcessesLeft = left[rank]
                    ranks[rank].wiredBytesAfter = fields["wired"].flatMap { Int($0) }
                }
            }
            // Nothing this run wrote stays behind, once no worker can still use it.
            if !c.keepRunFiles {
                for (rank, endpoint) in endpoints.enumerated() where endpoint.launched && left[rank] == 0 {
                    ranks[rank].runFilesRemoved = (try? helper(rank, c.removalScript(rank), seconds: 30))
                        .map { Self.fields($0)["removed"] == "1" } ?? false
                }
            }
            let launched = endpoints.filter(\.launched)
            let stream = evidence?.selectedTokenIDs
            var report = PairReport(outcome: outcome, failure: failure.map { redact($0) }, identity: identity, evidence: evidence,
                ranks: ranks, workerHashesIdentical: hashesEqual, metallibHashesIdentical: metallibEqual,
                recording: c.recording, ranksAgreeOnTokens: ranksAgree,
                bothExitsObserved: launched.allSatisfy { $0.termination != nil },
                noWorkerProcessLeft: left[0].flatMap { a in left[1].map { a == 0 && $0 == 0 } },
                progressTimeoutMilliseconds: c.progressTimeoutMilliseconds, timing: timing,
                promptSource: c.request.promptSource, decodedOutput: stream.flatMap { decode?($0) },
                generationMode: c.generationMode, repetitionsAgreeOnTokens: repetitionsAgree,
                workerTransport: c.workerTransport)
            report.dataPlane = c.dataPlane
            let planes = endpoints.map(\.dataPlane)
            if planes.count == 2, planes.allSatisfy({ $0 != nil }) {
                report.encryptedDataPlane = planes[0] == planes[1] && planes[0]!.protection == ClusterWorkerDataPlane.encrypted
                report.peerVerified = report.encryptedDataPlane == true && planes.allSatisfy { $0!.peerVerified }
            }
            if let records = Self.dataPlaneRecordAgreement(ranks.map { $0.runtimeLines ?? [] }) {
                report.dataPlaneRecordsAgree = records.agree; report.dataPlaneKeyRotations = records.rotations
            }
            return report
        }

        // 1. Both sides, before anything is launched.
        var inspections: [Inspection] = []
        for rank in 0...1 {
            do {
                let fields = Self.fields(try helper(rank, c.inspectionScript(rank), seconds: 60))
                guard let worker = fields["worker"], QualificationHash.isSHA256(worker),
                      let metallib = fields["metallib"], QualificationHash.isSHA256(metallib),
                      let running = fields["running"].flatMap({ Int($0) }) else {
                    throw QualificationError("the worker or the mlx.metallib beside it could not be hashed")
                }
                inspections.append(.init(worker: worker, metallib: metallib, chip: fields["chip"] ?? "",
                    os: fields["os"] ?? "", running: running, guardMarkers: fields["guard"].flatMap { Int($0) } ?? 0))
                ranks[rank].workerSHA256 = worker; ranks[rank].metallibSHA256 = metallib
                ranks[rank].chip = fields["chip"]; ranks[rank].operatingSystem = fields["os"]
                ranks[rank].wiredBytesBefore = fields["wired"].flatMap { Int($0) }
                ranks[rank].workerHasProgressGuard = inspections[rank].guardMarkers > 0
            } catch {
                return finish("refused", "\(ranks[rank].role): inspection failed: \(error)")
            }
        }
        hashesEqual = inspections[0].worker == inspections[1].worker
        metallibEqual = inspections[0].metallib == inspections[1].metallib
        guard hashesEqual == true else {
            return finish("refused", "the worker binaries differ: \(inspections[0].worker) on \(c.roles[0]), \(inspections[1].worker) on \(c.roles[1])")
        }
        guard metallibEqual == true else {
            return finish("refused", "the mlx.metallib files beside the workers differ")
        }
        if c.requireProgressGuard, let bare = (0...1).first(where: { inspections[$0].guardMarkers == 0 }) {
            return finish("refused", "\(ranks[bare].role): the worker has no JACCL progress guard; if its peer died it would spin forever")
        }
        if let busy = (0...1).first(where: { inspections[$0].running != 0 }) {
            return finish("refused", "\(ranks[busy].role): \(inspections[busy].running) worker process(es) from this path are already running")
        }
        let workerSHA256 = inspections[0].worker

        // 2. What the installed worker says it runs, for the registered files on each side.
        let capability: ClusterRuntimeCapability
        let partition: ClusterRuntimePartition
        do {
            let described = try (0...1).map {
                try ClusterRuntimeCapabilityCodec.decode(helper($0, c.capabilityScript($0, workerSHA256: workerSHA256), seconds: 60))
            }
            guard described[0] == described[1] else { throw QualificationError("the two workers describe different runtimes") }
            capability = described[0]
            guard capability.runtimeBinarySHA256 == workerSHA256, capability.runtimeModelID == c.request.modelID,
                  capability.profile.id == c.request.profileID,
                  capability.supportedPrefillSchedules.map(\.rawValue).contains(c.prefillSchedule),
                  capability.supportedGenerationModes.map(\.rawValue).contains(c.generationMode),
                  let selected = capability.partitions.first(where: { $0.stages.count == 2 && $0.stages[0].sourceLayerEnd == c.stageCut }) else {
                throw QualificationError("the worker does not offer this model, profile, schedule, generation mode or cut")
            }
            // The worker's own profile is the authority on how long a request may be.
            let p = capability.profile, prompt = c.request.promptTokenIDs.count, output = c.request.outputCount
            guard prompt <= p.maximumPromptTokens, output <= p.maximumOutputTokens, c.request.chunkSize <= p.maximumChunkTokens,
                  prompt <= p.maximumContextTokens - output else {
                throw QualificationError("the request (\(prompt) prompt and \(output) output tokens, chunk \(c.request.chunkSize)) exceeds "
                    + "the worker's profile (prompt \(p.maximumPromptTokens), output \(p.maximumOutputTokens), "
                    + "chunk \(p.maximumChunkTokens), context \(p.maximumContextTokens))")
            }
            partition = selected
        } catch {
            return finish("refused", "runtime description failed: \(error)")
        }
        identity = QualificationIdentity(request: c.request, stageCut: c.stageCut, prefillSchedule: c.prefillSchedule,
            artifactSHA256: capability.artifactSHA256, configurationSHA256: capability.configurationSHA256,
            planSHA256: partition.planSHA256)
        identity?.generationMode = c.generationMode
        identity?.profileFingerprint = capability.profileFingerprint
        identity?.stageSHA256 = partition.stages.map(\.stagePlanSHA256)
        identity?.arithmeticSHA256 = capability.arithmeticPolicySHA256

        if c.preflightOnly {
            log("pair-check: preflight passed; nothing was launched")
            return finish("preflight", nil)
        }

        // 3. Launch rank 0 first: it listens on the coordinator address.
        let workerIdentity = ClusterWorkerIdentity(membershipEpoch: c.membershipEpoch, modelID: capability.runtimeModelID,
            artifactSHA256: capability.artifactSHA256, configurationSHA256: capability.configurationSHA256,
            peers: c.peerIDs.map { .init(id: $0, buildSHA256: workerSHA256) })
        do {
            // S16: two member identities for this run, each rank pinning the
            // other's; a worker gets only its own per-epoch credential, as the
            // first line of its input (over the transport for the second Mac).
            var lines = try c.dataPlane == ClusterWorkerDataPlane.encrypted ? Self.dataPlaneLines(c) : [nil, nil]
            // Each side's prefix-SSD key, read on that side, follows as the next input line.
            for rank in 0...1 {
                guard let script = c.prefixSSDKeyScript(rank) else { continue }
                guard let key = Self.prefixSSDKey(try helper(rank, script, seconds: 30)) else {
                    throw QualificationError("\(ranks[rank].role): the prefix SSD key file holds no 32-byte key")
                }
                lines[rank] = (lines[rank] ?? Data()) + (try ClusterWorkerCodec.encode(ClusterWorkerPrefixSSDKey(
                    membershipEpoch: c.membershipEpoch, rank: rank, key: key)))
            }
            endpoints = try (0...1).map { rank in
                try PairWorkerEndpoint(command: c.command(rank, script: c.launchScript(rank,
                        artifactSHA256: capability.artifactSHA256, configurationSHA256: capability.configurationSHA256,
                        workerSHA256: workerSHA256)),
                    expectedIdentity: workerIdentity, rank: rank, profile: capability.profile,
                    executionPlanSHA256: partition.planSHA256,
                    stopRenewalsAfterNanoseconds: c.stopRenewalsAfterSeconds.map { UInt64($0 * 1e9) },
                    initialLine: lines[rank])
            }
        } catch { return finish("refused", "cannot prepare the workers: \(error)") }
        let begun = DispatchTime.now().uptimeNanoseconds
        let startupDeadline = begun + UInt64(c.startupSeconds) * 1_000_000_000
        for rank in 0...1 {
            if rank == 1 { Thread.sleep(forTimeInterval: c.rankOneDelaySeconds) }
            log("pair-check: launching \(ranks[rank].role)")
            do { try endpoints[rank].launch() } catch { return finish("failed", "\(ranks[rank].role): launch failed: \(error)") }
            guard endpoints[rank].waitForLaunchLine(until: min(startupDeadline, DispatchTime.now().uptimeNanoseconds + 30_000_000_000)) else {
                return finish("failed", "\(ranks[rank].role): the launch did not reach the worker"
                    + (endpoints[rank].termination.map { " (command ended with status \($0.status))" } ?? ""))
            }
        }

        // 4. Both ready, or nothing runs. Watch both at once, so one rank ending
        // early is seen while the other is still waiting for it.
        while DispatchTime.now().uptimeNanoseconds < startupDeadline,
              !endpoints.allSatisfy(\.readyObserved), !endpoints.contains(where: \.nativeCleanupObserved),
              endpoints.allSatisfy({ $0.faultDescription == nil }) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if let rank = (0...1).first(where: { endpoints[$0].termination != nil }), let termination = endpoints[rank].termination {
            return finish("failed", "\(ranks[rank].role) exited before the pair was ready (\(termination.signalled ? "signal" : "status") \(termination.status))")
        }
        guard endpoints.allSatisfy(\.readyObserved) else {
            let waiting = (0...1).filter { !endpoints[$0].readyObserved }.map { ranks[$0].role }
            return finish("failed", "not ready within \(c.startupSeconds) s: \(waiting.joined(separator: " and "))"
                + (endpoints.compactMap(\.faultDescription).first.map { " (\($0))" } ?? ""))
        }
        let pair: ClusterWorkerPair
        do {
            pair = try ClusterWorkerPair(workers: endpoints,
                startupDeadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000,
                keepWarm: c.keepWarm ? .standard : .off, refusesAboveServingContext: c.servingContextCheck, lanes: c.batchLanes,
                // GLM tensor parallel's lane loop retires a cancelled lane alone.
                lanesRetireAlone: c.generationMode == PairConfiguration.tensorParallelMode)
        } catch { return finish("failed", "the pair could not be formed after both ranks reported ready: \(error)") }
        timing.startupSeconds = Double(DispatchTime.now().uptimeNanoseconds - begun) / 1e9
        timing.servingContextAtReady = endpoints.map { $0.readiness?.servingContextTokens }
        log("pair-check: both ranks ready after \(String(format: "%.1f", timing.startupSeconds!)) s; serving context "
            + "\(pair.servingContextTokens) (rank 0 \(timing.servingContextAtReady?[0].map(String.init) ?? "?"), "
            + "rank 1 \(timing.servingContextAtReady?[1].map(String.init) ?? "?"))")
        if c.dataPlane == ClusterWorkerDataPlane.encrypted {
            guard let plane = pair.readiness?.dataPlane, plane.encryptedAndVerified else {
                return finish("failed", "the ranks did not report one encrypted, peer-verified data plane")
            }
            log("pair-check: data plane \(plane.protection), peers verified against their pins, transcript \(plane.transcriptSHA256.prefix(16))")
        } else if pair.readiness?.dataPlane != nil {
            return finish("failed", "a plaintext run reported a keyed data plane")
        }

        // 5 and 6. Reserve on both ranks, start, and let rank 0's committed
        // tokens continue; once per repetition, in the same loaded session.
        let announce = self.log
        var finalLease: ClusterWorkerRequest?
        var refused: [PairRefusedRequest] = []
        var firstRefused = false
        var result: (tokens: [Int], stamps: [UInt64], finish: String?, failure: String?, concluded: UInt64?) = ([], [], nil, nil, nil)
        var reason = ""
        var repetitions: [PairRepetitionTiming] = []
        var firstTokens: [Int] = []
        for repetition in 0..<c.totalRequests {
            // The request file's own request first, repeated; then each follow-up once.
            let current = repetition < c.repetitions ? c.request : c.followRequests[repetition - c.repetitions]
            // An idle gap leaves the session loaded and leased, as a server
            // between requests; the next request's first token shows whether
            // anything went cold meanwhile.
            var idleBefore: Double?
            if repetition > 0, !c.idleSeconds.isEmpty {
                let gap = c.idleSeconds[(repetition - 1) % c.idleSeconds.count]
                if gap > 0 { Thread.sleep(forTimeInterval: gap) }
                idleBefore = gap
            }
            let now = DispatchTime.now().uptimeNanoseconds
            let requestDeadline = now + UInt64(c.requestSeconds) * 1_000_000_000
            guard let capacity = pair.readiness?.requestCapacityBytes else {
                return finish("failed", "the pair stopped being ready before the reservation")
            }
            // The first request carries the request file's ID, which names the
            // recorded evidence. A repeated request needs an ID of its own.
            let requestID = repetition == 0 ? c.request.requestUUID : UUID()
            let serving = pair.servingContextTokens
            let refusedBefore = endpoints.map(\.refusalCount)
            let lease: ClusterWorkerRequest
            do {
                lease = try pair.reserve(requestID: requestID, reservation: .init(profileID: current.profileID,
                    promptTokenIDs: current.promptTokenIDs, stopTokenIDs: current.stopTokenIDs,
                    outputCount: current.outputCount, chunkSize: current.chunkSize,
                    deadlineUptimeNanoseconds: requestDeadline, capacityLimitBytes: capacity,
                    sampling: current.sampling?.wire, route: current.route.flatMap(ClusterWorkerRoute.init(rawValue:))))
            } catch ClusterWorkerOwnerError.refused(let why) {
                // This request alone: refused up front (longer than the
                // serving context) or by a rank's live gate and given back by
                // the other. The pair is still valid; go on to the next request.
                let refusing = (0...1).filter { endpoints[$0].refusalCount > refusedBefore[$0] }
                refused.append(.init(ordinal: repetition, requestID: requestID.uuidString.lowercased(),
                    promptTokens: current.promptTokenIDs.count, outputTokens: current.outputCount, reason: why.rawValue,
                    servingContextTokens: serving, refusedUpFront: refusing.isEmpty, refusingRanks: refusing))
                if repetition == 0 { firstRefused = true }
                log("pair-check: request \(repetition + 1) of \(c.totalRequests) refused (\(why.rawValue)) before it started: "
                    + "\(current.promptTokenIDs.count + current.outputCount) context tokens, serving context \(serving), "
                    + (refusing.isEmpty ? "refused up front" : "refused by " + refusing.map { ranks[$0].role }.joined(separator: " and "))
                    + "; the pair is \(pair.readiness == nil ? "NOT ready" : "still ready")")
                timing.refusedRequests = refused
                guard pair.readiness != nil else { return finish("failed", "the pair stopped being ready after a refused request") }
                continue
            } catch {
                if let rank = (0...1).first(where: { endpoints[$0].refusal != nil }) {
                    return finish("refused", "\(ranks[rank].role) refused the reservation (\(endpoints[rank].refusal!))")
                }
                return finish("failed", "reservation failed: \(error)")
            }
            let admission = Double(DispatchTime.now().uptimeNanoseconds - now) / 1e9
            defer { if repetition + 1 >= c.totalRequests { finalLease = lease } }

            let started = DispatchTime.now().uptimeNanoseconds
            let collector = Collector(stopAfter: c.stopAfterTokens) {
                announce("pair-check: first committed token after \(String(format: "%.2f", Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9)) s")
            }
            do { try lease.start { collector.record($0) } }
            catch { return finish("failed", "start failed: \(error)") }
            let concluded = collector.wait(until: requestDeadline + 5_000_000_000)
            result = collector.snapshot
            var measured: PairRepetitionTiming?
            if let first = result.stamps.first, let last = result.stamps.last {
                let firstToken = Double(first - started) / 1e9, decode = Double(last - first) / 1e9
                measured = .init(requestID: requestID.uuidString.lowercased(), admissionSeconds: admission,
                    firstTokenSeconds: firstToken,
                    prefillTokensPerSecond: Double(current.promptTokenIDs.count) / firstToken, decodeSeconds: decode,
                    decodeTokensPerSecond: result.tokens.count > 1 && last > first ? Double(result.tokens.count - 1) / decode : nil,
                    totalSeconds: Double((result.concluded ?? last) - started) / 1e9,
                    secondTokenGapSeconds: result.stamps.count > 1 ? Double(result.stamps[1] - first) / 1e9 : nil,
                    tokens: result.tokens.count, selectedTokenIDsSHA256: QualificationHash.tokenIDs(result.tokens),
                    finishReason: result.finish ?? "none")
                measured?.idleBeforeSeconds = idleBefore
                if repetition == 0 {
                    timing.admissionSeconds = admission
                    timing.firstTokenSeconds = firstToken
                    timing.prefillTokensPerSecond = measured?.prefillTokensPerSecond
                    timing.decodeSeconds = decode
                    timing.decodeTokensPerSecond = measured?.decodeTokensPerSecond
                    timing.totalSeconds = measured?.totalSeconds
                }
            }
            guard concluded, let finished = result.finish else {
                lease.cancel(reason: concluded ? .runtimeError : .deadline)
                // Name a rank whose process is already gone; the other is still
                // on its own way out and is reported with its exit status below.
                let gone = (0...1).compactMap { rank in
                    endpoints[rank].termination.map { "\(ranks[rank].role) ended with \($0.signalled ? "signal" : "status") \($0.status) during the request" }
                }
                return finish("failed", (result.failure ?? "the request did not finish before its deadline")
                    + " after \(result.tokens.count) committed token(s)" + (gone.isEmpty ? "" : "; " + gone.joined(separator: "; ")))
            }
            reason = finished
            if var measured {
                measured.reusedPromptTokens = collector.reused
                measured.storedPromptFrontiers = collector.stored.isEmpty ? nil : collector.stored
                measured.promptTokens = current.promptTokenIDs.count
                measured.promptTokenIDsSHA256 = current.promptTokenIDsSHA256
                measured.servingContextTokens = serving
                repetitions.append(measured)
            }
            timing.repetitions = repetitions
            if repetition == 0 { firstTokens = result.tokens }
            if repetition < c.repetitions { repetitionsAgree = (repetitionsAgree ?? true) && result.tokens == firstTokens }
            log("pair-check: request \(repetition + 1) of \(c.totalRequests) finished (\(reason)) with \(result.tokens.count) tokens"
                + ", \(collector.reused ?? 0) prompt tokens reused")
            if repetition + 1 < c.totalRequests {
                // The next reservation needs this one retired and released.
                let limit = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
                while !lease.isRetired, DispatchTime.now().uptimeNanoseconds < limit { Thread.sleep(forTimeInterval: 0.002) }
                guard lease.isRetired else { return finish("failed", "request \(repetition + 1) did not retire") }
                lease.releaseResources()
            }
        }
        if c.repetitions == 1 { repetitionsAgree = nil }
        timing.servingContextAtEnd = pair.servingContextTokens
        let lastLease = finalLease

        // 6b. Continuous batching: each batch request alone, then the waves.
        if !c.batchRequests.isEmpty {
            // A refused last repetition left no lease to retire.
            if let finalLease {
                let limit = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
                while !finalLease.isRetired, DispatchTime.now().uptimeNanoseconds < limit { Thread.sleep(forTimeInterval: 0.002) }
                guard finalLease.isRetired else { return finish("failed", "the last repetition did not retire before the batch phase") }
                finalLease.releaseResources()
            }
            var batch = PairBatchTiming(lanes: c.batchLanes, kvBackend: c.kvBackend ?? "paged", solo: [], waves: [],
                note: "Driver clock per request from its own start command; a wave's requests are started together "
                    + "from separate threads. Solo rows are each request file run alone in the same loaded session.")
            if c.batchSolo {
                for index in c.batchRequests.indices {
                    let rows = runBatchWave(pair: pair, indices: [index], log: announce)
                    batch.solo.append(contentsOf: rows.requests)
                    if let failure = rows.requests.compactMap(\.failure).first {
                        timing.batch = batch
                        return finish("failed", "batch solo request \(index) failed: \(failure)")
                    }
                }
            }
            for size in c.batchWaves {
                var wave = runBatchWave(pair: pair, indices: Array(0..<size), log: announce)
                if c.batchSolo {
                    for row in wave.requests.indices {
                        let request = wave.requests[row]
                        guard let solo = batch.solo.first(where: { $0.promptIndex == request.promptIndex }) else { continue }
                        // A request cancelled mid-run must match its solo run as far as it got.
                        wave.requests[row].matchesSolo = request.cancelledAfterTokens == nil
                            ? request.selectedTokenIDs == solo.selectedTokenIDs
                            : Array(solo.selectedTokenIDs.prefix(request.selectedTokenIDs.count)) == request.selectedTokenIDs
                        wave.requests[row].firstDifferenceIndex = zip(request.selectedTokenIDs, solo.selectedTokenIDs)
                            .enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset
                            ?? (request.selectedTokenIDs.count == solo.selectedTokenIDs.count ? nil
                                : min(request.selectedTokenIDs.count, solo.selectedTokenIDs.count))
                    }
                    wave.allMatchSolo = wave.requests.allSatisfy { $0.matchesSolo == true }
                }
                batch.waves.append(wave)
                log("pair-check: wave of \(size): \(wave.totalTokens) tokens in \(String(format: "%.2f", wave.wallSeconds)) s"
                    + " (\(String(format: "%.1f", wave.aggregateTokensPerSecond)) tok/s aggregate)"
                    + (wave.allMatchSolo.map { $0 ? ", tokens equal solo" : ", tokens DIFFER from solo" } ?? ""))
                if let failure = wave.requests.compactMap(\.failure).first {
                    timing.batch = batch
                    return finish("failed", "batch wave of \(size) failed: \(failure)")
                }
                // Tensor-parallel lanes keep each request's own arithmetic:
                // a token that differs from the request alone fails the run.
                if c.generationMode == PairConfiguration.tensorParallelMode, wave.allMatchSolo == false {
                    timing.batch = batch
                    return finish("failed", "batch wave of \(size): tokens differ from the requests run alone")
                }
                guard pair.readiness != nil else {
                    timing.batch = batch
                    return finish("failed", "the pair stopped being ready after the batch wave of \(size)")
                }
            }
            timing.batch = batch
        }

        // 7. Clean shutdown: command, acknowledgement, process exit.
        let shutdownStarted = DispatchTime.now().uptimeNanoseconds
        Task.detached {
            if let lastLease {
                await lastLease.waitUntilRetired()
                lastLease.releaseResources()
            }
            await pair.shutdown()
        }
        // A clean shutdown is acknowledged in seconds; a lease that lapsed
        // ends a worker within its time to live, plus the forced exit's bound.
        let exitLimit = DispatchTime.now().uptimeNanoseconds + ClusterWorkerLease.ttlNanoseconds + 60_000_000_000
        for endpoint in endpoints { _ = endpoint.waitForExit(until: exitLimit) }
        timing.shutdownSeconds = Double(DispatchTime.now().uptimeNanoseconds - shutdownStarted) / 1e9

        // 8. Each rank's own record of the run.
        var evidence = QualificationEvidence(selectedTokenIDs: result.tokens, finishReason: reason)
        var ranksAgree: Bool?
        if c.recording && firstRefused {
            // The recorded request never ran: nothing to collect.
            let clean = endpoints.allSatisfy { $0.shutdownCompleteObserved && $0.termination == .init(status: 0, signalled: false) }
            return finish("refused", "the recorded request was refused before it started (\(refused.first?.reason ?? "?"))"
                + (clean ? "; both ranks shut down cleanly" : "; a worker did not acknowledge shutdown and exit with status 0"))
        }
        if c.recording {
            do {
                let records = try (0...1).map { rank -> PairEvidence in
                    let record = try PairEvidence.decode(helper(rank, c.evidenceScript(rank), seconds: 60), rank: rank)
                    ranks[rank].evidenceCollected = true
                    ranks[rank].evidenceSelectedTokenIDs = record.execution.selectedTokenIDs
                    return record
                }
                ranksAgree = records.allSatisfy { $0.execution.selectedTokenIDs == result.tokens }
                let joined = try PairEvidence.join(records)
                guard ranksAgree == true, joined.identity.requestID == c.request.requestID,
                      joined.identity.planSHA256 == partition.planSHA256,
                      joined.identity.artifactSHA256 == capability.artifactSHA256,
                      joined.identity.configurationSHA256 == capability.configurationSHA256,
                      joined.evidence.finishReason == reason else {
                    return finish("failed", "the ranks' recorded evidence differs from the run the driver observed",
                                  ranksAgree: ranksAgree)
                }
                evidence = joined.evidence
                identity?.requestFingerprint = joined.identity.requestFingerprint
                identity?.profileFingerprint = joined.identity.profileFingerprint
                identity?.stageSHA256 = joined.identity.stageSHA256
                identity?.storageCommitmentSHA256 = joined.identity.storageCommitmentSHA256
                identity?.arithmeticSHA256 = joined.identity.arithmeticSHA256
            } catch {
                return finish("failed", "evidence collection failed: \(error)", ranksAgree: ranksAgree)
            }
        }
        let clean = endpoints.allSatisfy { $0.shutdownCompleteObserved && $0.termination == .init(status: 0, signalled: false) }
        if refused.count == c.totalRequests {
            return finish("refused", "every request was refused before it started (\(refused.map(\.reason).joined(separator: ", ")))"
                + (clean ? "; both ranks shut down cleanly" : "; a worker did not acknowledge shutdown and exit with status 0"))
        }
        return finish(clean ? "completed" : "failed",
            clean ? nil : "the request completed but a worker did not acknowledge shutdown and exit with status 0",
            evidence: evidence, ranksAgree: ranksAgree)
    }

    /// One wave: the batch requests at `indices`, each reserved and started
    /// from its own thread at once; returns when every one finished or failed,
    /// retired and released.
    func runBatchWave(pair: ClusterWorkerPair, indices: [Int], log: @escaping @Sendable (String) -> Void) -> PairBatchWave {
        let c = configuration
        final class Box: @unchecked Sendable {
            let lock = NSLock(); var rows: [PairBatchRequestTiming] = []
            func add(_ row: PairBatchRequestTiming) { lock.withLock { rows.append(row) } }
        }
        let box = Box(), group = DispatchGroup()
        let waveStart = DispatchTime.now().uptimeNanoseconds
        let cancelled = indices.count > 1 ? c.batchCancelAfterTokens.map { (index: indices[indices.count - 1], after: $0) } : nil
        for (position, index) in indices.enumerated() {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                if c.batchStaggerMilliseconds > 0 {
                    Thread.sleep(forTimeInterval: Double(position * c.batchStaggerMilliseconds) / 1000)
                }
                let request = c.batchRequests[index]
                let id = UUID()
                let started = DispatchTime.now().uptimeNanoseconds
                let deadline = started + UInt64(c.requestSeconds) * 1_000_000_000
                func row(_ tokens: [Int], _ finish: String) -> PairBatchRequestTiming {
                    PairBatchRequestTiming(promptIndex: index, requestID: id.uuidString.lowercased(),
                        promptTokens: request.promptTokenIDs.count, startOffsetSeconds: Double(started - waveStart) / 1e9,
                        tokens: tokens, finishReason: finish)
                }
                guard let capacity = pair.readiness?.requestCapacityBytes else {
                    var failed = row([], "none"); failed.failure = "the pair stopped being ready"; box.add(failed); return
                }
                let lease: ClusterWorkerRequest
                do {
                    lease = try pair.reserve(requestID: id, reservation: .init(profileID: request.profileID,
                        promptTokenIDs: request.promptTokenIDs, stopTokenIDs: request.stopTokenIDs,
                        outputCount: request.outputCount, chunkSize: request.chunkSize,
                        deadlineUptimeNanoseconds: deadline, capacityLimitBytes: capacity,
                        // A batch request's own sampling, as the single request's
                        // (before the reservation's sampling was required, a
                        // sampled batch request ran greedy here).
                        sampling: request.sampling?.wire))
                } catch {
                    var failed = row([], "none"); failed.failure = "reservation failed: \(error)"; box.add(failed); return
                }
                let collector = Collector(stopAfter: nil) {}
                let cancelAfter = cancelled?.index == index ? cancelled?.after : nil
                do {
                    try lease.start { event in
                        let wanted = collector.record(event)
                        // The cancel a caller makes: this lane alone retires.
                        if let cancelAfter, case .token = event, collector.snapshot.tokens.count == cancelAfter {
                            lease.cancel(reason: .callerCancelled)
                        }
                        return wanted
                    }
                } catch {
                    var failed = row([], "none"); failed.failure = "start failed: \(error)"; box.add(failed); return
                }
                if cancelAfter != nil {
                    // Its end is its retirement, not a finish.
                    let limit = deadline + 5_000_000_000
                    while !lease.isRetired, DispatchTime.now().uptimeNanoseconds < limit { Thread.sleep(forTimeInterval: 0.002) }
                    var value = row(collector.snapshot.tokens, "cancelled")
                    value.cancelledAfterTokens = cancelAfter
                    if lease.isRetired { lease.releaseResources() } else { value.failure = "the cancelled request did not retire" }
                    box.add(value); return
                }
                let concluded = collector.wait(until: deadline + 5_000_000_000)
                let result = collector.snapshot
                var value = row(result.tokens, result.finish ?? "none")
                value.reusedPromptTokens = collector.reused
                if let first = result.stamps.first, let last = result.stamps.last {
                    value.firstTokenSeconds = Double(first - started) / 1e9
                    value.decodeSeconds = Double(last - first) / 1e9
                    value.decodeTokensPerSecond = result.tokens.count > 1 && last > first
                        ? Double(result.tokens.count - 1) / (Double(last - first) / 1e9) : nil
                    value.totalSeconds = Double((result.concluded ?? last) - started) / 1e9
                }
                if !concluded || result.finish == nil {
                    value.failure = result.failure ?? "the request did not finish before its deadline"
                    lease.cancel(reason: concluded ? .runtimeError : .deadline)
                }
                let limit = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
                while !lease.isRetired, DispatchTime.now().uptimeNanoseconds < limit { Thread.sleep(forTimeInterval: 0.002) }
                if lease.isRetired { lease.releaseResources() } else if value.failure == nil { value.failure = "did not retire" }
                box.add(value)
            }
        }
        group.wait()
        let rows = box.rows.sorted { $0.promptIndex < $1.promptIndex }
        let end = rows.compactMap { row in row.totalSeconds.map { row.startOffsetSeconds + $0 } }.max() ?? 0
        let tokens = rows.reduce(0) { $0 + $1.tokens }
        let rates = rows.compactMap(\.decodeTokensPerSecond)
        return PairBatchWave(concurrency: indices.count, wallSeconds: end, totalTokens: tokens,
            aggregateTokensPerSecond: end > 0 ? Double(tokens) / end : 0,
            summedDecodeTokensPerSecond: rates.count == rows.count && !rates.isEmpty ? rates.reduce(0, +) : nil,
            requests: rows, allMatchSolo: nil)
    }

    /// `key=value` lines of an inspection.
    static func fields(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { result[String(parts[0])] = String(parts[1]) }
        }
        return result
    }

    /// A short command on one side: hashing, process listing, metadata, reading
    /// evidence. Never a loaded worker. It gets no input and a bounded output,
    /// and is the only kind of process this driver may terminate.
    func helper(_ rank: Int, _ script: String, seconds: Int) throws -> Data {
        let command = configuration.command(rank, script: script)
        let process = Process(), output = Pipe(), diagnostics = Pipe()
        process.executableURL = URL(fileURLWithPath: command[0]); process.arguments = Array(command.dropFirst())
        process.environment = PairConfiguration.transportEnvironment
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = diagnostics
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        let box = HelperOutput()
        try process.run()
        try? output.fileHandleForWriting.close(); try? diagnostics.fileHandleForWriting.close()
        let readers = DispatchGroup()
        for (descriptor, isOutput) in [(output.fileHandleForReading.fileDescriptor, true),
                                       (diagnostics.fileHandleForReading.fileDescriptor, false)] {
            readers.enter()
            Thread.detachNewThread {
                defer { readers.leave() }
                let limit = isOutput ? PairEvidence.maximumBytes + 1 : 65_536
                var buffer = [UInt8](repeating: 0, count: 1 << 16)
                while true {
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { return }
                    box.append(Data(buffer.prefix(count)), output: isOutput, limit: limit)
                }
            }
        }
        if finished.wait(timeout: .now() + .seconds(seconds)) != .success {
            process.terminate()
            _ = finished.wait(timeout: .now() + 5)
            throw QualificationError("an inspection command did not finish within \(seconds) s")
        }
        _ = readers.wait(timeout: .now() + 5)
        let (data, errors) = box.value
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let detail = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw QualificationError("command ended with status \(process.terminationStatus)" + (detail.isEmpty ? "" : ": " + String(detail.suffix(600))))
        }
        return data
    }

    private final class HelperOutput: @unchecked Sendable {
        private let lock = NSLock()
        private var output = Data(), errors = Data()
        func append(_ chunk: Data, output isOutput: Bool, limit: Int) {
            lock.lock(); defer { lock.unlock() }
            if isOutput { if output.count < limit { output.append(chunk.prefix(limit - output.count)) } }
            else if errors.count < limit { errors.append(chunk.prefix(limit - errors.count)) }
        }
        var value: (Data, Data) { lock.lock(); defer { lock.unlock() }; return (output, errors) }
    }
}
