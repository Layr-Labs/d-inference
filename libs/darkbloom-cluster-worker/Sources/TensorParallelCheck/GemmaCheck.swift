import DarkbloomClusterQualification
import DarkbloomClusterRuntime
import Darwin
import Foundation
import MLX

// Gemma 4 MoE tensor-parallel oracles (Gemma4TensorParallelModel), greedy:
//
//   darkbloom-cluster-tp-check gemma synthesize --output /NEW/DIR [--bits 4|8] [--seed N] [--dtype bfloat16|float32]
//       [--experts N --top-k K]
//       a tiny random Gemma 4 MoE checkpoint with the 26B's structure and request.json (never a model pass)
//   darkbloom-cluster-tp-check gemma run --mode full|split-sum|simulated|shard|tp --model-dir DIR --request FILE --report FILE
//       [--record-top K] [--backend ring|socket|jaccl] [--reduction native|sealed-bench] [--shard-rank R]
//       [--pack yes|no] [--path legacy|paged] [--deadline-seconds S]
//   darkbloom-cluster-tp-check gemma compare --reference FILE --candidate FILE [--bitwise yes|no] [--near-tie-ulps U]
//   darkbloom-cluster-tp-check gemma allsum [--backend ring|socket|jaccl] [--count N]
//
// `full` is the unsharded model; `simulated` the one-process oracle: both
// ranks' shards in one process, each on its own thread and stream, every
// collective the FP32 sum of both ranks' partials (`tp` must equal it bit for
// bit); `split-sum` the decomposition's oracle: the unsharded model whose
// row-parallel projections add both ranks' FP32 partials (bitwise to `tp` on
// the CPU; on an M5 Ultra GPU a 1,024-row prefill k_proj rounds some rows
// unlike its 512-row half); `shard` one rank's shard with no peer
// (diagnostic: wrong tokens by construction, one chip's share of the
// compute); `tp` one rank of a two-rank run over JACCL (two Macs) or the
// local ring or socket (two processes on one Mac over 127.0.0.1, correctness
// only). `--reduction sealed-bench` seals every floating collective with the
// fork's sealed all-sum (BENCH keys from an unauthenticated ephemeral
// exchange: the sealed path's arithmetic and cost, never a product trust).
// `compare` holds a candidate to a reference with QualificationComparator;
// `--bitwise yes` also requires every token, recorded top logit and log
// probability and the final row to be bit-identical (tp against simulated).
// `--path paged` runs every mode but split-sum through the resident runtime's
// own request path (`Gemma4TensorParallelModel.generatePaged`): paged KV with
// each rank's own heads, the product's CBv2 prompt entry under the registered
// prompt policy, and each step's token and stop flags agreed in the step's
// evaluation; `legacy` (the default) keeps the SDK's legacy caches.
// A report names roles and chips only, never a host, an address or a path.
enum GemmaCheck {
    struct Report: Codable {
        var schema = "darkbloom_cluster_tp_check_gemma_report_v1"
        var mode: String
        var role: String
        var rank: Int
        var size: Int
        var backend: String?
        var reduction: String?
        var correctnessOnly: Bool
        var chip: String
        var plan: String
        var modelConfigurationSHA256: String
        var modelID: String
        var requestID: String
        var promptTokens: Int
        var promptTokenIDsSHA256: String
        var outputCount: Int
        var chunkSize: Int
        var packedFeedForward: Bool
        var path: String?
        var loadSeconds: Double
        var loadedParameterBytes: Int
        var reductionsPerForward: Int?
        var floatingReductions: Int?
        var tokenIDs: [Int]
        var tokenIDsSHA256: String
        var topTokenIDs: [[Int]]?
        var topLogits: [[Float]]?
        var topLogprobs: [[Float]]?
        var finalLogits: [Float]?
        var firstTokenSeconds: Double
        var decodeSeconds: Double
        var ranksAgree: Bool?
        var passed: Bool
    }

    static func run(_ arguments: [String]) throws {
        guard let command = arguments.first else { throw Failure("gemma: synthesize, run, compare or allsum") }
        var fields: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            guard arguments[index].hasPrefix("--"), index + 1 < arguments.count else {
                throw Failure("gemma: arguments are --name value pairs")
            }
            fields[arguments[index]] = arguments[index + 1]
            index += 2
        }
        switch command {
        case "synthesize": try synthesize(fields)
        case "run": try runRank(fields)
        case "compare": try compare(fields)
        case "allsum": try allSum(fields)
        default: throw Failure("gemma: synthesize, run, compare or allsum")
        }
    }

    private static func synthesize(_ fields: [String: String]) throws {
        guard let output = fields["--output"], output.hasPrefix("/"), !FileManager.default.fileExists(atPath: output),
              let bits = Int(fields["--bits"] ?? "4"), [4, 8].contains(bits),
              let seed = UInt64(fields["--seed"] ?? "7"),
              let dtypeName = Optional(fields["--dtype"] ?? "bfloat16"), ["bfloat16", "float32"].contains(dtypeName),
              let experts = Int(fields["--experts"] ?? "16"), let topK = Int(fields["--top-k"] ?? "4") else {
            throw Failure("gemma synthesize needs --output /NEW/DIR [--bits 4|8] [--seed N] [--dtype bfloat16|float32] [--experts N --top-k K]")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try Gemma4TensorParallelModel.writeSyntheticCheckpoint(directory: directory, seed: seed, bits: bits,
            dtype: dtypeName == "float32" ? .float32 : .bfloat16, experts: experts, topK: topK)
        let prompt = (0 ..< 40).map { ($0 * 37 + 11) % 512 }
        let request: [String: Any] = ["requestID": "synthetic-gemma4", "modelID": "synthetic-gemma4-moe-tiny-\(bits)bit-\(dtypeName)-e\(experts)k\(topK)",
            "promptTokenIDs": prompt, "promptTokenIDsSHA256": tokenDigest(prompt), "outputCount": 24, "chunkSize": 16]
        try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("request.json"))
        note("synthetic Gemma 4 checkpoint (\(bits)-bit) and request written")
    }

    private static func runRank(_ fields: [String: String]) throws {
        guard let mode = fields["--mode"], ["full", "split-sum", "simulated", "shard", "tp"].contains(mode),
              let directory = fields["--model-dir"], let requestPath = fields["--request"],
              let reportPath = fields["--report"], !FileManager.default.fileExists(atPath: reportPath),
              let recordTop = Int(fields["--record-top"] ?? "8"), (0 ... 64).contains(recordTop),
              let shardRank = Int(fields["--shard-rank"] ?? "0"), (0 ... 1).contains(shardRank),
              let deadline = Int(fields["--deadline-seconds"] ?? "900"), (30 ... 7200).contains(deadline),
              ["native", "sealed-bench"].contains(fields["--reduction"] ?? "native"),
              ["yes", "no"].contains(fields["--pack"] ?? "yes"),
              ["legacy", "paged"].contains(fields["--path"] ?? "legacy") else {
            throw Failure("gemma run needs --mode full|split-sum|simulated|shard|tp, --model-dir, --request, a new --report and bounded options")
        }
        let paged = (fields["--path"] ?? "legacy") == "paged"
        guard !paged || mode != "split-sum" else { throw Failure("--path paged does not run the split-sum oracle") }
        let sealed = (fields["--reduction"] ?? "native") == "sealed-bench"
        guard !sealed || mode == "tp" else { throw Failure("--reduction sealed-bench applies to a tp rank only") }
        let pack = (fields["--pack"] ?? "yes") == "yes"
        try ProcessForcedExit.routeTerminationSignals()
        ProcessNativeMemoryRelease.installForForcedExit()
        try ProcessDeadline.arm(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + UInt64(deadline) * 1_000_000_000,
                                status: 124)
        let requestData = try Data(contentsOf: URL(fileURLWithPath: requestPath))
        guard requestData.count < 1 << 20 else { throw Failure("request file too large") }
        let request = try JSONDecoder().decode(Request.self, from: requestData)
        guard tokenDigest(request.promptTokenIDs) == request.promptTokenIDsSHA256,
              (1 ... 4096).contains(request.outputCount), (1 ... 4096).contains(request.chunkSize) else {
            throw Failure("the request's digest or bounds are wrong")
        }
        let modelDirectory = URL(fileURLWithPath: directory)
        let configurationSHA = sha256Hex(try Data(contentsOf: modelDirectory.appendingPathComponent("config.json")))

        var group: QwenTensorParallelGroup?
        let role: Gemma4TensorParallelModel.Role
        let reduction: QwenTensorParallelReduction?
        var pair: Gemma4TensorParallelLocalPair?
        switch mode {
        case "full": role = .full; reduction = nil
        case "split-sum": role = .splitSum; reduction = nil
        case "simulated":
            role = .shard(rank: 0)
            pair = Gemma4TensorParallelLocalPair()
            reduction = pair!.reduction(rank: 0)
        case "shard":
            role = .shard(rank: shardRank)
            reduction = QwenTensorParallelLocalReduction(rank: shardRank, size: 2)
            note("DIAGNOSTIC shard: rank \(shardRank)'s shard with no peer; tokens are not meaningful")
        default:
            guard let backend = QwenTensorParallelGroup.Backend(rawValue: fields["--backend"] ?? "ring") else {
                throw Failure("unknown backend")
            }
            let g = try QwenTensorParallelGroup(backend: backend)
            group = g
            role = .shard(rank: g.rank)
            reduction = g
            note("rank \(g.rank) of \(g.size) over \(backend.rawValue)\(backend.correctnessOnly ? " (correctness only, not a pair timing)" : "")")
            // Everything that changes the collectives is agreed before loading.
            let workload = "\(configurationSHA)|\(request.promptTokenIDsSHA256)|\(request.outputCount)|\(request.chunkSize)|top=\(recordTop)|pack=\(pack)|sealed=\(sealed)|paged=\(paged)|\(Gemma4TensorParallelPlan.arithmeticAgreementFields.joined(separator: ","))"
            guard try g.digestsEqual(fnv(workload)) else {
                throw Failure("the ranks disagree on the workload, the model configuration or the arithmetic contract")
            }
            if sealed {
                var scope = Data("darkbloom-tp-sealed-scope-v1|gemma4|".utf8)
                scope.append(Data(configurationSHA.utf8))
                let codec = try QwenTensorParallelSealCodec.bench(group: g, scope: scope)
                try codec.install()
                g.sealed = codec
                note("sealed all-sum installed (BENCH keys: unauthenticated ephemeral exchange; cost measurement only)")
            }
        }
        note("loading \(mode == "simulated" ? "both ranks in one process" : role.label)")
        let model = try Gemma4TensorParallelModel.load(modelDirectory: modelDirectory, role: role, reduction: reduction,
                                                       packFeedForward: pack)
        note("loaded in \(String(format: "%.2f", model.loadSeconds)) s, \(model.loadedParameterBytes) parameter bytes")
        if let group { guard try group.agree([7]) else { throw Failure("load barrier failed") } }
        let generation: Gemma4TensorParallelModel.Generation
        var pairAgrees: Bool?
        if let pair {
            final class Ranks: @unchecked Sendable { let models: [Gemma4TensorParallelModel]; init(_ m: [Gemma4TensorParallelModel]) { models = m } }
            let ranks = Ranks([model, try Gemma4TensorParallelModel.load(modelDirectory: modelDirectory,
                role: .shard(rank: 1), reduction: pair.reduction(rank: 1), packFeedForward: pack)])
            let prompt = request.promptTokenIDs, count = request.outputCount, chunk = request.chunkSize
            let both = try Gemma4TensorParallelLocalPair.run(device: Device.defaultDevice()) { rank in
                paged ? try ranks.models[rank].generatePaged(prompt: prompt, outputCount: count, chunk: chunk, recordTop: recordTop)
                    : try ranks.models[rank].generate(prompt: prompt, outputCount: count, chunk: chunk, recordTop: recordTop)
            }
            func bits(_ rows: [[Float]]) -> [[UInt32]] { rows.map { $0.map(\.bitPattern) } }
            pairAgrees = both[0].tokenIDs == both[1].tokenIDs && bits(both[0].topLogits) == bits(both[1].topLogits)
                && bits(both[0].topLogprobs) == bits(both[1].topLogprobs)
                && both[0].finalLogits.map { $0.map(\.bitPattern) } == both[1].finalLogits.map { $0.map(\.bitPattern) }
            generation = both[0]
        } else {
            generation = paged
                ? try model.generatePaged(prompt: request.promptTokenIDs, outputCount: request.outputCount,
                                          chunk: request.chunkSize, recordTop: recordTop)
                : try model.generate(prompt: request.promptTokenIDs, outputCount: request.outputCount,
                                     chunk: request.chunkSize, recordTop: recordTop)
        }
        var report = Report(mode: mode, role: mode == "simulated" ? "simulated-tp2" : role.label,
            rank: group?.rank ?? (mode == "shard" ? shardRank : 0),
            size: group?.size ?? (pair == nil ? 1 : 2), backend: group?.backend.rawValue, reduction: sealed ? "sealed-bench" : nil,
            correctnessOnly: group.map { $0.backend.correctnessOnly } ?? false, chip: chipName(),
            plan: Gemma4TensorParallelPlan.name, modelConfigurationSHA256: configurationSHA, modelID: request.modelID,
            requestID: request.requestID, promptTokens: request.promptTokenIDs.count,
            promptTokenIDsSHA256: request.promptTokenIDsSHA256, outputCount: request.outputCount,
            chunkSize: request.chunkSize, packedFeedForward: pack, path: paged ? "paged" : "legacy",
            loadSeconds: model.loadSeconds,
            loadedParameterBytes: model.loadedParameterBytes,
            reductionsPerForward: ["full", "split-sum"].contains(mode) ? nil : model.plan.reductionsPerForward,
            floatingReductions: group?.floatingReductions,
            tokenIDs: generation.tokenIDs, tokenIDsSHA256: tokenDigest(generation.tokenIDs),
            topTokenIDs: recordTop > 0 ? generation.topTokenIDs : nil, topLogits: recordTop > 0 ? generation.topLogits : nil,
            topLogprobs: recordTop > 0 ? generation.topLogprobs : nil, finalLogits: generation.finalLogits,
            firstTokenSeconds: generation.firstTokenSeconds, decodeSeconds: generation.decodeSeconds,
            ranksAgree: pairAgrees, passed: pairAgrees ?? true)
        if let group {
            let evidence = report.tokenIDsSHA256 + "|" + sha256Hex(Data((generation.finalLogits ?? []).flatMap {
                withUnsafeBytes(of: $0.bitPattern.littleEndian) { Array($0) } }))
            report.ranksAgree = try group.digestsEqual(fnv(evidence))
            report.passed = try group.agree([report.ranksAgree == true ? 1 : 0])
        }
        note("tokens \(String(report.tokenIDsSHA256.prefix(16))): \(generation.tokenIDs.prefix(12).map(String.init).joined(separator: " "))…"
            + (report.ranksAgree.map { " ranks agree: \($0)" } ?? ""))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard FileManager.default.createFile(atPath: reportPath, contents: try encoder.encode(report)) else {
            throw Failure("could not write the report")
        }
        note("report written; passed \(report.passed)")
        ProcessForcedExit.finish(status: report.passed ? 0 : 2, reason: "tp-check-gemma-complete")
    }

    /// QualificationComparator's verdict for two runs of one request, and
    /// with `--bitwise yes` the exact equality of everything recorded.
    private static func compare(_ fields: [String: String]) throws {
        guard let referencePath = fields["--reference"], let candidatePath = fields["--candidate"],
              let nearTie = Float(fields["--near-tie-ulps"] ?? "4"), nearTie >= 0,
              ["yes", "no"].contains(fields["--bitwise"] ?? "no") else {
            throw Failure("gemma compare needs --reference and --candidate [--bitwise yes|no] [--near-tie-ulps U]")
        }
        let decoder = JSONDecoder()
        let reference = try decoder.decode(Report.self, from: Data(contentsOf: URL(fileURLWithPath: referencePath)))
        let candidate = try decoder.decode(Report.self, from: Data(contentsOf: URL(fileURLWithPath: candidatePath)))
        let comparison = try QualificationComparator(nearTieULPs: nearTie)
            .compare(reference: try subject(reference), candidate: try subject(candidate))
        var lines = [QualificationComparator.render(comparison)]
        var passed = [.exact, .tokensEqualLogitsDiffer, .divergedAtNearTie].contains(comparison.verdict)
        if fields["--bitwise"] == "yes" {
            func bits(_ rows: [[Float]]?) -> [[UInt32]]? { rows.map { $0.map { $0.map(\.bitPattern) } } }
            let equal = reference.tokenIDs == candidate.tokenIDs
                && bits(reference.topLogits) == bits(candidate.topLogits)
                && bits(reference.topLogprobs) == bits(candidate.topLogprobs)
                && reference.topTokenIDs == candidate.topTokenIDs
                && reference.finalLogits.map { $0.map(\.bitPattern) } == candidate.finalLogits.map { $0.map(\.bitPattern) }
                && reference.finalLogits != nil
            lines.append("bitwise (tokens, top logits and log probabilities, final row): " + (equal ? "IDENTICAL" : "DIFFER"))
            passed = passed && equal
        }
        lines.append("verdict \(comparison.verdict.rawValue); passed \(passed)")
        print(lines.joined(separator: "\n"))
        Darwin.exit(passed ? 0 : 3)
    }

    /// One report as the comparator reads it: the request's identity (the
    /// generation mode recorded, not compared) and its evidence. Each step's
    /// near-tie unit is a bfloat16 place: the softcap's input is the head's
    /// BF16 projection.
    private static func subject(_ report: Report) throws -> QualificationSubject {
        let identity: [String: Any] = [
            "modelID": report.modelID, "profileID": "tp-check-gemma", "requestID": report.requestID,
            "promptTokenCount": report.promptTokens, "promptTokenIDsSHA256": report.promptTokenIDsSHA256,
            "chunkSize": report.chunkSize, "outputCount": report.outputCount, "stopTokenIDs": [Int](),
            "stageCut": 0, "prefillSchedule": "serial_v1", "artifactSHA256": report.modelConfigurationSHA256,
            "configurationSHA256": report.modelConfigurationSHA256, "planSHA256": sha256Hex(Data(report.plan.utf8)),
            "generationMode": report.mode,
        ]
        let decoded = try JSONDecoder().decode(QualificationIdentity.self,
            from: JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys]))
        var steps: [QualificationStep]?
        if let ids = report.topTokenIDs, let logits = report.topLogits, ids.count == report.tokenIDs.count {
            steps = report.tokenIDs.indices.map { index in
                QualificationStep(ordinal: index, frameSequence: index, committedTokens: report.promptTokens + index,
                    tokenID: report.tokenIDs[index], topTokenIDs: ids[index], topLogits: logits[index],
                    maximumTieCount: 1, rowSHA256: sha256Hex(Data(logits[index].flatMap {
                        withUnsafeBytes(of: $0.bitPattern.littleEndian) { Array($0) } })), rowDType: "bfloat16")
            }
        }
        var evidence = QualificationEvidence(selectedTokenIDs: report.tokenIDs, finishReason: "length",
            completedFrames: nil, committedTokens: report.promptTokens + report.tokenIDs.count, steps: steps)
        if let row = report.finalLogits {
            let bytes = Data(row.flatMap { withUnsafeBytes(of: $0.bitPattern.littleEndian) { Array($0) } })
            evidence.finalLogits = QualificationFinalLogits(shape: [row.count], dtype: "float32", byteCount: bytes.count,
                logicalBytesSHA256: sha256Hex(bytes), values: row)
        }
        return QualificationSubject(label: "\(report.role) on \(report.chip)", identity: decoded, evidence: evidence)
    }

    /// Cross-rank sums at Gemma 4 26B decode and prefill widths (2,816): the
    /// attention row, the packed feed-forward rows (top-8 + 1) and a 2,048-token
    /// chunk's attention rows, each `count` times, native and sealed.
    private static func allSum(_ fields: [String: String]) throws {
        guard let backend = QwenTensorParallelGroup.Backend(rawValue: fields["--backend"] ?? "ring"),
              let count = Int(fields["--count"] ?? "61"), (1 ... 10_000).contains(count) else {
            throw Failure("gemma allsum takes [--backend ring|socket|jaccl] [--count N]")
        }
        let group = try QwenTensorParallelGroup(backend: backend)
        note("rank \(group.rank) of \(group.size) over \(backend.rawValue)\(backend.correctnessOnly ? " (correctness only, not a pair timing)" : "")")
        let shapes = [[1, 1, 2816], [1, 9, 2816], [1, 2048, 2816]]
        func pass(sealed: Bool) throws {
            for shape in shapes {
                let value = MLXArray.ones(shape, dtype: .float32) * Float(group.rank + 1)
                eval(value)
                _ = try group.exchangeIntegers([1])
                let start = DispatchTime.now().uptimeNanoseconds
                var chained = value
                for _ in 0 ..< count { chained = group.allSum(chained) * 0.5 }
                eval(chained)
                let each = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 / Double(count)
                // (1 + 2) / 2 from the first sum on: any other value is a stale or torn read.
                let error = abs(chained - 1.5).max().item(Float.self)
                note(String(format: "gemma allsum sealed=%d shape=%@ bytes=%d per_sum=%.3f ms max_error=%g", sealed ? 1 : 0,
                            shape.map(String.init).joined(separator: "x"), shape.reduce(4, *), each, error))
                guard error == 0 else { throw Failure("a cross-rank sum returned a wrong value") }
            }
        }
        try pass(sealed: false)
        let codec = try QwenTensorParallelSealCodec.bench(group: group, scope: Data("gemma-tp-allsum".utf8))
        try codec.install()
        group.sealed = codec
        try pass(sealed: true)
        note("gemma allsum passed")
    }
}
