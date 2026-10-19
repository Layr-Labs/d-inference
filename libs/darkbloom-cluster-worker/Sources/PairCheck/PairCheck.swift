import DarkbloomClusterPrompt
import DarkbloomClusterQualification
import Darwin
import Foundation

// Two-Mac qualification, without MLX in this process:
//   request  write a qualification request from fixed text or fixed token IDs
//   run      run that request on rank 0 (this Mac) and rank 1 (the second Mac)
//   solo     run that request on one Mac alone, timed on this driver's clock
//   compare  compare a reference report with a pair report (or two reports)
//   record   the qualification record of a pair report against its references
//            (what a provider's pair-serving grant rests on)

@main enum PairCheck {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static let usage = """
        usage:
          darkbloom-cluster-pair-check request --output NEW-REQUEST.json --chunk-size N --output-count N
              (--model-dir /ABS/MODEL (--user-text-file FILE | --raw-text-file FILE) [--prompt-tokens N]
               | --synthetic-tokens N [--seed N] | --token-ids-file FILE)
              [--stop-token-ids A,B] [--request-id UUID] [--model-id REGISTERED_MODEL_ID (default: the tokenizer's model)]
              [--route decoding_rank_alone (the phase split's decoding rank serves it alone; the planner's per-request route)]
              [--temperature F [--top-p F] [--top-k N] [--min-p F] --sampling-seed N [--sampling-stream N]
               (a sampled request: the decoding rank draws with the product's sampler, keyed on seed, stream and index)]
          darkbloom-cluster-pair-check run --request REQUEST.json --stage-cut CUT --report NEW-REPORT.json
              --remote-ssh DESTINATION [--ssh-option Key=Value]...
              --local-worker /ABS/WORKER --remote-worker /ABS/WORKER
              --local-model-dir /ABS/MODEL --remote-model-dir /ABS/MODEL
              --local-rdma-device NAME --remote-rdma-device NAME --coordinator RANK0_LINK_IPV4:PORT
              [--local-rank 0|1 (default 0; 1 runs rank 0 on the second Mac and rank 1 here, and the
               coordinator address is then the second Mac's own link address)]
              [--evidence final-row|none] [--prefill-schedule serial_v1|one_chunk_lookahead_v1]
              [--mode pipeline|pipeline-compact|pipeline-mtp|phase-split|phase-split-mtp|tensor-parallel] [--mtp-depth 1...4 (phase-split-mtp; 1...3 pipeline-mtp)]
              [--tensor-shares A:B (tensor-parallel; each rank's share weight, default equal)]
              [--repetitions N (with --evidence none; no session limit)]
              [--idle-seconds S[,S...] (idle gaps before requests 2, 3, ...; the list repeats)]
              [--keep-warm on|off (S27 keep-warm, both tiers; default on)]
              [--follow-request REQUEST.json (repeatable; run once each after the repetitions, same session)]
              [--serving-context-check on|off (default on: a request longer than the pair's serving context is
                                              refused before either rank is asked; off sends it to the ranks' gates)]
              [--stop-renewals-after-seconds S (qualification: stop renewing both rank leases; workers must end)]
              [--transport local-socket-test (both ranks on this Mac, with --remote-command-prefix; correctness only)]
              [--fault RANK:handoff_corrupt_segment=N | RANK:handoff_stall_after_segment=N:MILLISECONDS
                       | RANK:prefix_ssd_restore_fail=1 | RANK:prefix_ssd_restore_stall=MILLISECONDS]
              [--local-prefix-ssd-dir /ABS --local-prefix-ssd-key-file /ABS] (each Mac's prompt-prefix SSD tier:
              [--remote-prefix-ssd-dir /ABS --remote-prefix-ssd-key-file /ABS]  root and a private 32-byte key file;
                                                                     the key reaches the worker on its input)
              [--prefix-ssd off (diagnosis: both workers keep nothing on disk and delete what they kept)]
              [--stop-after-tokens N (the owner stops like a client that hangs up; with --evidence none)]
              [--data-plane encrypted_v1|plaintext (S16; default encrypted_v1: per-run pinned identities, keyed records)]
              [--data-plane-fault RANK:wrong-pin | RANK:KIND:ORDINAL (qualification: a wrong pin on that rank, or one
                                  flipped ciphertext byte of its ORDINAL-th KIND record, e.g. 0:residualPayload:3)]
              [--data-plane-rekey-records N (qualification: both ranks rekey every N records per direction, 2...262144)]
              [--startup-seconds N] [--request-seconds N]
              [--rank1-delay-seconds N] [--progress-timeout-ms N] [--allow-unguarded-jaccl yes]
              (request and progress limits default to budgets scaled with the prompt length from the model's
               measured single-Mac rates, never below 100 s and 60000 ms)
              [--memory-gate record|measure (qualification: record every host memory gate decision; measure also
                                             leaves a refusal for admissible memory alone unenforced)]
              [--stage-residency yes|no|off (qualification: yes = both workers hold a standing MLX wired limit for
                                             the loaded stage; off = MiMo runs without its standing residency)]
              [--mimo-step-evidence on (qualification, MiMo: rank 1 reports each selected row's digests and top logits)]
              [--local-scratch-dir /ABS] [--remote-scratch-dir /ABS] [--keep-run-files yes] [--preflight-only yes]
          darkbloom-cluster-pair-check solo --request REQUEST.json --stage-cut CUT --report NEW-REPORT.json
              --service /ABS/darkbloom-cluster-reference --model-dir /ABS/MODEL
              [--remote-ssh DESTINATION [--ssh-option Key=Value]...] [--role LABEL] [--repetitions 1...8]
              [--lifetime-seconds 10...3600] [--startup-seconds N] [--request-seconds N]
          darkbloom-cluster-pair-check compare --reference REPORT.json --candidate REPORT.json
              [--near-tie-ulps N] [--allow-cut-difference yes] [--allow-schedule-difference yes]
              [--allow-profile-difference yes (profiles that differ only in their limits)]
              [--json yes] [--require VERDICT[,VERDICT]] [--model-dir /ABS/MODEL]
          darkbloom-cluster-pair-check record --pair PAIR-REPORT.json --reference REPORT.json [--reference REPORT.json]...
              --output NEW-RECORD.jsonl [--near-tie-ulps N] [--allow-cut-difference yes]
              [--allow-schedule-difference yes] [--allow-profile-difference yes]
              [--timing-mode TIMED-PAIR-REPORT.json --timing-plain TIMED-PAIR-REPORT.json
               (decode of timed runs of the same placement and request in the record's mode and as pipeline_v1)]
        """

    /// `--name value` pairs; names in `repeated` may occur more than once.
    static func parse(_ arguments: [String], allowed: Set<String>, repeated: Set<String> = []) throws -> [String: [String]] {
        guard arguments.count % 2 == 0 else { throw Failure("Expected --name value pairs\n" + usage) }
        var fields: [String: [String]] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let name = arguments[index]
            guard allowed.contains(name), repeated.contains(name) || fields[name] == nil else {
                throw Failure("Unknown or repeated argument \(name)\n" + usage)
            }
            fields[name, default: []].append(arguments[index + 1])
        }
        return fields
    }

    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            switch arguments.first {
            case "request": try await request(Array(arguments.dropFirst()))
            case "run": try await run(Array(arguments.dropFirst()))
            case "solo": try solo(Array(arguments.dropFirst()))
            case "compare": try await compare(Array(arguments.dropFirst()))
            case "record": try record(Array(arguments.dropFirst()))
            default: throw Failure(usage)
            }
        } catch {
            FileHandle.standardError.write(Data("darkbloom-cluster-pair-check: \(error)\n".utf8))
            Darwin.exit(1)
        }
    }

    static func integer(_ fields: [String: [String]], _ name: String) throws -> Int? {
        guard let text = fields[name]?.first else { return nil }
        guard let value = Int(text), String(value) == text else { throw Failure("\(name) must be an integer") }
        return value
    }

    static func request(_ arguments: [String]) async throws {
        let fields = try parse(arguments, allowed: ["--output", "--chunk-size", "--output-count", "--model-dir",
            "--user-text-file", "--raw-text-file", "--prompt-tokens", "--synthetic-tokens", "--seed",
            "--token-ids-file", "--stop-token-ids", "--request-id", "--model-id",
            "--temperature", "--top-p", "--top-k", "--min-p", "--sampling-seed", "--sampling-stream", "--route"])
        guard let output = fields["--output"]?.first, let chunk = try integer(fields, "--chunk-size"),
              let count = try integer(fields, "--output-count") else { throw Failure(usage) }
        let stops = try (fields["--stop-token-ids"]?.first ?? "").split(separator: ",").map { text -> Int in
            guard let value = Int(text) else { throw Failure("--stop-token-ids must be comma-separated integers") }
            return value
        }
        let id = try fields["--request-id"]?.first.map { text -> UUID in
            guard let value = UUID(uuidString: text) else { throw Failure("--request-id must be a UUID") }
            return value
        } ?? UUID()
        let sources = ["--user-text-file", "--raw-text-file", "--synthetic-tokens", "--token-ids-file"].filter { fields[$0] != nil }
        guard sources.count == 1 else { throw Failure("Choose exactly one prompt source\n" + usage) }
        let promptTokens = try integer(fields, "--prompt-tokens")
        let tokens: [Int], source: QualificationPromptSource
        var tokenizerModelID: String?
        switch sources[0] {
        case "--synthetic-tokens":
            let length = try integer(fields, "--synthetic-tokens")!, seed = try integer(fields, "--seed") ?? 0
            let bound = QualificationLimits.forModel(fields["--model-id"]?.first ?? QualificationRequest.modelID).maximumPromptTokens
            guard (1...bound).contains(length) else { throw Failure("--synthetic-tokens must be 1...\(bound) for this model") }
            tokens = QualificationRequest.syntheticPrompt(count: length, seed: seed)
            source = .init(kind: "synthetic", description: "Token i is 1000 + ((seed + i) * 2654435761 mod 2^32) mod 100000; not meaningful text",
                           syntheticSeed: seed)
        case "--token-ids-file":
            let data = try QualificationFiles.read(URL(fileURLWithPath: fields["--token-ids-file"]![0]), maximumBytes: 1 << 20)
            tokens = try JSONDecoder().decode([Int].self, from: data)
            source = .init(kind: "tokenIDs", description: "Token IDs supplied as a JSON array")
        default:
            guard let model = fields["--model-dir"]?.first, model.hasPrefix("/") else {
                throw Failure("A text prompt needs --model-dir for the artifact's tokenizer")
            }
            let tokenizer = try await PromptTokenizer.load(modelDirectory: URL(fileURLWithPath: model))
            tokenizerModelID = tokenizer.modelID
            let data = try QualificationFiles.read(URL(fileURLWithPath: fields[sources[0]]![0]), maximumBytes: 4 << 20)
            guard let text = String(data: data, encoding: .utf8) else { throw Failure("The prompt text is not UTF-8") }
            if sources[0] == "--user-text-file" {
                (tokens, source) = try tokenizer.encodeChat(userText: text, promptTokenCount: promptTokens)
            } else {
                var body = tokenizer.encodeRaw(text)
                guard !body.isEmpty else { throw Failure("The prompt text produced no tokens") }
                if let promptTokens {
                    let unit = body
                    while body.count < promptTokens { body += unit }
                    body = Array(body.prefix(promptTokens))
                }
                tokens = body; source = tokenizer.rawSource(text: text, tokenCount: body.count)
            }
        }
        // A closed choice: the request names one registered model, and the
        // reference and the workers each refuse a request for another one. A
        // text prompt takes the model from the artifact whose tokenizer made it.
        let modelID = fields["--model-id"]?.first ?? tokenizerModelID ?? QualificationRequest.modelID
        guard QualificationRequest.registeredModel(modelID) != nil else {
            throw Failure("--model-id must be one of: " + QualificationRequest.registeredModels.map(\.modelID).joined(separator: ", "))
        }
        guard tokenizerModelID == nil || tokenizerModelID == modelID else {
            throw Failure("--model-id is \(modelID) but the tokenizer in --model-dir belongs to \(tokenizerModelID!)")
        }
        func float(_ name: String) throws -> Float? {
            guard let text = fields[name]?.first else { return nil }
            guard let value = Float(text), value.isFinite else { throw Failure("\(name) must be a finite number") }
            return value
        }
        func unsigned(_ name: String) throws -> UInt64? {
            guard let text = fields[name]?.first else { return nil }
            guard let value = UInt64(text) else { throw Failure("\(name) must be a non-negative integer") }
            return value
        }
        var sampling: QualificationSampling?
        if let temperature = try float("--temperature") {
            guard let seed = try unsigned("--sampling-seed") else { throw Failure("A sampled request needs --sampling-seed") }
            sampling = .init(temperature: temperature, topP: try float("--top-p") ?? 1, topK: try integer(fields, "--top-k") ?? 0,
                minP: try float("--min-p") ?? 0, seed: seed, stream: try unsigned("--sampling-stream") ?? 1)
        } else if ["--top-p", "--top-k", "--min-p", "--sampling-seed", "--sampling-stream"].contains(where: { fields[$0] != nil }) {
            throw Failure("Sampling options need --temperature")
        }
        var value = try QualificationRequest(requestID: id, promptTokenIDs: tokens, chunkSize: chunk,
            outputCount: count, stopTokenIDs: stops, promptSource: source, modelID: modelID, sampling: sampling)
        if let route = fields["--route"]?.first {
            value.route = route
            try value.validate()
        }
        try QualificationFiles.writeNew(value.encoded(), to: URL(fileURLWithPath: output))
        print("request \(value.requestID) for \(value.modelID): \(tokens.count) prompt tokens, chunk \(chunk), \(count) outputs, prompt SHA-256 \(value.promptTokenIDsSHA256)"
            + (sampling.map { " sampled (temperature \($0.temperature), top-p \($0.topP), top-k \($0.topK), seed \($0.seed))" } ?? ""))
    }

    static func run(_ arguments: [String]) async throws {
        let names: Set<String> = ["--request", "--stage-cut", "--report", "--remote-ssh", "--ssh-option",
            "--local-worker", "--remote-worker", "--local-model-dir", "--remote-model-dir",
            "--local-rdma-device", "--remote-rdma-device", "--coordinator", "--evidence", "--prefill-schedule",
            "--startup-seconds", "--request-seconds", "--rank1-delay-seconds",
            "--idle-seconds", "--keep-warm", "--stop-renewals-after-seconds",
            "--progress-timeout-ms", "--local-scratch-dir", "--remote-scratch-dir", "--remote-command-prefix",
            "--preflight-only", "--allow-unguarded-jaccl", "--keep-run-files", "--mode", "--mtp-depth", "--tensor-shares", "--repetitions", "--transport", "--fault", "--stop-after-tokens",
            "--memory-gate", "--stage-residency", "--mimo-step-evidence", "--local-rank", "--follow-request", "--prefix-cache",
            "--data-plane", "--data-plane-fault", "--data-plane-rekey-records", "--serving-context-check",
            "--batch-lanes", "--batch-request", "--batch-wave", "--batch-solo", "--kv-backend",
            "--prefix-ssd", "--local-prefix-ssd-dir", "--local-prefix-ssd-key-file", "--remote-prefix-ssd-dir",
            "--remote-prefix-ssd-key-file"]
        let fields = try parse(arguments, allowed: names, repeated: ["--ssh-option", "--remote-command-prefix", "--follow-request",
            "--batch-request", "--batch-wave"])
        func required(_ name: String) throws -> String {
            guard let value = fields[name]?.first else { throw Failure("Missing \(name)\n" + usage) }
            return value
        }
        let request = try QualificationRequest.read(URL(fileURLWithPath: try required("--request")))
        let reportURL = URL(fileURLWithPath: try required("--report"))
        guard !FileManager.default.fileExists(atPath: reportURL.path) else {
            throw Failure("Report \(reportURL.lastPathComponent) already exists; a report is never overwritten")
        }
        guard let cut = try integer(fields, "--stage-cut") else { throw Failure("Missing --stage-cut\n" + usage) }
        let evidence = fields["--evidence"]?.first ?? "final-row"
        guard ["final-row", "none"].contains(evidence) else { throw Failure("--evidence must be final-row or none") }
        // `--remote-command-prefix` replaces ssh with another command that runs
        // its last argument through a shell. It exists for tests without a peer.
        let transport: [String], sensitive: [String]
        if let prefix = fields["--remote-command-prefix"] {
            guard fields["--remote-ssh"] == nil else { throw Failure("Choose --remote-ssh or --remote-command-prefix") }
            transport = prefix; sensitive = []
        } else {
            let destination = try required("--remote-ssh")
            transport = try PairConfiguration.sshTransport(destination: destination, options: fields["--ssh-option"] ?? [])
            // Option values can name a user, a host or a key file; numbers and switches cannot.
            sensitive = [destination] + (fields["--ssh-option"] ?? []).compactMap { option -> String? in
                guard let value = option.split(separator: "=", maxSplits: 1).last.map(String.init), value.count >= 3,
                      Int(value) == nil, !["yes", "none", "accept-new"].contains(value) else { return nil }
                return value
            }
        }
        // The workers have no lifetime: the budgets bound startup, each request and
        // each collective wait, scaled with the prompt (the solo tool keeps a lifetime).
        let repetitions = try integer(fields, "--repetitions") ?? 1
        let budgets = PairCheckBudgets(request: request, repetitions: repetitions,
            startupSeconds: try integer(fields, "--startup-seconds"), lifetimeSeconds: nil,
            requestSeconds: try integer(fields, "--request-seconds"), progressMilliseconds: try integer(fields, "--progress-timeout-ms"))
        let delay = fields["--rank1-delay-seconds"]?.first.flatMap(Double.init) ?? 2
        let modes = ["pipeline": PairConfiguration.pipelineMode, "phase-split": PairConfiguration.phaseSplitMode,
                     "pipeline-compact": PairConfiguration.pipelineCompactDecodeMode,
                     "phase-split-mtp": PairConfiguration.phaseSplitMTPMode, "pipeline-mtp": PairConfiguration.pipelineMTPMode,
                     "tensor-parallel": PairConfiguration.tensorParallelMode]
        guard let mode = modes[fields["--mode"]?.first ?? "pipeline"] else {
            throw Failure("--mode must be pipeline, pipeline-compact, pipeline-mtp, phase-split, phase-split-mtp or tensor-parallel")
        }
        var configuration = try PairConfiguration(request: request, stageCut: cut,
            local: .init(modelDirectory: try required("--local-model-dir"), workerPath: try required("--local-worker"),
                         rdmaDevice: try required("--local-rdma-device"), scratchDirectory: fields["--local-scratch-dir"]?.first ?? "/tmp"),
            remote: .init(modelDirectory: try required("--remote-model-dir"), workerPath: try required("--remote-worker"),
                          rdmaDevice: try required("--remote-rdma-device"), scratchDirectory: fields["--remote-scratch-dir"]?.first ?? "/tmp"),
            remoteTransport: transport, coordinator: try required("--coordinator"),
            prefillSchedule: fields["--prefill-schedule"]?.first ?? "serial_v1", recording: evidence == "final-row",
            startupSeconds: budgets.startupSeconds,
            requestSeconds: budgets.requestSeconds, rankOneDelaySeconds: delay,
            progressTimeoutMilliseconds: budgets.progressMilliseconds,
            requireProgressGuard: fields["--allow-unguarded-jaccl"]?.first != "yes",
            keepRunFiles: fields["--keep-run-files"]?.first == "yes",
            preflightOnly: fields["--preflight-only"]?.first == "yes", generationMode: mode,
            repetitions: repetitions,
            workerTransport: fields["--transport"]?.first ?? PairConfiguration.jacclTransport, sensitive: sensitive,
            localRank: try integer(fields, "--local-rank") ?? 0)
        if let idle = fields["--idle-seconds"]?.first {
            let gaps = idle.split(separator: ",").map { Double($0) }
            guard !gaps.isEmpty, gaps.allSatisfy({ $0.map { (0...3600).contains($0) } ?? false }) else {
                throw Failure("--idle-seconds takes comma-separated seconds, each 0...3600")
            }
            configuration.idleSeconds = gaps.map { $0! }
        }
        if let keepWarm = fields["--keep-warm"]?.first {
            guard ["on", "off"].contains(keepWarm) else { throw Failure("--keep-warm takes on or off") }
            configuration.keepWarm = keepWarm == "on"
        }
        if let stop = fields["--stop-renewals-after-seconds"]?.first {
            guard let seconds = Double(stop), (1...3600).contains(seconds) else {
                throw Failure("--stop-renewals-after-seconds takes 1...3600")
            }
            configuration.stopRenewalsAfterSeconds = seconds
        }
        if let cache = fields["--prefix-cache"]?.first {
            guard ["on", "off"].contains(cache) else { throw Failure("--prefix-cache takes on or off") }
            configuration.prefixCacheOff = cache == "off"
        }
        if let lanes = try integer(fields, "--batch-lanes") {
            guard (1...8).contains(lanes) else { throw Failure("--batch-lanes takes 1...8") }
            configuration.batchLanes = lanes
        }
        if let backend = fields["--kv-backend"]?.first {
            guard ["paged", "contiguous"].contains(backend) else { throw Failure("--kv-backend takes paged or contiguous") }
            configuration.kvBackend = backend
        }
        if let batch = fields["--batch-request"] {
            configuration.batchRequests = try batch.map { try QualificationRequest.read(URL(fileURLWithPath: $0)) }
            configuration.batchWaves = try (fields["--batch-wave"] ?? []).map {
                guard let value = Int($0), (1...8).contains(value) else { throw Failure("--batch-wave takes 1...8") }
                return value
            }
            configuration.batchSolo = fields["--batch-solo"]?.first != "no"
            try configuration.validate()
        }
        for (side, keyPath) in [("local", \PairConfiguration.localPrefixSSD), ("remote", \PairConfiguration.remotePrefixSSD)] {
            let directory = fields["--\(side)-prefix-ssd-dir"]?.first, key = fields["--\(side)-prefix-ssd-key-file"]?.first
            guard (directory == nil) == (key == nil) else {
                throw Failure("--\(side)-prefix-ssd-dir and --\(side)-prefix-ssd-key-file go together")
            }
            if let directory, let key { configuration[keyPath: keyPath] = PairPrefixSSD(directory: directory, keyFile: key) }
        }
        if let ssd = fields["--prefix-ssd"]?.first {
            guard ["on", "off"].contains(ssd) else { throw Failure("--prefix-ssd takes on or off") }
            configuration.prefixSSDOff = ssd == "off"
        }
        if fields["--local-prefix-ssd-dir"] != nil || fields["--remote-prefix-ssd-dir"] != nil { try configuration.validate() }
        if let follow = fields["--follow-request"] {
            configuration.followRequests = try follow.map { try QualificationRequest.read(URL(fileURLWithPath: $0)) }
            try configuration.validate()
        }
        if let check = fields["--serving-context-check"]?.first {
            guard ["on", "off"].contains(check) else { throw Failure("--serving-context-check takes on or off") }
            configuration.servingContextCheck = check == "on"
        }
        if let fault = fields["--fault"]?.first {
            let parts = fault.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let rank = Int(parts[0]) else { throw Failure("--fault takes RANK:name=value") }
            configuration.faultRank = rank; configuration.faultValue = String(parts[1])
            try configuration.validate()
        }
        if let plane = fields["--data-plane"]?.first {
            guard [PairConfiguration.encryptedDataPlane, PairConfiguration.plaintextDataPlane].contains(plane) else {
                throw Failure("--data-plane takes encrypted_v1 or plaintext")
            }
            configuration.dataPlane = plane
        }
        if let fault = fields["--data-plane-fault"]?.first {
            // RANK:wrong-pin, or RANK:KIND:ORDINAL (one flipped ciphertext byte).
            let parts = fault.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let rank = Int(parts[0]) else {
                throw Failure("--data-plane-fault takes RANK:wrong-pin or RANK:KIND:ORDINAL")
            }
            if parts[1] == "wrong-pin" { configuration.wrongPinRank = rank }
            else { configuration.tamperRank = rank; configuration.tamperValue = String(parts[1]) }
            try configuration.validate()
        }
        if let records = try integer(fields, "--data-plane-rekey-records") {
            configuration.rekeyRecords = records
            try configuration.validate()
        }
        if let stop = try integer(fields, "--stop-after-tokens") {
            configuration.stopAfterTokens = stop
            try configuration.validate()
        }
        if let depth = try integer(fields, "--mtp-depth") {
            configuration.speculativeDepth = depth
            try configuration.validate()
        }
        if let text = fields["--tensor-shares"]?.first {
            let weights = text.split(separator: ":").compactMap { Int($0) }
            guard weights.count == 2, weights.map(String.init).joined(separator: ":") == text else {
                throw Failure("--tensor-shares takes A:B")
            }
            configuration.tensorShares = weights
            try configuration.validate()
        }
        if let gate = fields["--memory-gate"]?.first {
            guard ["record", "measure"].contains(gate) else { throw Failure("--memory-gate takes record or measure") }
            configuration.memoryGateMode = gate
        }
        if let residency = fields["--stage-residency"]?.first {
            // yes/no: S00's standing wired limit for any stage; off: MiMo without its own residency.
            guard ["yes", "no", "off"].contains(residency) else { throw Failure("--stage-residency takes yes, no or off") }
            configuration.stageResidency = residency == "yes"
            configuration.withoutStageResidency = residency == "off"
        }
        if let steps = fields["--mimo-step-evidence"]?.first {
            guard steps == "on" else { throw Failure("--mimo-step-evidence takes only the value on") }
            // MiMo's step lines; the GLM row writes the same evidence format.
            guard ["registered_mimo_v26_flash_mopd", "registered_glm53_flash"].contains(configuration.request.modelID) else {
                throw Failure("--mimo-step-evidence is for the MiMo and GLM rows only")
            }
            configuration.mimoStepEvidence = true
        }
        // A loopback socket needs both ranks on this Mac.
        guard configuration.workerTransport == PairConfiguration.jacclTransport || fields["--remote-command-prefix"] != nil else {
            throw Failure("--transport local-socket-test needs --remote-command-prefix (both ranks on this Mac)")
        }
        // Last resort for the driver itself: inspections, the planned run
        // (startup, every request at its timeout and every idle gap), the
        // workers' exit, and collection, with room to spare. The workers have
        // no lifetime of their own; the driver's run is what is bounded.
        let longestGap = Int((configuration.idleSeconds.max() ?? 0).rounded(.up))
        let planned = min(86_400, configuration.startupSeconds
            + configuration.repetitions * (configuration.requestSeconds + longestGap) + 420)
        try QualificationDeadline.arm(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
            + UInt64(planned) * 1_000_000_000, status: 124)
        FileHandle.standardError.write(Data(("pair-check: budgets for \(request.promptTokenIDs.count) prompt and \(request.outputCount) output tokens, "
            + "\(repetitions) request(s): startup \(configuration.startupSeconds) s, request \(configuration.requestSeconds) s, "
            + "progress limit \(configuration.progressTimeoutMilliseconds.map(String.init) ?? "none") ms (\(budgets.source))\n").utf8))
        // The artifact's tokenizer, if this Mac has it, only to print readable output.
        let tokenizer = try? await PromptTokenizer.load(modelDirectory: URL(fileURLWithPath: configuration.local.modelDirectory))
        var driver = PairDriver(configuration: configuration)
        driver.log = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        if let tokenizer { driver.decode = { tokenizer.decode($0) } }
        let report = driver.run()
        try QualificationFiles.writeNew(QualificationReportFiles.encode(report), to: reportURL)
        var lines = ["outcome: \(report.outcome)" + (report.failure.map { " (\($0))" } ?? "")]
        for rank in report.ranks {
            let exit = rank.exitSignal.map { "signal \($0)" } ?? rank.exitStatus.map { "status \($0)" } ?? (rank.launched ? "not observed" : "not launched")
            let wired = rank.wiredBytesBefore.flatMap { before in rank.wiredBytesAfter.map { String(format: "%+.2f GiB", Double($0 - before) / 1_073_741_824) } } ?? "unknown"
            lines.append("\(rank.role): \(rank.chip ?? "unknown chip"), ready \(rank.readyObserved), shutdown acknowledged \(rank.shutdownCompleteObserved), exit \(exit), worker processes left \(rank.workerProcessesLeft.map(String.init) ?? "unknown"), wired memory change \(wired)")
        }
        if let evidence = report.evidence {
            lines.append("tokens: \(evidence.selectedTokenIDs.count) (\(evidence.finishReason)); ranks agree: \(report.ranksAgreeOnTokens.map { "\($0)" } ?? "not recorded")")
        }
        if let text = report.decodedOutput, !text.isEmpty { lines.append("decoded output: \(text)") }
        for (index, timing) in (report.timing.repetitions ?? []).enumerated() {
            lines.append(String(format: "request %d: first token %.3f s (%.0f prompt tok/s), decode %.1f tok/s, total %.3f s",
                index + 1, timing.firstTokenSeconds, timing.prefillTokensPerSecond,
                timing.decodeTokensPerSecond ?? 0, timing.totalSeconds)
                + ", prompt \(timing.promptTokens.map(String.init) ?? "?"), reused \(timing.reusedPromptTokens ?? 0)"
                + ", tokens \(timing.tokens) \(timing.selectedTokenIDsSHA256.prefix(16))")
        }
        for item in report.timing.refusedRequests ?? [] {
            lines.append("request \(item.ordinal + 1): refused (\(item.reason)) before it started, "
                + "\(item.promptTokens + item.outputTokens) context tokens, serving context \(item.servingContextTokens), "
                + (item.refusedUpFront ? "refused up front" : "refused by rank " + item.refusingRanks.map(String.init).joined(separator: ",")))
        }
        if let ready = report.timing.servingContextAtReady {
            lines.append("serving context: at ready " + ready.map { $0.map(String.init) ?? "?" }.joined(separator: "/")
                + ", at end \(report.timing.servingContextAtEnd.map(String.init) ?? "?")")
        }
        if let agree = report.repetitionsAgreeOnTokens { lines.append("repeated requests select the same tokens: \(agree)") }
        if let agree = report.dataPlaneRecordsAgree {
            lines.append("data plane: records agree \(agree), key rotations \(report.dataPlaneKeyRotations ?? 0)")
        }
        for rank in report.ranks { for line in rank.runtimeLines ?? [] { lines.append("\(rank.role): \(line)") } }
        lines.append("report: \(reportURL.lastPathComponent)")
        print(lines.joined(separator: "\n"))
        Darwin.exit(report.outcome == (configuration.preflightOnly ? "preflight" : "completed") ? 0 : 2)
    }

    static func solo(_ arguments: [String]) throws {
        let fields = try parse(arguments, allowed: ["--request", "--stage-cut", "--report", "--service", "--model-dir",
            "--remote-ssh", "--ssh-option", "--role", "--repetitions", "--lifetime-seconds", "--startup-seconds",
            "--request-seconds"], repeated: ["--ssh-option"])
        func required(_ name: String) throws -> String {
            guard let value = fields[name]?.first else { throw Failure("Missing \(name)\n" + usage) }
            return value
        }
        let request = try QualificationRequest.read(URL(fileURLWithPath: try required("--request")))
        // The solo service selects argmax tokens; a sampled request has no solo oracle.
        guard request.sampling == nil else { throw Failure("solo runs greedy requests only; this request is sampled") }
        let reportURL = URL(fileURLWithPath: try required("--report"))
        guard !FileManager.default.fileExists(atPath: reportURL.path) else {
            throw Failure("Report \(reportURL.lastPathComponent) already exists; a report is never overwritten")
        }
        guard let cut = try integer(fields, "--stage-cut") else { throw Failure("Missing --stage-cut\n" + usage) }
        var transport = ["/bin/sh", "-c"], sensitive: [String] = []
        if let destination = fields["--remote-ssh"]?.first {
            transport = try PairConfiguration.sshTransport(destination: destination, options: fields["--ssh-option"] ?? [])
            sensitive = [destination] + (fields["--ssh-option"] ?? []).compactMap { option -> String? in
                guard let value = option.split(separator: "=", maxSplits: 1).last.map(String.init), value.count >= 3,
                      Int(value) == nil, !["yes", "none", "accept-new"].contains(value) else { return nil }
                return value
            }
        }
        let repetitions = try integer(fields, "--repetitions") ?? 1
        let budgets = PairCheckBudgets(request: request, repetitions: repetitions,
            startupSeconds: try integer(fields, "--startup-seconds"), lifetimeSeconds: try integer(fields, "--lifetime-seconds"),
            requestSeconds: try integer(fields, "--request-seconds"), progressMilliseconds: nil)
        let lifetime = budgets.lifetimeSeconds
        let remote = fields["--remote-ssh"] != nil
        FileHandle.standardError.write(Data(("solo: budgets for \(request.promptTokenIDs.count) prompt and \(request.outputCount) output tokens, "
            + "\(repetitions) request(s): lifetime \(lifetime) s, startup \(budgets.startupSeconds) s, request \(budgets.requestSeconds) s (\(budgets.source))\n").utf8))
        let configuration = try SoloConfiguration(request: request, stageCut: cut,
            modelDirectory: try required("--model-dir"), servicePath: try required("--service"),
            transport: transport, remote: remote, repetitions: repetitions,
            lifetimeSeconds: lifetime, startupSeconds: budgets.startupSeconds,
            requestSeconds: budgets.requestSeconds,
            role: fields["--role"]?.first ?? (remote ? "single host remote" : "single host local"), sensitive: sensitive)
        try QualificationDeadline.arm(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
            + UInt64(lifetime + 180) * 1_000_000_000, status: 124)
        var driver = SoloDriver(configuration: configuration)
        driver.log = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        let report = driver.run()
        try QualificationFiles.writeNew(QualificationReportFiles.encode(report), to: reportURL)
        var lines = ["outcome: \(report.outcome)" + (report.failure.map { " (\($0))" } ?? ""),
                     "\(report.role): \(report.chip ?? "unknown chip"), exit \(report.exitStatus.map { "status \($0)" } ?? report.exitSignal.map { "signal \($0)" } ?? "not observed"), service processes left \(report.serviceProcessesLeft.map(String.init) ?? "unknown")"]
        for (index, timing) in report.repetitions.enumerated() {
            lines.append(String(format: "request %d: first token %.3f s (%.0f prompt tok/s), decode %.1f tok/s, total %.3f s",
                index + 1, timing.firstTokenSeconds, timing.prefillTokensPerSecond,
                timing.decodeTokensPerSecond ?? 0, timing.totalSeconds))
        }
        if let agree = report.repetitionsAgreeOnTokens { lines.append("repeated requests select the same tokens: \(agree)") }
        lines.append("report: \(reportURL.lastPathComponent)")
        print(lines.joined(separator: "\n"))
        Darwin.exit(report.outcome == "completed" ? 0 : 2)
    }

    static func compare(_ arguments: [String]) async throws {
        let fields = try parse(arguments, allowed: ["--reference", "--candidate", "--near-tie-ulps",
            "--allow-cut-difference", "--allow-schedule-difference", "--allow-profile-difference", "--json", "--require", "--model-dir"])
        guard let referencePath = fields["--reference"]?.first, let candidatePath = fields["--candidate"]?.first else {
            throw Failure(usage)
        }
        let threshold = try fields["--near-tie-ulps"]?.first.map { text -> Float in
            guard let value = Float(text), value >= 0, value.isFinite else { throw Failure("--near-tie-ulps must be a non-negative number") }
            return value
        } ?? 4
        let required = try (fields["--require"]?.first ?? "").split(separator: ",").map { text -> QualificationVerdict in
            guard let verdict = QualificationVerdict(rawValue: String(text)) else {
                throw Failure("--require takes verdicts from: " + QualificationVerdict.allCases.map(\.rawValue).joined(separator: ", "))
            }
            return verdict
        }
        let candidate = try QualificationReportFiles.subject(URL(fileURLWithPath: candidatePath))
        let referenceData = try QualificationFiles.read(URL(fileURLWithPath: referencePath), maximumBytes: QualificationReportFiles.maximumBytes)
        // A MiMo reference names its request by ID; the comparison reads the
        // request fields it does not carry from the candidate.
        let reference = MiMoQualificationEvidence.isReference(referenceData)
            ? try MiMoQualificationEvidence.reference(referenceData, comparableWith: candidate.identity).subject
            : try QualificationReportFiles.subject(URL(fileURLWithPath: referencePath))
        let comparison = try QualificationComparator(nearTieULPs: threshold,
            allowCutDifference: fields["--allow-cut-difference"]?.first == "yes",
            allowScheduleDifference: fields["--allow-schedule-difference"]?.first == "yes",
            allowProfileDifference: fields["--allow-profile-difference"]?.first == "yes").compare(reference: reference, candidate: candidate)
        if fields["--json"]?.first == "yes" {
            print(String(decoding: try QualificationReportFiles.encode(comparison), as: UTF8.self), terminator: "")
        } else {
            print(QualificationComparator.render(comparison))
            if let index = comparison.tokens.firstDivergenceIndex, let model = fields["--model-dir"]?.first,
               let tokenizer = try? await PromptTokenizer.load(modelDirectory: URL(fileURLWithPath: model)) {
                let start = max(0, index - 12)
                func text(_ tokens: [Int]) -> String { tokenizer.decode(Array(tokens.dropFirst(start).prefix(index - start + 6))) }
                print("reference text around the divergence: \(text(reference.evidence.selectedTokenIDs).debugDescription)")
                print("candidate text around the divergence: \(text(candidate.evidence.selectedTokenIDs).debugDescription)")
            }
        }
        Darwin.exit(required.isEmpty || required.contains(comparison.verdict) ? 0 : 3)
    }
}

extension PairCheck {
    /// Writes one qualification record (one JSON line) for a completed
    /// cross-cable pair report against every reference given, and prints
    /// whether it passes the near-tie rule. Exit 0 when it was written, pass
    /// or fail; a failing record withholds the model as surely as a passing
    /// one grants it.
    static func record(_ arguments: [String]) throws {
        let fields = try parse(arguments, allowed: ["--pair", "--reference", "--output", "--near-tie-ulps",
            "--allow-cut-difference", "--allow-schedule-difference", "--allow-profile-difference",
            "--timing-mode", "--timing-plain"], repeated: ["--reference"])
        guard let pairPath = fields["--pair"]?.first, let output = fields["--output"]?.first,
              let referencePaths = fields["--reference"], !referencePaths.isEmpty else { throw Failure(usage) }
        let threshold = try fields["--near-tie-ulps"]?.first.map { text -> Float in
            guard let value = Float(text), value >= 0, value.isFinite else { throw Failure("--near-tie-ulps must be a non-negative number") }
            return value
        } ?? 4
        let comparator = QualificationComparator(nearTieULPs: threshold,
            allowCutDifference: fields["--allow-cut-difference"]?.first == "yes",
            allowScheduleDifference: fields["--allow-schedule-difference"]?.first == "yes",
            allowProfileDifference: fields["--allow-profile-difference"]?.first == "yes")
        let record = try PairQualificationRecords.make(
            pairReport: QualificationFiles.read(URL(fileURLWithPath: pairPath), maximumBytes: QualificationReportFiles.maximumBytes),
            references: referencePaths.map { try QualificationFiles.read(URL(fileURLWithPath: $0), maximumBytes: QualificationReportFiles.maximumBytes) },
            comparator: comparator, timing: try timingReports(fields))
        try QualificationFiles.writeNew(Data((try record.encodedLine() + "\n").utf8), to: URL(fileURLWithPath: output))
        let chips = record.ranks.map(\.chip).joined(separator: " + ")
        print("\(record.runtimeModelID) on \(chips), cut \(record.cuts.map(String.init).joined(separator: ",")), \(record.generationMode): "
            + record.comparisons.map(\.verdict).joined(separator: ", ") + (record.passed ? " -> passes the near-tie rule" : " -> FAILS the near-tie rule"))
        if let measured = record.measuredDecode {
            print(String(format: "measured decode: %.1f tok/s in %@ vs %.1f tok/s as the plain pipeline (%.2fx)",
                measured.modeTokensPerSecond, record.generationMode, measured.plainPipelineTokensPerSecond, measured.speedup))
        }
    }

    /// Both timing reports, or neither.
    static func timingReports(_ fields: [String: [String]]) throws -> (mode: Data, plain: Data)? {
        let mode = fields["--timing-mode"]?.first, plain = fields["--timing-plain"]?.first
        guard (mode == nil) == (plain == nil) else { throw Failure("--timing-mode and --timing-plain go together") }
        guard let mode, let plain else { return nil }
        let bound = QualificationReportFiles.maximumBytes
        return (try QualificationFiles.read(URL(fileURLWithPath: mode), maximumBytes: bound),
                try QualificationFiles.read(URL(fileURLWithPath: plain), maximumBytes: bound))
    }
}

/// The pair's and the solo run's time limits: each one the operator gave, or
/// else a budget scaled with this request's prompt from the model's measured
/// single-Mac rates (`QualificationTimeBudget`), never below the fixed values
/// every earlier run used (240 s lifetime, 120 s startup, 100 s request,
/// 60,000 ms progress limit). A model without measured rates keeps those.
struct PairCheckBudgets {
    let lifetimeSeconds: Int, startupSeconds: Int, requestSeconds: Int, progressMilliseconds: Int
    let source: String

    init(request: QualificationRequest, repetitions: Int, startupSeconds: Int?, lifetimeSeconds: Int?,
         requestSeconds: Int?, progressMilliseconds: Int?) {
        let budget = QualificationTimeBudget.forModel(request.modelID)
        let prompt = request.promptTokenIDs.count, output = request.outputCount
        let startup = startupSeconds ?? 120
        let derivedRequest = budget.map { max(100, $0.requestSeconds(promptTokens: prompt, outputTokens: output)) } ?? 100
        let derivedLifetime = budget.map {
            max(240, $0.lifetimeSeconds(promptTokens: prompt, outputTokens: output, repetitions: repetitions, startupSeconds: startup))
        } ?? 240
        let lifetime = lifetimeSeconds ?? derivedLifetime
        self.lifetimeSeconds = lifetime
        self.startupSeconds = startupSeconds ?? min(120, lifetime)
        self.requestSeconds = requestSeconds ?? min(derivedRequest, lifetime)
        self.progressMilliseconds = progressMilliseconds
            ?? budget.map { $0.progressTimeoutMilliseconds(promptTokens: prompt, chunkTokens: request.chunkSize) } ?? 60_000
        source = budget == nil ? "fixed defaults: no measured rates for \(request.modelID)"
            : "scaled from the measured single-Mac rates of \(request.modelID) unless given"
    }
}
