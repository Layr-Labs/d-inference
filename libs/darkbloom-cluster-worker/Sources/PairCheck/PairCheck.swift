import DarkbloomClusterPrompt
import DarkbloomClusterQualification
import Darwin
import Foundation

// Two-Mac qualification, without MLX in this process:
//   request  write a qualification request from fixed text or fixed token IDs
//   run      run that request on rank 0 (this Mac) and rank 1 (the second Mac)
//   compare  compare a reference report with a pair report (or two reports)

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
              [--stop-token-ids A,B] [--request-id UUID] [--model-id registered_qwen35_9b|registered_qwen38_27b]
          darkbloom-cluster-pair-check run --request REQUEST.json --stage-cut CUT --report NEW-REPORT.json
              --remote-ssh DESTINATION [--ssh-option Key=Value]...
              --local-worker /ABS/WORKER --remote-worker /ABS/WORKER
              --local-model-dir /ABS/MODEL --remote-model-dir /ABS/MODEL
              --local-rdma-device NAME --remote-rdma-device NAME --coordinator RANK0_LINK_IPV4:PORT
              [--evidence final-row|none] [--prefill-schedule serial_v1|one_chunk_lookahead_v1]
              [--lifetime-seconds 10...300] [--startup-seconds N] [--request-seconds N] [--rank1-delay-seconds N]
              [--progress-timeout-ms N (default 60000)] [--allow-unguarded-jaccl yes]
              [--local-scratch-dir /ABS] [--remote-scratch-dir /ABS] [--keep-run-files yes] [--preflight-only yes]
          darkbloom-cluster-pair-check compare --reference REPORT.json --candidate REPORT.json
              [--near-tie-ulps N] [--allow-cut-difference yes] [--allow-schedule-difference yes]
              [--json yes] [--require VERDICT[,VERDICT]] [--model-dir /ABS/MODEL]
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
            case "compare": try await compare(Array(arguments.dropFirst()))
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
            "--token-ids-file", "--stop-token-ids", "--request-id", "--model-id"])
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
            guard (1...QualificationRequest.maximumPromptTokens).contains(length) else { throw Failure("--synthetic-tokens must be 1...8192") }
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
        let value = try QualificationRequest(requestID: id, promptTokenIDs: tokens, chunkSize: chunk,
            outputCount: count, stopTokenIDs: stops, promptSource: source, modelID: modelID)
        try QualificationFiles.writeNew(value.encoded(), to: URL(fileURLWithPath: output))
        print("request \(value.requestID) for \(value.modelID): \(tokens.count) prompt tokens, chunk \(chunk), \(count) outputs, prompt SHA-256 \(value.promptTokenIDsSHA256)")
    }

    static func run(_ arguments: [String]) async throws {
        let names: Set<String> = ["--request", "--stage-cut", "--report", "--remote-ssh", "--ssh-option",
            "--local-worker", "--remote-worker", "--local-model-dir", "--remote-model-dir",
            "--local-rdma-device", "--remote-rdma-device", "--coordinator", "--evidence", "--prefill-schedule",
            "--lifetime-seconds", "--startup-seconds", "--request-seconds", "--rank1-delay-seconds",
            "--progress-timeout-ms", "--local-scratch-dir", "--remote-scratch-dir", "--remote-command-prefix",
            "--preflight-only", "--allow-unguarded-jaccl", "--keep-run-files"]
        let fields = try parse(arguments, allowed: names, repeated: ["--ssh-option", "--remote-command-prefix"])
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
        let lifetime = try integer(fields, "--lifetime-seconds") ?? 240
        let delay = fields["--rank1-delay-seconds"]?.first.flatMap(Double.init) ?? 2
        let configuration = try PairConfiguration(request: request, stageCut: cut,
            local: .init(modelDirectory: try required("--local-model-dir"), workerPath: try required("--local-worker"),
                         rdmaDevice: try required("--local-rdma-device"), scratchDirectory: fields["--local-scratch-dir"]?.first ?? "/tmp"),
            remote: .init(modelDirectory: try required("--remote-model-dir"), workerPath: try required("--remote-worker"),
                          rdmaDevice: try required("--remote-rdma-device"), scratchDirectory: fields["--remote-scratch-dir"]?.first ?? "/tmp"),
            remoteTransport: transport, coordinator: try required("--coordinator"),
            prefillSchedule: fields["--prefill-schedule"]?.first ?? "serial_v1", recording: evidence == "final-row",
            lifetimeSeconds: lifetime, startupSeconds: try integer(fields, "--startup-seconds") ?? min(120, lifetime),
            requestSeconds: try integer(fields, "--request-seconds") ?? min(100, lifetime), rankOneDelaySeconds: delay,
            progressTimeoutMilliseconds: try integer(fields, "--progress-timeout-ms") ?? 60_000,
            requireProgressGuard: fields["--allow-unguarded-jaccl"]?.first != "yes",
            keepRunFiles: fields["--keep-run-files"]?.first == "yes",
            preflightOnly: fields["--preflight-only"]?.first == "yes", sensitive: sensitive)
        // Last resort for the driver itself: inspections, the workers' whole
        // lifetime, their exit, and collection, with room to spare.
        try QualificationDeadline.arm(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
            + UInt64(lifetime + 420) * 1_000_000_000, status: 124)
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
        lines.append("report: \(reportURL.lastPathComponent)")
        print(lines.joined(separator: "\n"))
        Darwin.exit(report.outcome == (configuration.preflightOnly ? "preflight" : "completed") ? 0 : 2)
    }

    static func compare(_ arguments: [String]) async throws {
        let fields = try parse(arguments, allowed: ["--reference", "--candidate", "--near-tie-ulps",
            "--allow-cut-difference", "--allow-schedule-difference", "--json", "--require", "--model-dir"])
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
        let reference = try QualificationReportFiles.subject(URL(fileURLWithPath: referencePath))
        let candidate = try QualificationReportFiles.subject(URL(fileURLWithPath: candidatePath))
        let comparison = try QualificationComparator(nearTieULPs: threshold,
            allowCutDifference: fields["--allow-cut-difference"]?.first == "yes",
            allowScheduleDifference: fields["--allow-schedule-difference"]?.first == "yes").compare(reference: reference, candidate: candidate)
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
