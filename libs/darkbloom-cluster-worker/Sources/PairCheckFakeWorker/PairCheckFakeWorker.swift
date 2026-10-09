import CryptoKit
import Darwin
import DarkbloomClusterProtocol
import Foundation

/// Model-free stand-in for `darkbloom-cluster-worker`, used only by the pair
/// driver's tests. It accepts the worker's exact command line and speaks the
/// worker protocol through the library's own codec and session, so the driver
/// is exercised through its real launch path. How it behaves is read from
/// `behavior.json` beside the executable; nothing reaches it through the
/// environment, because the driver launches a worker with a fixed one.
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

        init() {}
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            mode = try values.decodeIfPresent(String.self, forKey: .mode) ?? "ok"
            clockSkewNanoseconds = try values.decodeIfPresent(Int64.self, forKey: .clockSkewNanoseconds) ?? 0
            evidenceTokenDelta = try values.decodeIfPresent(Int.self, forKey: .evidenceTokenDelta) ?? 0
            evidenceDeltaRanks = try values.decodeIfPresent([Int].self, forKey: .evidenceDeltaRanks) ?? [1]
            firstToken = try values.decodeIfPresent(Int.self, forKey: .firstToken) ?? 100
        }
        enum CodingKeys: String, CodingKey { case mode, clockSkewNanoseconds, evidenceTokenDelta, evidenceDeltaRanks, firstToken }
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
        if arguments.first == "--describe-runtime" { describe(arguments, executable: executable) }

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
        // What a real worker would refuse: its own deadline on its own clock.
        let now = uptime()
        guard deadline > now, deadline - now <= 300_000_000_000 else { exit(65) }
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

        let identity = ClusterWorkerIdentity(membershipEpoch: epoch, modelID: "registered_qwen35_9b",
            artifactSHA256: artifact, configurationSHA256: configuration,
            peers: [.init(id: peer0, buildSHA256: build0), .init(id: peer1, buildSHA256: build1)])
        do {
            var session = try ClusterWorkerSession(identity: identity, rank: rank, profile: profile, executionPlanSHA256: plan(cut: cut))
            var sequence: UInt64 = 0, requestID: UUID?, reservation: ClusterWorkerReservation?, selected = 0
            func emit(_ event: ClusterWorkerEvent) throws {
                let id: UUID?
                switch event { case .ready, .unavailable, .shutdownComplete: id = nil; default: id = requestID }
                let frame = ClusterWorkerEventFrame(membershipEpoch: epoch, sequence: sequence, requestID: id, event: event)
                try session.accept(frame, now: uptime())
                try FileHandle.standardOutput.write(contentsOf: ClusterWorkerCodec.encode(frame)); sequence += 1
            }
            func tokens(_ request: ClusterWorkerReservation) -> [Int] {
                (0..<request.outputCount).map { behavior.firstToken + $0 }
            }
            func record(_ request: ClusterWorkerReservation) throws {
                guard let directory = fields["--evidence-directory"], let requestID else { return }
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
                executionPlanSHA256: plan(cut: cut), requestCapacityBytes: 1 << 20)))
            var decoder = ClusterWorkerLineDecoder(commandStream: true)
            while true {
                var buffer = [UInt8](repeating: 0, count: 65_536)
                let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                if count == 0 { break }
                if count < 0 { if errno == EINTR { continue }; exit(74) }
                for line in try decoder.append(Data(buffer.prefix(count))) {
                    let command = try ClusterWorkerCodec.decodeCommand(line)
                    try session.accept(command, now: uptime())
                    switch command.command {
                    case .reserve(let value):
                        requestID = command.requestID; reservation = value; selected = 0
                        let current = uptime()
                        if behavior.mode == "refuse" { try emit(.refused(.capacity)) }
                        else if value.deadlineUptimeNanoseconds <= current || value.deadlineUptimeNanoseconds > deadline {
                            try emit(.refused(.deadline))
                        } else { try emit(.admitted(reservedBytes: 4096)) }
                    case .start:
                        if behavior.mode == "exit-on-start" { exit(9) }
                        if behavior.mode == "stall-on-start" { continue }
                        let request = reservation!
                        if rank == 1 {
                            try record(request)
                            try emit(.finished(.length)); try emit(.retired(.clean))
                        } else {
                            try emit(.committedToken(ordinal: 0, tokenID: tokens(request)[0],
                                committedTokens: request.promptTokenIDs.count)); selected = 1
                        }
                    case .tokenDecision(_, let decision):
                        let request = reservation!
                        if selected == request.outputCount || decision == .cleanStop {
                            try record(request)
                            try emit(.finished(selected == request.outputCount ? .length : .clientStop))
                            try emit(.retired(.clean))
                        } else {
                            try emit(.committedToken(ordinal: selected, tokenID: tokens(request)[selected],
                                committedTokens: request.promptTokenIDs.count + selected)); selected += 1
                        }
                    case .cancel:
                        // A real worker reports the failure, releases and exits.
                        try emit(.failed(.runtimeError)); exit(1)
                    case .shutdown:
                        try emit(.shutdownComplete); exit(0)
                    }
                }
            }
            // Input ended without shutdown: a real worker releases and exits 1.
            exit(1)
        } catch { exit(70) }
    }

    static func describe(_ arguments: [String], executable: URL) -> Never {
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
                arithmeticPolicySHA256: hash("fake-arithmetic"), maxLifetimeSeconds: 300, maxRequests: 16,
                supportedPrefillSchedules: [.serial, .oneChunkLookahead])
            try FileHandle.standardOutput.write(contentsOf: ClusterRuntimeCapabilityCodec.encode(capability))
            exit(0)
        } catch { exit(1) }
    }
}
