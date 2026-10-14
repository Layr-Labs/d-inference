import Darwin
import DarkbloomClusterProtocol
import DarkbloomClusterRemote
import DarkbloomClusterSecurity
import Foundation

// S24 observability checks (model-free; loopback only; not a hardware pass).
//
//   observability-check SCRATCH_DIR
//
// A. Incident log: record, cursor, dismissal, supersession, the 200 ring,
//    origin de-duplication, a corrupt file, owner-only files, two writers.
// B. Classifier and guidance: Darkbloom's own launch and serving failures and
//    the owner's oMLX failure modes (paraphrased) each get a specific reason;
//    every reason has guidance; codes are stable.
// C. Pair telemetry: records, ring, medians, MTP acceptance, the file.
// D. Worker protocol: the request telemetry event's codec, bounds and order.
// E. Status mirror: codec compatibility, the board's transitions, the
//    publisher, and a real link control edge on loopback.

let output = FileHandle.standardOutput
nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passes = 0
func check(_ condition: Bool, _ label: String) {
    if condition { passes += 1; output.write(Data("PASS \(label)\n".utf8)) }
    else { failures += 1; output.write(Data("FAIL \(label)\n".utf8)) }
}
func refuses(_ label: String, _ body: () throws -> Void) {
    var refused = false
    do { try body() } catch { refused = true }
    check(refused, label)
}

let scratch = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
    : NSTemporaryDirectory() + "observability-check-\(getpid())")
try? FileManager.default.removeItem(at: scratch)
try! FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

// MARK: A. Incident log

func incidentChecks() throws {
    let home = scratch.appendingPathComponent("home-a")
    let file = ClusterIncidentLog.defaultFile(homeDirectory: home)
    let log = ClusterIncidentLog(file: file, redact: { $0.replacingOccurrences(of: "secret-host", with: "<host>") })
    let empty = log.feed()
    check(empty.incidents.isEmpty && empty.loadError == nil && empty.epoch.isEmpty, "A1 a missing log reads as empty, no error")

    let first = try log.record(.init(severity: .error, source: "leader", stateCode: .activationLaunchFailed,
        explanation: ClusterFailureClassifier.classify(message: "ssh: connect to host secret-host port 22: No route to host"),
        jobID: "epoch-1", deploymentID: "pair-1", modelID: "model-a", rank: 1))
    check(first.seq == 1 && first.id.count == 32 && first.reasonCode == "peer_unreachable" && first.guidanceCode == "peer_unreachable",
          "A2 first record: seq 1, 32-hex id, classified reason and guidance")
    check(first.message.contains("<host>") && !first.message.contains("secret-host"), "A3 the message is redacted before it is stored")
    var info = stat()
    check(stat(file.path, &info) == 0 && info.st_mode & 0o777 == 0o600, "A4 the log file is owner-only (0600)")
    check(stat(file.deletingLastPathComponent().path, &info) == 0 && info.st_mode & 0o777 == 0o700, "A5 its directory is owner-only (0700)")

    let second = try log.record(.init(severity: .warn, source: "follower", stateCode: .linkEdgeDown, message: "edge down\u{0}\n  twice",
                                      jobID: "epoch-1"))
    check(second.seq == 2 && second.message == "edge down twice", "A6 control characters are removed and whitespace collapsed")
    check(log.feed(since: 1).incidents.map(\.seq) == [2], "A7 the cursor returns only later records")
    let epoch = log.feed().epoch
    check(epoch.count == 16, "A8 the log has a 16-hex epoch")

    let other = ClusterIncidentLog(file: file)   // a second process's view of the same file
    let third = try other.record(.init(severity: .error, source: "cli", stateCode: .sessionFailed, message: "from another writer"))
    check(third.seq == 3 && log.feed().incidents.count == 3 && log.feed().epoch == epoch, "A9 two writers share one sequence and epoch")

    check(try log.dismiss(id: first.id) && log.feed().open.map(\.seq) == [3, 2], "A10 dismissal keeps the record and hides it from open")
    check(try !log.dismiss(id: String(repeating: "0", count: 32)), "A11 dismissing an unknown ID reports false")
    check(try log.supersede(jobID: "epoch-1", by: third.id) == 2, "A12 supersession flags every other record of the job")
    check(log.feed().incidents.first { $0.seq == 2 }?.supersededBy == third.id, "A13 the superseded record is kept, flagged")

    let mirrored = try log.record(.init(severity: .error, source: "follower", stateCode: "peer_lost", reasonCode: "peer_lost",
        guidanceCode: "peer_lost", message: "mirrored", origin: "follower:abc:7"))
    let again = try log.record(.init(severity: .error, source: "follower", stateCode: "peer_lost", reasonCode: "peer_lost",
        guidanceCode: "peer_lost", message: "mirrored", origin: "follower:abc:7"))
    check(mirrored.id == again.id && log.feed().incidents.count == 4, "A14 a record with the same origin is added once")

    refuses("A15 a code with spaces is refused") {
        _ = try log.record(.init(severity: .info, source: "has space", stateCode: .sessionFailed, message: "x"))
    }
    let long = try log.record(.init(severity: .info, source: "leader", stateCode: .sessionFailed,
                                    message: String(repeating: "é", count: 2000)))
    check(long.message.utf8.count <= ClusterIncidentLog.maximumMessageBytes && long.message.hasSuffix("..."),
          "A16 a long message is bounded at a character boundary")

    for index in 0..<230 {
        _ = try log.record(.init(severity: .info, source: "leader", stateCode: .sessionFailed, message: "ring \(index)"))
    }
    let ring = log.feed()
    check(ring.incidents.count == ClusterIncidentLog.maximumIncidents && ring.incidents.last?.seq == 235
          && ring.incidents.first?.seq == 36, "A17 the ring keeps the last 200 and the sequence keeps counting")

    // Concurrent writers in one process.
    let group = DispatchGroup()
    for _ in 0..<8 {
        group.enter()
        DispatchQueue.global().async {
            for _ in 0..<5 { _ = try? ClusterIncidentLog(file: file).record(.init(severity: .info, source: "leader",
                stateCode: .sessionFailed, message: "concurrent")) }
            group.leave()
        }
    }
    group.wait()
    let after = log.feed()
    check(after.latestSeq == 275 && Set(after.incidents.map(\.seq)).count == after.incidents.count,
          "A18 forty concurrent records: no sequence lost or repeated")

    // A corrupt file never blocks; the next record moves it aside and starts a new epoch.
    try Data("{not json".utf8).write(to: file)
    let corrupt = log.feed()
    check(corrupt.incidents.isEmpty && corrupt.loadError != nil, "A19 a corrupt log reads as empty with its error named")
    let fresh = try log.record(.init(severity: .error, source: "leader", stateCode: .activationLaunchFailed, message: "after corruption"))
    check(fresh.seq == 1 && log.feed().epoch != epoch, "A20 the next record starts a new epoch at seq 1")
    check(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().appendingPathComponent("incidents.corrupt.json").path),
          "A21 the corrupt file is kept aside for whoever investigates")

    // The file keeps oMLX's field names.
    _ = try log.record(.init(severity: .error, source: "leader", stateCode: .activationLaunchFailed,
        explanation: ClusterFailureClassifier.classify(message: "Native key relay deadline expired")))
    let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
    check(["\"state_code\"", "\"guidance_code\"", "\"reason_code\"", "\"next_seq\"", "\"schema_version\" : 1"].allSatisfy(text.contains),
          "A22 the file uses the oMLX schema names (plus reason_code)")
}

// MARK: B. Classifier and guidance

func classifierChecks() {
    let cases: [(String, [String], ClusterFailureReason)] = [
        ("Owner refused: darkbloom-orphan-wired-v1 role=owner decision=refused", [], .orphanedWiredMemory),
        ("Unresolved native ownership journal: an earlier cluster session's owner ended before its worker was seen to exit.", [], .deviceBusy),
        ("Cannot inspect the provider instance lock", [], .localProviderRunning),
        ("GPT-OSS stage load exceeds the allocator limit: needs 9 of 8 bytes", [], .memoryGateRefused),
        ("The follower member did not connect over the link control channel (is `darkbloom cluster link-follower` running on the other Mac?)", [], .followerNotConnected),
        // The plain wording of the one-command path keeps the classifier's phrase (A/B3 of the fix list).
        ("The other Mac did not answer over the cable. Make sure it is on; it rejoins by itself. (The follower member did not connect over the link control channel.)", [], .followerNotConnected),
        ("Darkbloom changed on this Mac since the cluster was set up: run `darkbloom cluster` again; it sets up again by itself. (The installed worker's runtime description differs from the saved capability.)", [], .workerRuntimeMismatch),
        ("Native key relay deadline expired", [], .bootstrapStalled),
        ("Installed executable bytes differ from the expected binary SHA-256", [], .workerRuntimeMismatch),
        ("Unsupported worker protocol version", [], .versionMismatch),
        ("Resident identity differs", [], .modelIdentityMismatch),
        ("Installed matrix changed", [], .planChanged),
        ("Lease renewal refused", [], .rankLeaseExpired),
        ("DistributedLocalServerError: bindFailed", [], .listenerFailed),
        // A generic error with a specific cause in an owner's diagnostics.
        ("Native owner did not establish bilateral readiness", ["noise\nssh: connect to host h port 22: Connection refused\n"], .peerUnreachable),
        ("Native owner did not establish bilateral readiness", ["Permission denied (publickey,password)."], .sshTrust),
        ("Native owner did not establish bilateral readiness", ["Host key verification failed."], .sshTrust),
        ("Worker startup exhausted its deadline", [], .startupTimedOut),
        ("The serving session stopped without being asked to", ["rank 1 ended: its owner exited with status 75"], .collectiveStall),
        ("The serving session stopped without being asked to", ["rank 1 ended: its owner exited with status 1"], .peerLost),
        ("Native owner did not establish bilateral readiness", ["darkbloom-worker-exit-v1 rank=0 termination=exited(75)"], .collectiveStall),
        // A link follower's refusal: the leader's own error is only that the link closed.
        ("closed", ["rank 1 follower refused the open: follower is serving another session"], .modelBusy),
        ("closed", ["rank 1 follower refused the open: bootstrap profile differs from this member's selection"], .planChanged),
        ("closed", ["rank 1 follower refused the open: open refused: GPT-OSS stage load exceeds the allocator limit: needs 9 of 8 bytes"], .memoryGateRefused),
        ("closed", ["rank 1 follower refused the open: follower is stopping"], .launchInterrupted),
        ("Native owner did not establish bilateral readiness",
         ["darkbloom-worker-exit-v1 rank=0 termination=signalled(6)\ndarkbloom-worker-tail-v1 GPT-OSS stage load exceeds the allocator limit: needs 9 of 8 bytes"], .memoryGateRefused),
        // The owner's oMLX launch failures (paraphrased failure modes, notes/03 section 9).
        ("JACCL requires a full RDMA connectivity matrix", [], .linkNotReady),
        ("worker exited while its Mac remained reachable", [], .peerLost),
        ("remote rank kill failed with status 255", [], .cleanupUnresolved),
        ("[jaccl] mesh: work completion error status=1", [], .rdmaCompletionError),
        ("collective_stall after 30001 ms in all_reduce", [], .collectiveStall),
        ("peer_lost: rank 1 stopped answering", [], .peerLost),
        ("model identity differs between the ranks", [], .modelIdentityMismatch),
        ("the model directory is missing on the remote Mac", [], .modelMissing),
        ("ImportError: the remote ran older code", [], .workerRuntimeMismatch),
        ("distributed decoding with MTP is not supported", [], .unsupportedMode),
        ("native tensor parallel cannot shard this model's control flow", [], .unsupportedMode),
        ("an IPv6 link-local scoped address could not be parsed", [], .addressUnusable),
        ("load-peak guard: 163.1 GiB over 162.5 GiB", [], .memoryGateRefused),
        ("rank 0 answered 404 then connection reset by peer", [], .peerLost),
        ("the engine pool did not activate the approved plan", [], .planChanged),
        ("cache materializer unavailable for this model", [], .runtimeError),
        ("There is no Stream(cpu, 2) in current thread", [], .runtimeError),
        ("launcher terminated with -15", [], .workerCrashed),
        ("topology change refused while a request is being served", [], .modelBusy),
        // A request that failed on the pair names its cause (S24): the pair's own line, or the worker's tail.
        ("The serving session stopped without being asked to (session quarantined); rank 0 ended: its owner exited with status 0",
         ["request 1c3269d9 failed on the pair: Rank 0 reported failure: runtimeError"], .requestFailed),
        ("The serving session stopped without being asked to (session quarantined)",
         ["darkbloom-worker-fail-v1 rank=1 event=failed:runtimeError\ndarkbloom-worker-tail-v1 Speculative window produced non-finite logits"], .requestFailed),
    ]
    for (index, item) in cases.enumerated() {
        let result = ClusterFailureClassifier.classify(.init(error: item.0, diagnostics: item.1))
        check(result.reason == item.2, "B\(index + 1) \(item.2.rawValue): \(item.0.prefix(60))\(result.reason == item.2 ? "" : " -> got \(result.reason.rawValue) (\(result.rule ?? "no rule"))")")
    }
    let withLine = ClusterFailureClassifier.classify(.init(error: "Native owner did not establish bilateral readiness",
        diagnostics: ["first\nssh: connect to host h port 22: Connection refused\nlast"]))
    check(withLine.message.contains("Connection refused"), "B-line the matching diagnostic line is kept in the message")
    let unknown = ClusterFailureClassifier.classify(message: "something nobody wrote a rule for")
    check(unknown.reason == .unclassified && unknown.guidance.code == "unknown_failure", "B-fallback an unmatched error is unclassified with the generic guidance")
    check(ClusterGuidance.explain(nil).code == "unknown_failure" && ClusterGuidance.explain("").code == "unknown_failure",
          "B-explain explain() never returns nothing")
    let everyReason = ClusterFailureReason.allCases.allSatisfy { !ClusterGuidance.guidance(for: $0).steps.isEmpty }
    check(everyReason, "B-guidance every reason has guidance with steps")
    let codes = Set(ClusterFailureReason.allCases.map { ClusterGuidance.guidance(for: $0).code })
    for code in codes { check(ClusterGuidance.guidance(code: code) != nil, "B-code \(code) resolves back to its guidance") }
    // Stable machine codes: these strings are recorded in incidents and read by the owner's tools.
    let stable = ["host_key_unknown", "host_identity_changed", "no_matching_host_key", "login_rejected", "peer_unreachable",
                  "peer_timeout", "model_stage_incomplete", "plan_changed", "version_mismatch", "address_unresolved",
                  "worker_runtime_unverified", "unknown_failure"]
    check(stable.allSatisfy { ClusterGuidance.guidance(code: $0) != nil }, "B-stable the oMLX guidance codes are kept")
    // Owner gates: no SSH set-up and no network settings in anything a user is told to do.
    let allGuidance = ClusterFailureReason.allCases.map { ClusterGuidance.guidance(for: $0) }
        + stable.compactMap { ClusterGuidance.guidance(code: $0) }
    let forbidden = ["ssh-copy-id", "ssh-keygen", "ssh-keyscan", "authorized_keys", "public key", "known_hosts", "--fix", "sudo",
                     "ipv4 address", "static", "network settings >", "internet sharing", "10.0.0."]
    for g in allGuidance {
        let text = ([g.title, g.explanation] + g.steps + [g.command ?? ""]).joined(separator: " ").lowercased()
        let hit = forbidden.filter { text.contains($0) }
        check(hit.isEmpty, "B-gate \(g.code) asks for no SSH set-up or network setting\(hit.isEmpty ? "" : ": \(hit)")")
    }
    for g in ["host_key_unknown", "host_identity_changed", "no_matching_host_key", "login_rejected"].compactMap({ ClusterGuidance.guidance(code: $0) }) {
        check(g.steps.first?.contains("darkbloom cluster") == true, "B-gate \(g.code) leads with the SSH-free pairing")
    }
}

// MARK: C. Pair telemetry

func telemetryChecks() throws {
    let file = scratch.appendingPathComponent("home-c/.darkbloom/cluster/pair-telemetry.json")
    let log = ClusterPairTelemetryLog(file: file, sessionID: "session-1", capacity: 4)
    func record(_ index: Int, ttft: Double, decode: Double, drafted: Int?, accepted: Int?, cached: Int = 0,
                outcome: String = "stop") -> ClusterPairRequestTelemetry {
        .init(requestID: "r\(index)", finishedAt: Double(index), modelID: "m", mode: "phase_split_mtp_v1", cut: "0-16|16-32",
              promptTokens: 100, cachedTokens: cached, completionTokens: 64, firstTokenMilliseconds: ttft,
              decodeTokensPerSecond: decode, handoffMilliseconds: 80, handoffBytes: 1_000_000, mtpDrafted: drafted,
              mtpAccepted: accepted, outcome: outcome)
    }
    let single = record(0, ttft: 100, decode: 50, drafted: 90, accepted: 70)
    check(single.mtpAcceptance == 0.7778, "C1 MTP acceptance is accepted over drafted, four places")
    log.record(record(1, ttft: 300, decode: 40, drafted: 100, accepted: 80))
    log.record(record(2, ttft: 100, decode: 60, drafted: 100, accepted: 60, cached: 90))
    log.record(record(3, ttft: 200, decode: 50, drafted: nil, accepted: nil))
    let summary = log.summary
    check(summary.requests == 3 && summary.medianFirstTokenMilliseconds == 200 && summary.medianDecodeTokensPerSecond == 50,
          "C2 medians over completed requests")
    check(summary.mtpAcceptance == 0.7 && summary.cachedTokens == 90 && summary.requestsWithCacheHit == 1,
          "C3 MTP acceptance sums over drafting requests; cached tokens counted")
    log.record(record(4, ttft: 1, decode: 1, drafted: nil, accepted: nil, outcome: "engine_error"))
    log.record(record(5, ttft: 1, decode: 1, drafted: nil, accepted: nil))
    check(log.recent.map(\.requestID) == ["r2", "r3", "r4", "r5"], "C4 the log keeps its last capacity records")
    check(log.summary.completed == 3 && log.writeFailures == 0, "C5 a failed request is not completed; every write succeeded")
    let read = ClusterPairTelemetryLog.read(file)
    check(read?.records.count == 4 && read?.sessionID == "session-1" && read?.summary == log.summary, "C6 the file reads back")
    var info = stat()
    check(stat(file.path, &info) == 0 && info.st_mode & 0o777 == 0o600, "C7 the telemetry file is owner-only")
    let snapshot = ClusterObservabilitySnapshot.read(homeDirectory: scratch.appendingPathComponent("home-c"))
    check(snapshot.telemetry?.recent.first?.requestID == "r5" && snapshot.incidents == nil && snapshot.followers == nil,
          "C8 the status snapshot shows the newest request first and no absent section")
    check(snapshot.lines.contains { $0.contains("phase_split_mtp_v1 cut 0-16|16-32") && $0.contains("hand-off 80.0 ms") },
          "C9 status lines name mode, cut and hand-off")
    // Speed records from served requests: cold completed requests only, kept across sessions, with their route.
    let history = ClusterServedSpeedFile.defaultFile(homeDirectory: scratch.appendingPathComponent("home-c"))
    check(ClusterServedSpeedFile.read(history)?.records.map(\.requestID) == ["r3", "r5"],
          "C10 every completed request that computed its whole prompt is a speed record (not cached, not failed, not the session's first on its route)")
    let next = ClusterPairTelemetryLog(file: file, sessionID: "session-2", capacity: 4)
    // The session's first request on the alone route warms that path: telemetry only.
    next.record(.init(requestID: "r6w", finishedAt: 6, modelID: "m", mode: "phase_split_mtp_v1", cut: "0-16|16-32",
        promptTokens: 40, cachedTokens: 0, completionTokens: 8, firstTokenMilliseconds: 900, decodeTokensPerSecond: 90,
        handoffMilliseconds: nil, handoffBytes: nil, mtpDrafted: nil, mtpAccepted: nil, outcome: "stop", route: "alone:second"))
    next.record(.init(requestID: "r6", finishedAt: 6, modelID: "m", mode: "phase_split_mtp_v1", cut: "0-16|16-32",
        promptTokens: 40, cachedTokens: 0, completionTokens: 8, firstTokenMilliseconds: 30, decodeTokensPerSecond: 90,
        handoffMilliseconds: nil, handoffBytes: nil, mtpDrafted: nil, mtpAccepted: nil, outcome: "stop",
        route: "alone:second", routeReason: "second alone is predicted 30% faster than the pair"))
    let kept = ClusterServedSpeedFile.read(history)
    check(kept?.records.map(\.requestID) == ["r3", "r5", "r6"] && kept?.records.last?.route == "alone:second"
            && ClusterPairTelemetryLog.read(file)?.records.map(\.requestID) == ["r6w", "r6"],
          "C11 speed records outlive the serving session; the session's telemetry starts anew")
    check(stat(history.path, &info) == 0 && info.st_mode & 0o777 == 0o600, "C12 the speed records file is owner-only")
    var many: [ClusterPairRequestTelemetry] = []
    for index in 0..<40 {
        many = ClusterServedSpeedFile.adding(.init(requestID: "x\(index)", finishedAt: Double(index), modelID: "m", mode: "pipeline_v1",
            cut: "0-1|1-2", promptTokens: 10, cachedTokens: 0, completionTokens: 2, firstTokenMilliseconds: 1,
            decodeTokensPerSecond: 1, handoffMilliseconds: nil, handoffBytes: nil, mtpDrafted: nil, mtpAccepted: nil,
            outcome: "length"), to: many)
    }
    check(many.count == ClusterServedSpeedFile.keptPerRoute && many.first?.requestID == "x8", "C13 speed records are bounded per setup and route")
    let routed = ClusterObservabilitySnapshot.read(homeDirectory: scratch.appendingPathComponent("home-c"))
    check(routed.lines.contains { $0.contains("route alone:second") } && routed.lines.contains { $0.contains("route: second alone is predicted") }
            && routed.lines.contains { $0.hasPrefix("Speed records from served requests") && $0.contains("alone:second 1") && $0.contains("pair 2") },
          "C14 status shows each request's route and why, and the speed records by route")
    // The members' rank order travels with each record, and a different order is a different setup.
    func ranked(_ id: String, _ ranks: [String]?) -> ClusterPairRequestTelemetry {
        .init(requestID: id, finishedAt: 1, modelID: "m", mode: "phase_split_mtp_v1", cut: "0-4|4-32", promptTokens: 10,
              cachedTokens: 0, completionTokens: 2, firstTokenMilliseconds: 1, decodeTokensPerSecond: 1, handoffMilliseconds: nil,
              handoffBytes: nil, mtpDrafted: nil, mtpAccepted: nil, outcome: "stop", ranks: ranks)
    }
    var orders: [ClusterPairRequestTelemetry] = []
    for index in 0..<40 { orders = ClusterServedSpeedFile.adding(ranked("o\(index)", index % 2 == 0 ? ["a", "b"] : ["b", "a"]), to: orders) }
    let encoded = try? JSONEncoder().encode(ranked("e", ["a", "b"]))
    check(orders.count == 40 && encoded.flatMap { try? JSONDecoder().decode(ClusterPairRequestTelemetry.self, from: $0) }?.ranks == ["a", "b"]
            && ranked("bad", ["", "b"]).ranks == nil,
          "C15 a speed record names its members in rank order; another order is another setup; an empty label is dropped")
}

// MARK: D. Worker protocol

let epochD = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
let requestD = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!
let identityD = ClusterWorkerIdentity(membershipEpoch: epochD, modelID: "example-model",
    artifactSHA256: String(repeating: "a", count: 64), configurationSHA256: String(repeating: "b", count: 64),
    peers: [.init(id: "first", buildSHA256: String(repeating: "c", count: 64)),
            .init(id: "second", buildSHA256: String(repeating: "d", count: 64))])
let profileD = ClusterWorkerProfile(id: "greedy-text", vocabularySize: 512,
    maximumPromptTokens: 16, maximumOutputTokens: 4, maximumChunkTokens: 8, maximumContextTokens: 20)
let planD = String(repeating: "e", count: 64)

struct Conversation {
    var session: ClusterWorkerSession
    var commands: UInt64 = 0, events: UInt64 = 0
    let rank: Int
    init(rank: Int) throws {
        self.rank = rank
        session = try .init(identity: identityD, rank: rank, profile: profileD, executionPlanSHA256: planD)
        try event(.ready(.init(identity: identityD, rank: rank, profile: profileD, executionPlanSHA256: planD,
                               requestCapacityBytes: 1024)), request: nil)
        try command(.reserve(.init(profileID: profileD.id, promptTokenIDs: [1, 2, 3], stopTokenIDs: [], outputCount: 2,
            chunkSize: 2, deadlineUptimeNanoseconds: 1000, capacityLimitBytes: 900, sampling: nil)))
        try event(.admitted(reservedBytes: 100))
        try command(.start)
    }
    mutating func command(_ value: ClusterWorkerCommand) throws {
        try session.accept(.init(membershipEpoch: epochD, sequence: commands, requestID: requestD, command: value), now: 10)
        commands += 1
    }
    mutating func event(_ value: ClusterWorkerEvent, request: UUID? = requestD) throws {
        try session.accept(.init(membershipEpoch: epochD, sequence: events, requestID: request, event: value), now: 10)
        events += 1
    }
}

func protocolChecks() throws {
    let telemetry = ClusterWorkerRequestTelemetry(handoffNanoseconds: 81_000_000, handoffBytes: 80_507_332,
                                                  mtpDrafted: 120, mtpAccepted: 93)
    let frame = ClusterWorkerEventFrame(membershipEpoch: epochD, sequence: 7, requestID: requestD, event: .requestTelemetry(telemetry))
    let bytes = try ClusterWorkerCodec.encode(frame)
    check(try ClusterWorkerCodec.decodeEvent(bytes) == frame, "D1 request telemetry round-trips through the event codec")
    let partial = ClusterWorkerEventFrame(membershipEpoch: epochD, sequence: 8, requestID: requestD,
                                          event: .requestTelemetry(.init(handoffNanoseconds: 5)))
    check(try ClusterWorkerCodec.decodeEvent(ClusterWorkerCodec.encode(partial)) == partial, "D2 absent fields stay absent")
    refuses("D3 empty telemetry is refused") { _ = try ClusterWorkerCodec.encode(.init(membershipEpoch: epochD, sequence: 1,
        requestID: requestD, event: .requestTelemetry(.init()))) }
    refuses("D4 more accepted than drafted is refused") { _ = try ClusterWorkerCodec.encode(.init(membershipEpoch: epochD, sequence: 1,
        requestID: requestD, event: .requestTelemetry(.init(mtpDrafted: 3, mtpAccepted: 4)))) }
    refuses("D5 telemetry without a request ID is refused") { _ = try ClusterWorkerCodec.encode(.init(membershipEpoch: epochD,
        sequence: 1, requestID: nil, event: .requestTelemetry(telemetry))) }
    let unknown = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\"handoffBytes\"", with: "\"handoffBites\"")
    refuses("D6 an unknown telemetry field is refused") { _ = try ClusterWorkerCodec.decodeEvent(Data(unknown.utf8)) }

    // Rank 1: telemetry after its prompt cache report, once, before finished.
    var rank1 = try Conversation(rank: 1)
    try rank1.event(.promptCache(reusedTokens: 1, storedFrontiers: [2]))
    try rank1.event(.requestTelemetry(telemetry))
    refuses("D7 a second telemetry event is refused") { var copy = rank1; try copy.event(.requestTelemetry(telemetry)) }
    try rank1.event(.finished(.length))
    try rank1.event(.retired(.clean))
    check(rank1.session.activeRequestID == nil && !rank1.session.protocolFailed, "D8 rank 1: cache, telemetry, finish, retire")
    var reversed = try Conversation(rank: 1)
    try reversed.event(.requestTelemetry(telemetry))
    refuses("D9 a prompt cache report after telemetry is refused") { try reversed.event(.promptCache(reusedTokens: 1, storedFrontiers: [])) }
    // Rank 0: only after its first committed token and decision.
    var rank0 = try Conversation(rank: 0)
    refuses("D10 rank 0 telemetry before any token is refused") { var copy = rank0; try copy.event(.requestTelemetry(telemetry)) }
    try rank0.event(.committedToken(ordinal: 0, tokenID: 5, committedTokens: 3))
    try rank0.command(.tokenDecision(ordinal: 0, decision: .proceed))
    try rank0.event(.committedToken(ordinal: 1, tokenID: 6, committedTokens: 4))
    try rank0.command(.tokenDecision(ordinal: 1, decision: .proceed))
    try rank0.event(.requestTelemetry(.init(handoffNanoseconds: 70_000_000)))
    try rank0.event(.finished(.length))
    try rank0.event(.retired(.clean))
    check(!rank0.session.protocolFailed, "D11 rank 0: tokens, telemetry, finish, retire")
}

// MARK: E. Status mirror

final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ClusterLinkControlMessage] = []
    var connected = true
    func append(_ value: ClusterLinkControlMessage) { lock.withLock { values.append(value) } }
    var messages: [ClusterLinkControlMessage] { lock.withLock { values } }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 1_000
    var now: Double { lock.withLock { value } }
    func advance(_ seconds: Double) { lock.withLock { value += seconds } }
}

func statusChecks() throws {
    let epoch = UUID()
    let summary = ClusterLinkIncidentSummary(seq: 3, ts: 10, severity: "error", stateCode: "peer_lost", reasonCode: "peer_lost",
                                              guidanceCode: "peer_lost", message: "rank 1 ended")
    let mirror = ClusterLinkStatusMirror(epoch: epoch, rank: 1, state: .serving, modelID: "m", freeMemoryBytes: 10,
        wiredMemoryBytes: 20, linkReady: true, detail: "ok", sequence: 4, sentAt: 5, uptimeSeconds: 6, thermalState: "nominal",
        physicalMemoryBytes: 128, requestsServed: 9, incidentEpoch: "0123456789abcdef", incidents: [summary])
    let encoded = try JSONEncoder().encode(ClusterLinkControlMessage.status(mirror))
    check(try JSONDecoder().decode(ClusterLinkControlMessage.self, from: encoded) == .status(mirror), "E1 the extended status round-trips")
    // An older peer's status (no S24 fields) still decodes, and an older
    // decoder ignores the new fields (synthesized Codable skips unknown keys).
    let old = #"{"kind":"status","status":{"detail":"","epoch":"\#(epoch.uuidString)","linkReady":true,"rank":1,"state":"idle"}}"#
    if case .status(let value) = try JSONDecoder().decode(ClusterLinkControlMessage.self, from: Data(old.utf8)) {
        check(value.sequence == nil && value.incidents == nil && value.state == .idle, "E2 an older peer's status decodes")
    } else { check(false, "E2 an older peer's status decodes") }

    let clock = Clock()
    let board = ClusterLinkStatusBoard(staleAfterSeconds: 10, clock: { clock.now })
    var status = mirror
    check(board.receive(status).contains(.firstSeen(rank: 1)), "E3 first status: first seen")
    let firstIncidents = board.receive(status)
    check(firstIncidents.isEmpty, "E4 a repeated sequence is ignored")
    status.sequence = 5; status.state = .failed; status.detail = "worker ended"
    let changed = board.receive(status)
    check(changed.contains(.stateChanged(rank: 1, from: .serving, to: .failed, detail: "worker ended")), "E5 a state change is reported")
    check(!changed.contains { if case .incidents = $0 { return true }; return false }, "E6 incidents already seen are not reported again")
    status.sequence = 6
    status.incidents = [summary, .init(seq: 4, ts: 11, severity: "error", stateCode: "session_failed", reasonCode: nil,
                                       guidanceCode: nil, message: "x")]
    let fresh = board.receive(status)
    check(fresh.contains { if case .incidents(1, _, let list) = $0 { return list.map(\.seq) == [4] }; return false },
          "E7 only the new incident is reported")
    clock.advance(11)
    check(board.checkStaleness() == [.becameStale(rank: 1, silentSeconds: 11)] && board.checkStaleness().isEmpty,
          "E8 silence past the limit is reported once")
    check(board.entries().first?.stale == true, "E9 the entry reads as stale")
    status.sequence = 7
    check(board.receive(status).contains(.recovered(rank: 1)), "E10 a status after silence is a recovery")
    var restarted = status
    restarted.sequence = 1; restarted.uptimeSeconds = 1
    board.receive(restarted)
    check(board.entries().first?.status.sequence == 1, "E11 a restarted sender (sequence and uptime reset) is accepted")

    // The publisher sends only while connected, with increasing sequences.
    let captured = Captured()
    let publisher = ClusterLinkStatusPublisher(epoch: epoch, rank: 1, interval: .milliseconds(100),
        send: { captured.append($0) }, isConnected: { captured.connected },
        snapshot: { .init(state: .ready, modelID: "m", requestsServed: 2, incidentEpoch: "e", incidents: [summary]) },
        sample: { .init(freeBytes: 1, wiredBytes: 2, physicalBytes: 3, thermalState: "nominal") })
    publisher.start()
    usleep(450_000)
    captured.connected = false
    let sentWhileConnected = captured.messages.count
    usleep(350_000)
    publisher.stop()
    let sequences = captured.messages.compactMap { message -> UInt64? in if case .status(let s) = message { return s.sequence }; return nil }
    check(sentWhileConnected >= 3 && captured.messages.count == sentWhileConnected, "E12 sent every interval while connected, nothing after")
    check(zip(sequences, sequences.dropFirst()).allSatisfy { $0 < $1 }, "E13 sequences increase")
    check(publisher.counters.skipped >= 2, "E14 ticks while disconnected are counted as skipped")

    // A real edge on loopback: the follower's publisher, the leader's board.
    let secret = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    let edgeID = UUID()
    let key = try ClusterLinkControlKey.qualification(secret: secret, epoch: epoch, edgeID: edgeID)
    var limits = ClusterLinkControlLimits()
    limits.heartbeatInterval = .milliseconds(200); limits.silenceTimeout = .seconds(2)
    let leaderBoard = ClusterLinkStatusBoard()
    let listener = try ClusterLinkControlListener(configuration: .init(interface: "lo0", port: 0, policy: .loopbackForTests,
        edges: [try ClusterLinkControlEdge(edgeID: edgeID, epoch: epoch, key: key, peerAddress: .loopback, limits: limits)])) { event, _ in
        if case .message(_, _, .status(let value)) = event { leaderBoard.receive(value) }
    }
    let port = try listener.start()
    let client = try ClusterLinkControlClient(configuration: .init(interface: "lo0", port: port, policy: .loopbackForTests,
        edge: try ClusterLinkControlEdge(edgeID: edgeID, epoch: epoch, key: key, peerAddress: .loopback, limits: limits))) { _, _ in }
    client.start()
    let connected = client.peer.waitUntilConnected(timeout: .seconds(5))
    let follower = ClusterLinkStatusPublisher(peer: client.peer, epoch: epoch, rank: 1, interval: .milliseconds(200)) {
        .init(state: .serving, modelID: "loopback-model", requestsServed: 3, incidentEpoch: "e", incidents: [summary])
    }
    follower.start()
    var arrived: ClusterLinkStatusBoard.Entry?
    for _ in 0..<50 where arrived == nil { usleep(100_000); arrived = leaderBoard.entries().first }
    follower.stop(); client.stop(); listener.stop()
    check(connected && arrived?.status.modelID == "loopback-model" && arrived?.status.state == .serving
          && arrived?.status.wiredMemoryBytes != nil && arrived?.status.incidents?.first?.seq == 3,
          "E15 over a real loopback edge the leader's board holds the follower's status (memory, incidents)")

    // The leader's file and the snapshot `cluster status` reads.
    let home = scratch.appendingPathComponent("home-e")
    let file = ClusterLinkStatusBoardFile.defaultFile(homeDirectory: home)
    try ClusterLinkStatusBoardFile(updatedAt: clock.now, entries: board.entries()).write(to: file)
    let snapshot = ClusterObservabilitySnapshot.read(homeDirectory: home, now: clock.now + 30)
    check(snapshot.followers?.entries.first?.stale == true && snapshot.followers?.entries.first?.ageSeconds == 30,
          "E16 the snapshot recomputes age and staleness from the file")
    check(snapshot.lines.contains { $0.contains("Rank 1 (mirrored over the link)") && $0.contains("STALE") }, "E17 status lines show it")
}

// MARK: F. A planned stop is not an incident

func stopCauseChecks() {
    // The leader was asked to stop (a drain, `darkbloom stop`, Ctrl-C): its own workers' exit that follows
    // must not turn the fence the other Mac reads into "a rank was lost".
    let planned = ClusterSessionStopCause.fenceCause(unrequested: true, requestedFirst: true, lastFailure: nil)
    check(planned == ClusterSessionStopCause.requested, "F1 a stop asked for first keeps the requested cause when its workers' exit follows")
    check(ClusterSessionStopCause.fenceCause(unrequested: false, requestedFirst: true, lastFailure: nil) == ClusterSessionStopCause.requested,
          "F2 a requested stop fences with the requested cause")
    let lost = ClusterSessionStopCause.fenceCause(unrequested: true, requestedFirst: false, lastFailure: nil)
    check(lost == "the session stopped: a rank was lost", "F3 a stop nobody asked for still says a rank was lost")
    check(ClusterSessionStopCause.fenceCause(unrequested: true, requestedFirst: false, lastFailure: "request failed: x")
          == "the session stopped: request failed: x", "F4 and names the request failure when there is one")
    // The follower reads the fence its link endpoint reports ("leader fenced: <cause>").
    check(ClusterSessionStopCause.isRequestedStop(fenceReason: "leader fenced: " + planned), "F5 the follower reads a requested stop as planned")
    check(!ClusterSessionStopCause.isRequestedStop(fenceReason: "leader fenced: " + lost), "F6 a lost rank is not read as planned")
    check(!ClusterSessionStopCause.isRequestedStop(fenceReason: "leader fenced"), "F7 a fence without a cause is not read as planned")
    check(!ClusterSessionStopCause.isRequestedStop(fenceReason: "leader replay or gap"), "F8 a protocol fence is not read as planned")
    check(!ClusterSessionStopCause.isRequestedStop(fenceReason: "leader fenced: the session is stopping because x"),
          "F9 only the exact requested cause is planned")
}

do {
    try incidentChecks()
    classifierChecks()
    try telemetryChecks()
    try protocolChecks()
    try statusChecks()
    stopCauseChecks()
} catch {
    failures += 1
    output.write(Data("FAIL unexpected error: \(error)\n".utf8))
}
try? FileManager.default.removeItem(at: scratch)
output.write(Data("SUMMARY observability checks: \(passes) passed, \(failures) failed\n".utf8))
exit(failures == 0 ? 0 : 1)
