import CryptoKit
import Darwin
import DarkbloomClusterProtocol
import Foundation

/// Model-free stand-in for `darkbloom-cluster-worker`, used only by the pair
/// driver's tests. It accepts the worker's exact command line and speaks the
/// worker protocol through the library's own codec and session, so the driver
/// is exercised through its real launch path. How it behaves is read from
/// `behavior.json` beside the executable; nothing reaches it through the
/// environment, because the driver launches a worker with a fixed one. It
/// serves one request at a time, or several with the batch lanes the driver
/// names, in every mode it describes, and sends each committed token's
/// logprobs when a request asks for them.
@main enum PairCheckFakeWorker {
    struct Behavior: Decodable {
        var mode = "ok"
        /// Added to this process's uptime, as if it ran on another Mac.
        var clockSkewNanoseconds: Int64 = 0
        /// A rank whose number is in `evidenceDeltaRanks` records this much
        /// added to its last token.
        var evidenceTokenDelta = 0
        var evidenceDeltaRanks = [1]
        var firstToken = 100
        /// Describe a runtime that runs the pipeline only, as an older worker would.
        var pipelineOnly = false
        /// From this reservation of the run on (counting from 1), every logprob rank 0 sends is one ulp lower.
        var logprobDriftFromReservation: Int?

        init() {}
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            mode = try values.decodeIfPresent(String.self, forKey: .mode) ?? "ok"
            clockSkewNanoseconds = try values.decodeIfPresent(Int64.self, forKey: .clockSkewNanoseconds) ?? 0
            evidenceTokenDelta = try values.decodeIfPresent(Int.self, forKey: .evidenceTokenDelta) ?? 0
            evidenceDeltaRanks = try values.decodeIfPresent([Int].self, forKey: .evidenceDeltaRanks) ?? [1]
            firstToken = try values.decodeIfPresent(Int.self, forKey: .firstToken) ?? 100
            pipelineOnly = try values.decodeIfPresent(Bool.self, forKey: .pipelineOnly) ?? false
            logprobDriftFromReservation = try values.decodeIfPresent(Int.self, forKey: .logprobDriftFromReservation)
        }
        enum CodingKeys: String, CodingKey {
            case mode, clockSkewNanoseconds, evidenceTokenDelta, evidenceDeltaRanks, firstToken, pipelineOnly
            case logprobDriftFromReservation
        }
    }

    /// The name the guarded JACCL reads; the driver looks for it in a worker.
    static let progressGuardName = "JACCL_PROGRESS_TIMEOUT_MS"

    static let profile = ClusterWorkerProfile(id: "registered_qwen35_9b_greedy_generation_v1", vocabularySize: 248_320,
        maximumPromptTokens: 8192, maximumOutputTokens: 128, maximumChunkTokens: 512, maximumContextTokens: 8320)
    static let artifact = String(repeating: "a", count: 64), configuration = String(repeating: "b", count: 64)

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func plan(cut: Int) -> String { hash("fake-plan-\(cut)") }
    static func stages(cut: Int) -> [String] { [hash("fake-stage0-\(cut)"), hash("fake-stage1-\(cut)")] }

    static func executableURL() -> URL {
        var capacity: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &capacity)
        var bytes = [CChar](repeating: 0, count: Int(capacity))
        _ = _NSGetExecutablePath(&bytes, &capacity)
        return URL(fileURLWithPath: String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let executable = executableURL()
        let behavior = (try? Data(contentsOf: executable.deletingLastPathComponent().appendingPathComponent("behavior.json")))
            .flatMap { try? JSONDecoder().decode(Behavior.self, from: $0) } ?? Behavior()
        func uptime() -> UInt64 {
            UInt64(bitPattern: Int64(bitPattern: DispatchTime.now().uptimeNanoseconds) + behavior.clockSkewNanoseconds)
        }
        if arguments == ["--uptime-nanoseconds"] { print(uptime()); exit(0) }
        if arguments.first == "--describe-runtime" { describe(arguments, executable: executable, pipelineOnly: behavior.pipelineOnly) }

        var fields: [String: String] = [:]
        guard arguments.count % 2 == 0 else { exit(64) }
        for index in stride(from: 0, to: arguments.count, by: 2) { fields[arguments[index]] = arguments[index + 1] }
        let environment = ProcessInfo.processInfo.environment
        guard let rank = fields["--rank"].flatMap(Int.init), (0...1).contains(rank),
              let cut = fields["--stage-cut"].flatMap(Int.init), [4, 8, 12, 16].contains(cut),
              let epoch = fields["--membership-epoch"].flatMap(UUID.init(uuidString:)),
              let deadline = fields["--deadline-uptime-nanoseconds"].flatMap(UInt64.init),
              let peer0 = fields["--peer0-id"], let build0 = fields["--peer0-build-sha256"],
              let peer1 = fields["--peer1-id"], let build1 = fields["--peer1-build-sha256"],
              fields["--model-id"] == "registered_qwen35_9b", fields["--model-dir"]?.hasPrefix("/") == true,
              fields["--artifact-sha256"] == artifact, fields["--configuration-sha256"] == configuration,
              let matrixPath = environment["JACCL_IBV_DEVICES"],
              let matrix = try? Data(contentsOf: URL(fileURLWithPath: matrixPath)) else { exit(64) }
        // What a real worker would refuse at startup: an unknown generation
        // mode, a qualification switch without the explicit test flag, and the
        // retired environment declaration of the mode.
        if let mode = fields["--generation-mode"], ClusterGenerationMode(rawValue: mode) == nil { exit(66) }
        if let flag = fields["--qualification-switches"], flag != "yes" { exit(66) }
        if environment["DARKBLOOM_CLUSTER_GENERATION_MODE"] != nil { exit(67) }
        if fields["--qualification-switches"] == nil,
           environment["DARKBLOOM_CLUSTER_TRANSPORT"] != nil || environment["DARKBLOOM_CLUSTER_QUALIFICATION_FAULT"] != nil
            || environment["DARKBLOOM_CLUSTER_STAGE_RESIDENCY"] != nil
            || environment["DARKBLOOM_CLUSTER_QUALIFICATION_TAMPER"] != nil { exit(67) }
        if let plane = fields["--data-plane"], plane != ClusterWorkerDataPlaneTrust.argument { exit(66) }
        let tampers = environment["DARKBLOOM_CLUSTER_QUALIFICATION_TAMPER"] != nil
        if tampers && fields["--data-plane"] == nil { exit(66) }
        // What a real worker would refuse: its own deadline on its own clock.
        let now = uptime()
        guard deadline > now, deadline - now <= 3_600_000_000_000 else { exit(65) }
        let run = URL(fileURLWithPath: matrixPath).deletingLastPathComponent()
        // Dispositions a launcher sets to "ignore" survive into the worker.
        let ignored = [SIGINT, SIGHUP, SIGTERM].map { number -> Bool in
            let previous = signal(number, SIG_IGN)
            let wasIgnored = unsafeBitCast(previous, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self)
            if !wasIgnored { signal(number, previous) }
            return wasIgnored
        }
        let observed: [String: Any] = ["arguments": arguments, "environment": environment,
            "progressTimeout": environment[progressGuardName] ?? "",
            "matrix": String(decoding: matrix, as: UTF8.self), "processID": Int(getpid()),
            "ignoresInterrupt": ignored[0], "ignoresHangup": ignored[1], "ignoresTerminate": ignored[2]]
        try? JSONSerialization.data(withJSONObject: observed, options: [.sortedKeys])
            .write(to: run.appendingPathComponent("observed.json"))
        // A driver must never signal a worker. If it does, this records it.
        signal(SIGTERM) { _ in
            let path = ProcessInfo.processInfo.environment["JACCL_IBV_DEVICES"].map {
                URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("signalled").path
            } ?? "/dev/null"
            close(open(path, O_WRONLY | O_CREAT, 0o600))
            _exit(143)
        }
        signal(SIGPIPE, SIG_IGN)

        switch behavior.mode {
        case "exit-before-ready": exit(7)
        case "never-ready":
            // Like a worker blocked in native initialization: deaf to its input,
            // ended only by the lifetime it was started with.
            while uptime() < deadline { usleep(20_000) }
            exit(124)
        default: break
        }

        // S16 stand-in: the credential is the first input line; its certificate
        // must verify, and the pin must name the other rank's identity (the
        // two fakes compare through the run root, as the real ones compare
        // signed hellos on the data plane). A wrong pin ends this rank before
        // readiness, and its peer, never confirmed, ends too.
        var dataPlane: ClusterWorkerDataPlane?
        var peerTampers = false
        if fields["--data-plane"] != nil {
            var line = Data(), byte: UInt8 = 0
            while byte != 10 {
                guard Darwin.read(STDIN_FILENO, &byte, 1) == 1, line.count < 4096 else { exit(75) }
                line.append(byte)
            }
            guard let trust = try? ClusterWorkerCodec.decodeDataPlaneTrust(line), trust.membershipEpoch == epoch,
                  trust.rank == rank, let worker = try? P256.Signing.PrivateKey(rawRepresentation: trust.workerSigningKey),
                  let member = try? P256.Signing.PublicKey(x963Representation: trust.memberIdentity),
                  let signature = try? P256.Signing.ECDSASignature(rawRepresentation: trust.workerCertificate) else { exit(76) }
            var message = Data("darkbloom/data-plane/worker-certificate/v1\0".utf8)
            message.append(withUnsafeBytes(of: epoch.uuid) { Data($0) }); message.append(UInt8(rank))
            message.append(worker.publicKey.x963Representation)
            guard member.isValidSignature(signature, for: message) else { exit(76) }
            // Both fakes run on one Mac in the tests: they meet in this user's
            // temporary directory, named by the epoch, and the last one out removes it.
            let meeting = FileManager.default.temporaryDirectory
                .appendingPathComponent("darkbloom-fake-data-plane-" + epoch.uuidString.lowercased())
            try? FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
            func file(_ name: String) -> URL { meeting.appendingPathComponent(name) }
            func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: file(name).path) }
            try? trust.memberIdentity.write(to: file("identity-rank\(rank)"))
            var other: Data?
            for _ in 0..<500 where other == nil {
                other = try? Data(contentsOf: file("identity-rank\(1 - rank)")); if other == nil || other!.count != 65 { other = nil; usleep(10_000) }
            }
            // No peer hello ever came (the peer died or never started): like the
            // real worker's failed key exchange, this rank ends by itself, status 1.
            guard let other else { exit(1) }
            guard other == trust.peerPin else { exit(1) } // peer not pinned: refused before any key
            // A tampering rank's first protected record will reach its peer.
            if tampers { try? Data([1]).write(to: file("tamper-rank\(rank)")) }
            try? Data([1]).write(to: file("confirmed-rank\(rank)"))
            var confirmed = false
            for _ in 0..<500 where !confirmed { confirmed = exists("confirmed-rank\(1 - rank)"); if !confirmed { usleep(10_000) } }
            guard confirmed else { exit(1) }
            peerTampers = exists("tamper-rank\(1 - rank)")
            try? Data([1]).write(to: file("done-rank\(rank)"))
            if exists("done-rank\(1 - rank)") { try? FileManager.default.removeItem(at: meeting) }
            let sorted = [trust.memberIdentity, other].sorted { $0.lexicographicallyPrecedes($1) }
            let transcript = SHA256.hash(data: withUnsafeBytes(of: epoch.uuid) { Data($0) } + sorted[0] + sorted[1])
            let edge = SHA256.hash(data: Data("edge".utf8) + sorted[0] + sorted[1])
            dataPlane = .init(protection: ClusterWorkerDataPlane.encrypted, peerVerified: true,
                transcriptSHA256: transcript.map { String(format: "%02x", $0) }.joined(),
                edgeID: edge.prefix(16).map { String(format: "%02x", $0) }.joined())
        }

        let identity = ClusterWorkerIdentity(membershipEpoch: epoch, modelID: "registered_qwen35_9b",
            artifactSHA256: artifact, configurationSHA256: configuration,
            peers: [.init(id: peer0, buildSHA256: build0), .init(id: peer1, buildSHA256: build1)])
        do {
            // One request at a time, or several at once with batch lanes (`DARKBLOOM_CLUSTER_BATCH_LANES`, each
            // request's events in the order `ClusterWorkerLaneSession` holds them to), as the real worker.
            let lanes = environment["DARKBLOOM_CLUSTER_BATCH_LANES"].flatMap(Int.init) ?? 1
            var single = lanes == 1
                ? try ClusterWorkerSession(identity: identity, rank: rank, profile: profile, executionPlanSHA256: plan(cut: cut)) : nil
            var laned = lanes > 1 ? try ClusterWorkerLaneSession(identity: identity, rank: rank, profile: profile,
                executionPlanSHA256: plan(cut: cut), lanes: lanes) : nil
            /// A reservation and how far it got; `number` counts every reservation of the run from 1.
            struct Held { let reservation: ClusterWorkerReservation; let number: Int; var selected = 0; var admittedNotStarted = false }
            var sequence: UInt64 = 0, held: [UUID: Held] = [:], reservations = 0
            func emit(_ event: ClusterWorkerEvent, _ id: UUID? = nil) throws {
                let frame = ClusterWorkerEventFrame(membershipEpoch: epoch, sequence: sequence, requestID: id, event: event)
                if single != nil { try single!.accept(frame, now: uptime()) } else { try laned!.accept(frame, now: uptime()) }
                try FileHandle.standardOutput.write(contentsOf: ClusterWorkerCodec.encode(frame)); sequence += 1
            }
            func tokens(_ request: ClusterWorkerReservation) -> [Int] {
                (0..<request.outputCount).map { behavior.firstToken + $0 }
            }
            // A token's logprob and its alternatives, when its request asks for them: the same at each ordinal for
            // every request, so a request in a wave sends what it sends alone; from the
            // `logprobDriftFromReservation`-th reservation on, one ulp lower, as a lane whose arithmetic drifted from
            // its request's alone while its tokens stayed the same.
            func logprobs(_ request: Held, ordinal: Int, token: Int) -> ClusterWorkerTokenLogprobs? {
                guard let count = request.reservation.sampling?.capturedLogprobs else { return nil }
                var value = -Float(ordinal + 1) / 16
                if let from = behavior.logprobDriftFromReservation, request.number >= from { value = value.nextDown }
                return .init(logprob: value, top: (0..<count).map { .init(tokenID: token + $0, logprob: value - Float($0)) })
            }
            func record(_ request: ClusterWorkerReservation, _ requestID: UUID) throws {
                guard let directory = fields["--evidence-directory"] else { return }
                var history = tokens(request)
                if behavior.evidenceDeltaRanks.contains(rank) { history[history.count - 1] += behavior.evidenceTokenDelta }
                let frames = (request.promptTokenIDs.count - 1) / request.chunkSize + request.outputCount
                var evidence: [String: Any] = [
                    "schema": "qwen_stage_generation_final_diagnostic_v1", "rank": rank,
                    "requestFingerprint": hash("fake-request-" + requestID.uuidString.lowercased()),
                    "profileFingerprint": hash("fake-profile"),
                    "execution": ["selectedTokenIDs": history, "completedFrames": frames,
                        "committedTokens": request.promptTokenIDs.count + request.outputCount - 1,
                        "finishReason": "length", "tokenChainSHA256": hash("fake-chain")],
                    "agreement": ["requestID": requestID.uuidString.lowercased(), "sourceConfigurationSHA256": configuration,
                        "artifactAggregateSHA256": artifact, "storageCommitmentSHA256": hash("fake-storage-\(cut)"),
                        "planFingerprint": plan(cut: cut), "stageFingerprints": stages(cut: cut),
                        "numericalPolicySHA256": hash("fake-arithmetic")],
                    "stateEntries": [["globalLayerIndex": rank == 0 ? 0 : cut, "component": "ssm", "shape": [1, 2],
                        "dtype": "float32", "byteCount": 8, "sha256": hash("fake-state-\(rank)")]],
                    "stageStateSHA256": hash("fake-stage-state-\(rank)"),
                ]
                if rank == 1 {
                    evidence["finalLogits"] = ["shape": [1, 8], "dtype": "bfloat16", "byteCount": 16,
                        "logicalBytesSHA256": hash("fake-row"), "values": [0.5, 1.5, -2.0, 9.0, 8.5, 0.0, -0.25, 3.0]]
                }
                try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent(requestID.uuidString.lowercased() + ".json"))
            }
            try emit(.ready(.init(identity: identity, rank: rank, profile: profile,
                executionPlanSHA256: plan(cut: cut), requestCapacityBytes: 1 << 20, dataPlane: dataPlane)))
            var decoder = ClusterWorkerLineDecoder(commandStream: true)
            while true {
                var buffer = [UInt8](repeating: 0, count: 65_536)
                let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                if count == 0 { break }
                if count < 0 { if errno == EINTR { continue }; exit(74) }
                for line in try decoder.append(Data(buffer.prefix(count))) {
                    guard case .command(let command) = try ClusterWorkerCodec.decodeControl(line) else { continue } // a rank-lease renewal
                    if single != nil { try single!.accept(command, now: uptime()) } else { try laned!.accept(command, now: uptime()) }
                    let id = command.requestID
                    switch command.command {
                    case .reserve(let value):
                        let current = uptime()
                        reservations += 1
                        // "refuse": every reservation, as a rank whose gate refuses
                        // for memory; "refuse-once": the first only.
                        if behavior.mode == "refuse" || (behavior.mode == "refuse-once" && reservations == 1) {
                            try emit(.refused(.capacity), id)
                        }
                        else if value.deadlineUptimeNanoseconds <= current || value.deadlineUptimeNanoseconds > deadline {
                            try emit(.refused(.deadline), id)
                        } else {
                            held[id!] = .init(reservation: value, number: reservations, admittedNotStarted: true)
                            try emit(.admitted(reservedBytes: 4096), id)
                        }
                    case .start:
                        held[id!]!.admittedNotStarted = false
                        if behavior.mode == "exit-on-start" { exit(9) }
                        if behavior.mode == "stall-on-start" { continue }
                        // The tampering rank waits on its peer, which refuses the
                        // record it cannot open: it fails the request and exits.
                        if tampers { continue }
                        if peerTampers { try emit(.failed(.runtimeError), id); exit(1) }
                        let request = held[id!]!
                        if rank == 1 {
                            try record(request.reservation, id!)
                            try emit(.finished(.length), id); try emit(.retired(.clean), id); held[id!] = nil
                        } else {
                            let token = tokens(request.reservation)[0]
                            try emit(.committedToken(ordinal: 0, tokenID: token, committedTokens: request.reservation.promptTokenIDs.count,
                                logprobs: logprobs(request, ordinal: 0, token: token)), id)
                            held[id!]!.selected = 1
                        }
                    case .tokenDecision(_, let decision):
                        let request = held[id!]!, selected = request.selected
                        if selected == request.reservation.outputCount || decision == .cleanStop {
                            try record(request.reservation, id!)
                            try emit(.finished(selected == request.reservation.outputCount ? .length : .clientStop), id)
                            try emit(.retired(.clean), id); held[id!] = nil
                        } else {
                            let token = tokens(request.reservation)[selected]
                            try emit(.committedToken(ordinal: selected, tokenID: token,
                                committedTokens: request.reservation.promptTokenIDs.count + selected,
                                logprobs: logprobs(request, ordinal: selected, token: token)), id)
                            held[id!]!.selected += 1
                        }
                    case .cancel:
                        // A cancel that crossed this request's own retirement changes nothing.
                        guard let id, let request = held[id] else { continue }
                        // A reservation that never started is given back and the
                        // worker serves on (the pair's other rank refused the
                        // request); so is a started lane, which retires alone
                        // while the others run on. Otherwise a real worker
                        // reports the failure, releases and exits.
                        if request.admittedNotStarted || laned != nil { held[id] = nil; try emit(.retired(.cancelled), id); continue }
                        try emit(.failed(.runtimeError), id); exit(1)
                    case .keepWarm(let ordinal):
                        try emit(.keptWarm(ordinal: ordinal, microseconds: 1))
                    case .shutdown:
                        try emit(.shutdownComplete); exit(0)
                    }
                }
            }
            // Input ended without shutdown: a real worker releases and exits 1.
            exit(1)
        } catch { exit(70) }
    }

    static func describe(_ arguments: [String], executable: URL, pipelineOnly: Bool) -> Never {
        guard arguments.count == 7, arguments[1] == "--config", arguments[3] == "--manifest",
              arguments[5] == "--expected-executable-sha256",
              FileManager.default.fileExists(atPath: arguments[2]), FileManager.default.fileExists(atPath: arguments[4]),
              let bytes = try? Data(contentsOf: executable),
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == arguments[6] else { exit(1) }
        do {
            let capability = try ClusterRuntimeCapability(runtimeBinarySHA256: arguments[6],
                adapterID: ClusterRuntimeAdapter.qwen35Dense.rawValue, adapterVersion: 1,
                runtimeModelID: "registered_qwen35_9b", artifactSHA256: artifact, configurationSHA256: configuration,
                manifestSHA256: String(repeating: "c", count: 64), profile: profile, profileFingerprint: hash("fake-profile"),
                partitions: [4, 8, 12, 16].map { cut in
                    .init(planSHA256: plan(cut: cut), stages: [
                        .init(rank: 0, sourceLayerStart: 0, sourceLayerEnd: cut, stagePlanSHA256: stages(cut: cut)[0],
                              constructionConfigurationSHA256: hash("fake-construction0-\(cut)")),
                        .init(rank: 1, sourceLayerStart: cut, sourceLayerEnd: 32, stagePlanSHA256: stages(cut: cut)[1],
                              constructionConfigurationSHA256: hash("fake-construction1-\(cut)")),
                    ])
                }, arithmeticPolicyID: "qwen_cbv2_query128_bf16_tf32_default_v1",
                arithmeticPolicySHA256: hash("fake-arithmetic"),
                supportedPrefillSchedules: [.serial, .oneChunkLookahead],
                supportedGenerationModes: pipelineOnly ? [.pipeline]
                    : ClusterGenerationMode.allCases.filter { !$0.usesTensorParallelDecode || $0.usesTensorParallelPrefill })
            try FileHandle.standardOutput.write(contentsOf: ClusterRuntimeCapabilityCodec.encode(capability))
            exit(0)
        } catch { exit(1) }
    }
}
