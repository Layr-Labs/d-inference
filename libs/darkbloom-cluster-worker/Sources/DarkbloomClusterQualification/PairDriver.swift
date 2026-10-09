import Darwin
import DarkbloomClusterProcess
import DarkbloomClusterProtocol
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
        private let first: @Sendable () -> Void
        init(first: @escaping @Sendable () -> Void) { self.first = first }
        func record(_ event: ClusterWorkerRequestEvent) -> Bool {
            lock.lock(); defer { lock.unlock() }
            switch event {
            case .token(let id):
                tokens.append(id); stamps.append(DispatchTime.now().uptimeNanoseconds)
                if tokens.count == 1 { first() }
                return true
            case .finished(let reason): finish = reason.rawValue; done.signal(); return false
            case .failed(let message): failure = message; done.signal(); return false
            }
        }
        func wait(until deadline: UInt64) -> Bool { done.wait(timeout: .init(uptimeNanoseconds: deadline)) == .success }
        var snapshot: (tokens: [Int], stamps: [UInt64], finish: String?, failure: String?) {
            lock.lock(); defer { lock.unlock() }; return (tokens, stamps, finish, failure)
        }
    }

    public func run() -> PairReport {
        let c = configuration
        let redact = PairRedactor(sensitive: c.sensitive + [c.coordinator])
        var ranks = (0...1).map { PairRankReport(role: PairConfiguration.roles[$0], rank: $0) }
        var timing = PairTiming(note: "Driver clock, from the start command to rank 0's committed-token events; "
            + "includes control and transport. A recording worker also captures the final row and state digests, "
            + "so these are not serving timings.")
        var identity: QualificationIdentity?
        var hashesEqual: Bool?, metallibEqual: Bool?
        var endpoints: [PairWorkerEndpoint] = []

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
                ranks[rank].exitObserved = endpoint.launched && seen && endpoint.termination != nil
                if let termination = endpoint.termination {
                    if termination.signalled { ranks[rank].exitSignal = termination.status }
                    else { ranks[rank].exitStatus = termination.status }
                }
                let tail = redact(endpoint.diagnosticTail)
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
            return PairReport(outcome: outcome, failure: failure.map { redact($0) }, identity: identity, evidence: evidence,
                ranks: ranks, workerHashesIdentical: hashesEqual, metallibHashesIdentical: metallibEqual,
                recording: c.recording, ranksAgreeOnTokens: ranksAgree,
                bothExitsObserved: launched.allSatisfy { $0.termination != nil },
                noWorkerProcessLeft: left[0].flatMap { a in left[1].map { a == 0 && $0 == 0 } },
                progressTimeoutMilliseconds: c.progressTimeoutMilliseconds, timing: timing,
                promptSource: c.request.promptSource, decodedOutput: stream.flatMap { decode?($0) })
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
            return finish("refused", "the worker binaries differ: \(inspections[0].worker) on rank 0 local, \(inspections[1].worker) on rank 1 remote")
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
                  c.lifetimeSeconds <= capability.maxLifetimeSeconds,
                  let selected = capability.partitions.first(where: { $0.stages.count == 2 && $0.stages[0].sourceLayerEnd == c.stageCut }) else {
                throw QualificationError("the worker does not offer this model, profile, schedule, lifetime or cut")
            }
            partition = selected
        } catch {
            return finish("refused", "runtime description failed: \(error)")
        }
        identity = QualificationIdentity(request: c.request, stageCut: c.stageCut, prefillSchedule: c.prefillSchedule,
            artifactSHA256: capability.artifactSHA256, configurationSHA256: capability.configurationSHA256,
            planSHA256: partition.planSHA256)
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
            peers: PairConfiguration.peerIDs.map { .init(id: $0, buildSHA256: workerSHA256) })
        do {
            endpoints = try (0...1).map { rank in
                try PairWorkerEndpoint(command: c.command(rank, script: c.launchScript(rank,
                        artifactSHA256: capability.artifactSHA256, configurationSHA256: capability.configurationSHA256,
                        workerSHA256: workerSHA256)),
                    expectedIdentity: workerIdentity, rank: rank, profile: capability.profile,
                    executionPlanSHA256: partition.planSHA256, lifetimeSeconds: c.lifetimeSeconds)
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
                startupDeadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000, maximumRequests: 1)
        } catch { return finish("failed", "the pair could not be formed after both ranks reported ready: \(error)") }
        timing.startupSeconds = Double(DispatchTime.now().uptimeNanoseconds - begun) / 1e9
        log("pair-check: both ranks ready after \(String(format: "%.1f", timing.startupSeconds!)) s")

        // 5. Reserve on both ranks.
        let now = DispatchTime.now().uptimeNanoseconds
        let lifetimeEnd = pair.localLifetimeDeadlineUptimeNanoseconds
        guard lifetimeEnd > now + 8_000_000_000 else {
            return finish("failed", "the workers' lifetime was used up before the request could start")
        }
        let requestDeadline = min(now + UInt64(c.requestSeconds) * 1_000_000_000, lifetimeEnd - 3_000_000_000)
        guard let capacity = pair.readiness?.requestCapacityBytes else {
            return finish("failed", "the pair stopped being ready before the reservation")
        }
        let lease: ClusterWorkerRequest
        do {
            lease = try pair.reserve(requestID: c.request.requestUUID, reservation: .init(profileID: c.request.profileID,
                promptTokenIDs: c.request.promptTokenIDs, stopTokenIDs: c.request.stopTokenIDs,
                outputCount: c.request.outputCount, chunkSize: c.request.chunkSize,
                deadlineUptimeNanoseconds: requestDeadline, capacityLimitBytes: capacity))
        } catch {
            if let rank = (0...1).first(where: { endpoints[$0].refusal != nil }) {
                return finish("refused", "\(ranks[rank].role) refused the reservation (\(endpoints[rank].refusal!))")
            }
            return finish("failed", "reservation failed: \(error)")
        }
        timing.admissionSeconds = Double(DispatchTime.now().uptimeNanoseconds - now) / 1e9

        // 6. Start; rank 0's committed tokens arrive here and are allowed to continue.
        let started = DispatchTime.now().uptimeNanoseconds
        let announce = self.log
        let collector = Collector {
            announce("pair-check: first committed token after \(String(format: "%.2f", Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9)) s")
        }
        do { try lease.start { collector.record($0) } }
        catch { return finish("failed", "start failed: \(error)") }
        let concluded = collector.wait(until: requestDeadline + 5_000_000_000)
        let result = collector.snapshot
        if let first = result.stamps.first, let last = result.stamps.last {
            timing.firstTokenSeconds = Double(first - started) / 1e9
            timing.prefillTokensPerSecond = Double(c.request.promptTokenIDs.count) / timing.firstTokenSeconds!
            timing.decodeSeconds = Double(last - first) / 1e9
            if result.tokens.count > 1, last > first {
                timing.decodeTokensPerSecond = Double(result.tokens.count - 1) / timing.decodeSeconds!
            }
        }
        guard concluded, let reason = result.finish else {
            lease.cancel(reason: concluded ? .runtimeError : .deadline)
            return finish("failed", (result.failure ?? "the request did not finish before its deadline")
                + " after \(result.tokens.count) committed token(s)")
        }
        log("pair-check: request finished (\(reason)) with \(result.tokens.count) tokens")

        // 7. Clean shutdown: command, acknowledgement, process exit.
        let shutdownStarted = DispatchTime.now().uptimeNanoseconds
        Task.detached {
            await lease.waitUntilRetired()
            lease.releaseResources()
            await pair.shutdown()
        }
        let exitLimit = lifetimeEnd + 20_000_000_000
        for endpoint in endpoints { _ = endpoint.waitForExit(until: exitLimit) }
        timing.shutdownSeconds = Double(DispatchTime.now().uptimeNanoseconds - shutdownStarted) / 1e9

        // 8. Each rank's own record of the run.
        var evidence = QualificationEvidence(selectedTokenIDs: result.tokens, finishReason: reason)
        var ranksAgree: Bool?
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
        return finish(clean ? "completed" : "failed",
            clean ? nil : "the request completed but a worker did not acknowledge shutdown and exit with status 0",
            evidence: evidence, ranksAgree: ranksAgree)
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
