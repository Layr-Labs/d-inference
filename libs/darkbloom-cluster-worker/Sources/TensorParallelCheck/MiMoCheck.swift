import DarkbloomClusterQualification
import DarkbloomClusterRuntime
import Darwin
import Foundation
import MLX

// MiMo V2.6 tensor-parallel oracles (MiMoTensorParallelModel), greedy, MTP off:
//
//   darkbloom-cluster-tp-check mimo synthesize --output /NEW/DIR [--variant kernel|tiny] [--seed N]
//       [--dtype bfloat16|float32] [--experts N --top-k K] [--mtp yes]
//       a random MiMo checkpoint (never a model pass), request.json (40-token prompt, longer than the window
//       and the 16-token chunk), request-short.json (6 tokens, shorter than both) and request-long.json
//       (192 tokens: three 64-token pages before decode), 64 outputs each
//   darkbloom-cluster-tp-check mimo run --mode full|simulated|shard|tp --model-dir DIR --request FILE --report FILE
//       [--record-top K] [--backend ring|socket|jaccl] [--reduction native|sealed-bench] [--shard-rank R]
//       [--deadline-seconds S] [--temperature T [--sample-seed S]] [--path contiguous|paged]
//       [--agreement-tamper yes] [--record-routes yes]
//       greedy, or with --temperature a keyed draw (MLXRandom.categorical, key seed + step) over the whole
//       row, which every rank gathers bit for bit. `--path paged` is the resident runtime's path: the
//       verified load (the manifest first, then only this rank's byte runs), paged KV, the per-step
//       agreement sum, 100-op decode buffers, greedy logprobs through the split top-k gather and sampling
//       with the product's QwenStageTokenSampler over the gathered row. `--agreement-tamper yes` changes this
//       rank's agreement (a tp rank must then refuse before loading). `--record-routes yes` (paged) records
//       every position's routed expert sets; `compare` then reports where they first differ.
//       `--mtp-depth D` (paged; a `--mtp yes` checkpoint) decodes in speculative rounds: D proposals a round
//       from the replicated trained heads, or with `--mtp-script REPORT` the tokens of an earlier report
//       (forced acceptance), every `--mtp-misses K`-th moved off so the target rejects it. Tensor-parallel
//       ranks only (simulated, shard, tp): `full` with `--mtp-depth` is refused before loading.
//   darkbloom-cluster-tp-check mimo compare --reference FILE --candidate FILE [--bitwise yes|no] [--near-tie-ulps U]
//   darkbloom-cluster-tp-check mimo allsum [--backend ring|socket|jaccl] [--count N]
//
// `full` is the unsharded model; `simulated` both ranks' shards in one
// process, each on its own thread and stream, every collective the FP32 sum
// of both ranks' partials (`tp` must equal it bit for bit, caches included);
// `shard` one rank with no peer (diagnostic: wrong tokens by construction);
// `tp` one rank of a two-rank run over JACCL (two Macs) or the local ring or
// socket (two processes on one Mac over 127.0.0.1, correctness only).
// `--reduction sealed-bench` seals every floating collective with the fork's
// sealed all-sum (BENCH keys from an unauthenticated ephemeral exchange: the
// sealed path's arithmetic and cost, never a product trust). `compare` holds
// a candidate to a reference with QualificationComparator; `--bitwise yes`
// also requires every token, recorded top logit, log probability, step row
// digest, the final row and each shared rank's cache digest to be identical.
// A report names roles and chips only, never a host, an address or a path.
enum MiMoCheck {
    struct Report: Codable {
        var schema = "darkbloom_cluster_tp_check_mimo_report_v1"
        var mode: String
        var role: String
        var rank: Int
        var size: Int
        var backend: String?
        var reduction: String?
        var correctnessOnly: Bool
        var chip: String
        var plan: String
        var planFingerprint: String
        var modelConfigurationSHA256: String
        var modelID: String
        var requestID: String
        var promptTokens: Int
        var promptTokenIDsSHA256: String
        var outputCount: Int
        var chunkSize: Int
        /// Set when the run sampled (the product's sampler over the gathered row).
        var temperature: Float?
        var sampleSeed: UInt64?
        var loadSeconds: Double
        var loadedParameterBytes: Int
        var reductionsPerForward: Int?
        var floatingReductions: Int?
        var tokenIDs: [Int]
        var tokenIDsSHA256: String
        var topTokenIDs: [[Int]]?
        var topLogits: [[Float]]?
        var topLogprobs: [[Float]]?
        var stepRowSHA256: [String]?
        var finalLogits: [Float]?
        /// Per rank (one entry for `full`), the KV caches' digest after the
        /// last step; nil for a rank this run does not hold.
        var cacheSHA256: [String?]
        var firstTokenSeconds: Double
        var decodeSeconds: Double
        var ranksAgree: Bool?
        var passed: Bool
        /// `paged`: the resident runtime's path, read through the verified load.
        var path: String?
        var verifiedAggregateSHA256: String?
        var readBytes: Int?
        var textBytes: Int?
        /// Per position (prompt, then each fed output token), each routed layer's experts.
        var routeSets: [[[Int]]]?
        /// Speculative rounds (`--mtp-depth`): proposals, how many were kept, kept per position.
        var speculativeDepth: Int?
        var speculativeProposals: String?
        var speculativeRounds: Int?
        var draftedTokens: Int?
        var acceptedDrafts: Int?
        var acceptedByPosition: [Int]?
        var draftHeadBytes: Int?
    }

    static func run(_ arguments: [String]) throws {
        guard let command = arguments.first else { throw Failure("mimo: synthesize, run, compare or allsum") }
        var fields: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            guard arguments[index].hasPrefix("--"), index + 1 < arguments.count else {
                throw Failure("mimo: arguments are --name value pairs")
            }
            fields[arguments[index]] = arguments[index + 1]
            index += 2
        }
        switch command {
        case "synthesize": try synthesize(fields)
        case "run": try runRank(fields)
        case "compare": try compare(fields)
        case "allsum": try allSum(fields)
        default: throw Failure("mimo: synthesize, run, compare or allsum")
        }
    }

    private static func synthesize(_ fields: [String: String]) throws {
        guard let output = fields["--output"], output.hasPrefix("/"), !FileManager.default.fileExists(atPath: output),
              let variant = MiMoTensorParallelModel.SyntheticVariant(rawValue: fields["--variant"] ?? "kernel"),
              let seed = UInt64(fields["--seed"] ?? "7"),
              let dtypeName = Optional(fields["--dtype"] ?? "bfloat16"), ["bfloat16", "float32"].contains(dtypeName),
              (fields["--experts"] == nil) == (fields["--top-k"] == nil),
              fields["--experts"].map({ Int($0) != nil }) ?? true, fields["--top-k"].map({ Int($0) != nil }) ?? true,
              ["yes", "no"].contains(fields["--mtp"] ?? "no") else {
            throw Failure("mimo synthesize needs --output /NEW/DIR [--variant kernel|tiny] [--seed N] [--dtype bfloat16|float32] [--experts N --top-k K] [--mtp yes]")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try MiMoTensorParallelModel.writeSyntheticCheckpoint(directory: directory, variant: variant, seed: seed,
            dtype: dtypeName == "float32" ? .float32 : .bfloat16,
            experts: fields["--experts"].flatMap { Int($0) }, topK: fields["--top-k"].flatMap { Int($0) },
            mtp: fields["--mtp"] == "yes")
        let vocabulary = MiMoTensorParallelModel.syntheticConfiguration(variant)["vocab_size"] as! Int
        for (name, count) in [("request.json", 40), ("request-short.json", 6), ("request-long.json", 192)] {
            let prompt = (0 ..< count).map { ($0 * 37 + 11) % vocabulary }
            let request: [String: Any] = ["requestID": "synthetic-mimo-\(count)",
                "modelID": "synthetic-mimo-v26-\(variant.rawValue)-\(dtypeName)-s\(seed)",
                "promptTokenIDs": prompt, "promptTokenIDsSHA256": tokenDigest(prompt), "outputCount": 64, "chunkSize": 16]
            try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
                .write(to: directory.appendingPathComponent(name))
        }
        note("synthetic MiMo checkpoint (\(variant.rawValue), \(dtypeName)) and requests written")
    }

    private static func runRank(_ fields: [String: String]) throws {
        guard let mode = fields["--mode"], ["full", "simulated", "shard", "tp"].contains(mode),
              let directory = fields["--model-dir"], let requestPath = fields["--request"],
              let reportPath = fields["--report"], !FileManager.default.fileExists(atPath: reportPath),
              let recordTop = Int(fields["--record-top"] ?? "8"), (0 ... 64).contains(recordTop),
              let shardRank = Int(fields["--shard-rank"] ?? "0"), (0 ... 1).contains(shardRank),
              let deadline = Int(fields["--deadline-seconds"] ?? "900"), (30 ... 7200).contains(deadline),
              ["native", "sealed-bench"].contains(fields["--reduction"] ?? "native"),
              fields["--temperature"].map({ Float($0).map { $0.isFinite && $0 > 0 } ?? false }) ?? true,
              fields["--sample-seed"].map({ UInt64($0) != nil }) ?? true,
              ["contiguous", "paged"].contains(fields["--path"] ?? "contiguous"),
              (fields["--agreement-tamper"] ?? "no") == "no" || (fields["--agreement-tamper"] == "yes" && fields["--mode"] == "tp"),
              (fields["--record-routes"] ?? "no") == "no" || (fields["--record-routes"] == "yes" && fields["--path"] == "paged"),
              fields["--mtp-depth"].map({ Int($0).map { (1 ... 3).contains($0) } ?? false }) ?? true,
              fields["--mtp-depth"] == nil || fields["--path"] == "paged",
              (fields["--mtp-script"] == nil && fields["--mtp-misses"] == nil) || fields["--mtp-depth"] != nil,
              fields["--mtp-misses"].map({ Int($0).map { $0 >= 0 } ?? false }) ?? true else {
            throw Failure("mimo run needs --mode full|simulated|shard|tp, --model-dir, --request, a new --report and bounded options")
        }
        // `MiMoV26TextModel.forwardVerifyWindow` throws on a whole model: refuse here, before the load.
        guard mode != "full" || fields["--mtp-depth"] == nil else {
            throw Failure("--mtp-depth needs --mode simulated, shard or tp: a speculative round's verify window "
                + "runs only on a tensor-parallel rank, not on the whole model (--mode full)")
        }
        var speculative: MiMoTensorParallelModel.SpeculativeOptions?
        if let depth = fields["--mtp-depth"].flatMap({ Int($0) }) {
            if let scriptPath = fields["--mtp-script"] {
                let script = try JSONDecoder().decode(Report.self, from: Data(contentsOf: URL(fileURLWithPath: scriptPath)))
                speculative = .init(depth: depth, proposals: .scripted(tokens: script.tokenIDs,
                    missEvery: Int(fields["--mtp-misses"] ?? "0")!))
            } else {
                speculative = .init(depth: depth, proposals: .heads)
            }
        }
        let sampling = fields["--temperature"].map {
            MiMoTensorParallelModel.Sampling(temperature: Float($0)!, seed: UInt64(fields["--sample-seed"] ?? "1")!)
        }
        let paged = fields["--path"] == "paged"
        let recordRoutes = fields["--record-routes"] == "yes"
        let sealed = (fields["--reduction"] ?? "native") == "sealed-bench"
        guard !sealed || mode == "tp" else { throw Failure("--reduction sealed-bench applies to a tp rank only") }
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
        let configurationData = try Data(contentsOf: modelDirectory.appendingPathComponent("config.json"))
        let configurationSHA = sha256Hex(configurationData)
        let plan = try MiMoTensorParallelPlan(configuration: configurationData)

        var group: QwenTensorParallelGroup?
        let role: MiMoTensorParallelModel.Role
        let reduction: QwenTensorParallelReduction?
        var pair: Gemma4TensorParallelLocalPair?
        switch mode {
        case "full": role = .full; reduction = nil
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
            var workload = "\(configurationSHA)|\(request.promptTokenIDsSHA256)|\(request.outputCount)|\(request.chunkSize)|top=\(recordTop)|sealed=\(sealed)|sampling=\(sampling.map { "\($0.temperature.bitPattern):\($0.seed)" } ?? "greedy")|\(plan.fingerprint)"
            if paged {
                // The resident runtime's load agreement: the plan, its arithmetic and the serving contract.
                workload += "|" + (MiMoTensorParallelPlan.arithmeticAgreementFields
                    + MiMoTensorParallelResidentRuntime.servingAgreementFields(chunkTokens: request.chunkSize)).joined(separator: "|")
            }
            if let speculative {
                var proposals = "heads"
                if case .scripted(let tokens, let missEvery) = speculative.proposals {
                    proposals = "script-\(tokenDigest(tokens))-\(missEvery)"
                }
                workload += "|mtp-depth=\(speculative.depth)|\(proposals)"
            }
            if fields["--agreement-tamper"] == "yes" { workload += "|tampered-on-rank-\(g.rank)" }
            guard try g.digestsEqual(fnv(workload)) else {
                throw Failure("the ranks disagree on the workload, the model configuration or the arithmetic contract")
            }
            if sealed {
                var scope = Data("darkbloom-tp-sealed-scope-v1|mimo-v26|".utf8)
                scope.append(Data(configurationSHA.utf8))
                let codec = try QwenTensorParallelSealCodec.bench(group: g, scope: scope)
                try codec.install()
                g.sealed = codec
                note("sealed all-sum installed (BENCH keys: unauthenticated ephemeral exchange; cost measurement only)")
            }
        }
        note("loading \(mode == "simulated" ? "both ranks in one process" : role.label)\(paged ? " (verified, this rank's byte runs)" : "")")
        var verified: (aggregate: String, readBytes: Int, textBytes: Int)?
        func load(_ role: MiMoTensorParallelModel.Role, _ reduction: QwenTensorParallelReduction?) throws -> MiMoTensorParallelModel {
            guard paged else { return try MiMoTensorParallelModel.load(modelDirectory: modelDirectory, role: role, reduction: reduction) }
            let value = try MiMoTensorParallelModel.loadVerified(modelDirectory: modelDirectory, role: role, reduction: reduction)
            if verified == nil { verified = (value.aggregateSHA256, value.readBytes, value.textBytes) }
            return value.model
        }
        var draftHeadBytes: Int?
        func loadHeads(_ model: MiMoTensorParallelModel) throws {
            guard let speculative, case .heads = speculative.proposals else { return }
            draftHeadBytes = try model.loadDraftHeads(modelDirectory: modelDirectory)
        }
        let model = try load(role, reduction)
        try loadHeads(model)
        note("loaded in \(String(format: "%.2f", model.loadSeconds)) s, \(model.loadedParameterBytes) parameter bytes"
            + (draftHeadBytes.map { ", draft heads \($0) bytes (replicated)" } ?? ""))
        if let group { guard try group.agree([7]) else { throw Failure("load barrier failed") } }
        let generation: MiMoTensorParallelModel.Generation
        var caches: [String?]
        var pairAgrees: Bool?
        if let pair {
            final class Ranks: @unchecked Sendable { let models: [MiMoTensorParallelModel]; init(_ m: [MiMoTensorParallelModel]) { models = m } }
            let peer = try load(.shard(rank: 1), pair.reduction(rank: 1))
            try loadHeads(peer)
            let ranks = Ranks([model, peer])
            let prompt = request.promptTokenIDs, count = request.outputCount, chunk = request.chunkSize
            let speculative = speculative
            let both = try Gemma4TensorParallelLocalPair.run(device: Device.defaultDevice()) { rank in
                paged ? try ranks.models[rank].generatePaged(prompt: prompt, outputCount: count, chunk: chunk,
                                                             recordTop: recordTop, sampling: sampling,
                                                             recordRoutes: recordRoutes, speculative: speculative)
                    : try ranks.models[rank].generate(prompt: prompt, outputCount: count, chunk: chunk,
                                                      recordTop: recordTop, sampling: sampling)
            }
            func bits(_ rows: [[Float]]) -> [[UInt32]] { rows.map { $0.map(\.bitPattern) } }
            pairAgrees = both[0].tokenIDs == both[1].tokenIDs && bits(both[0].topLogits) == bits(both[1].topLogits)
                && bits(both[0].topLogprobs) == bits(both[1].topLogprobs) && both[0].stepRowSHA256 == both[1].stepRowSHA256
                && both[0].finalLogits.map { $0.map(\.bitPattern) } == both[1].finalLogits.map { $0.map(\.bitPattern) }
            generation = both[0]
            caches = both.map(\.cacheSHA256)
        } else {
            generation = paged
                ? try model.generatePaged(prompt: request.promptTokenIDs, outputCount: request.outputCount,
                                          chunk: request.chunkSize, recordTop: recordTop, sampling: sampling,
                                          recordRoutes: recordRoutes, speculative: speculative)
                : try model.generate(prompt: request.promptTokenIDs, outputCount: request.outputCount,
                                     chunk: request.chunkSize, recordTop: recordTop, sampling: sampling)
            switch role {
            case .full: caches = [generation.cacheSHA256]
            case .shard(let rank): caches = (0 ..< 2).map { $0 == rank ? generation.cacheSHA256 : nil }
            }
        }
        let rank: Int
        if case .shard(let r) = role, pair == nil { rank = r } else { rank = 0 }
        var report = Report(mode: mode, role: mode == "simulated" ? "simulated-tp2" : role.label, rank: rank,
            size: group?.size ?? (pair == nil ? 1 : 2), backend: group?.backend.rawValue, reduction: sealed ? "sealed-bench" : nil,
            correctnessOnly: group.map { $0.backend.correctnessOnly } ?? false, chip: chipName(),
            plan: MiMoTensorParallelPlan.name, planFingerprint: plan.fingerprint, modelConfigurationSHA256: configurationSHA,
            modelID: request.modelID, requestID: request.requestID, promptTokens: request.promptTokenIDs.count,
            promptTokenIDsSHA256: request.promptTokenIDsSHA256, outputCount: request.outputCount,
            chunkSize: request.chunkSize, temperature: sampling?.temperature, sampleSeed: sampling?.seed,
            loadSeconds: model.loadSeconds, loadedParameterBytes: model.loadedParameterBytes,
            reductionsPerForward: mode == "full" ? nil : plan.reductionsPerForward,
            floatingReductions: group?.floatingReductions,
            tokenIDs: generation.tokenIDs, tokenIDsSHA256: tokenDigest(generation.tokenIDs),
            topTokenIDs: recordTop > 0 ? generation.topTokenIDs : nil, topLogits: recordTop > 0 ? generation.topLogits : nil,
            topLogprobs: recordTop > 0 ? generation.topLogprobs : nil,
            stepRowSHA256: recordTop > 0 ? generation.stepRowSHA256 : nil, finalLogits: generation.finalLogits,
            cacheSHA256: caches, firstTokenSeconds: generation.firstTokenSeconds, decodeSeconds: generation.decodeSeconds,
            ranksAgree: pairAgrees, passed: pairAgrees ?? true, path: paged ? "paged" : nil,
            verifiedAggregateSHA256: verified?.aggregate, readBytes: verified?.readBytes, textBytes: verified?.textBytes,
            routeSets: generation.routeSets, speculativeDepth: speculative?.depth,
            speculativeProposals: speculative.map { if case .heads = $0.proposals { return "heads" } else { return "script" } },
            speculativeRounds: generation.speculativeRounds, draftedTokens: generation.draftedTokens,
            acceptedDrafts: generation.acceptedDrafts, acceptedByPosition: generation.acceptedByPosition,
            draftHeadBytes: draftHeadBytes)
        if let group {
            // Ranks hold different caches; they must agree on everything else.
            let evidence = report.tokenIDsSHA256 + "|" + (generation.stepRowSHA256.last ?? "")
            report.ranksAgree = try group.digestsEqual(fnv(evidence))
            report.passed = try group.agree([report.ranksAgree == true ? 1 : 0])
        }
        note("tokens \(String(report.tokenIDsSHA256.prefix(16))): \(generation.tokenIDs.prefix(12).map(String.init).joined(separator: " "))…"
            + (report.ranksAgree.map { " ranks agree: \($0)" } ?? ""))
        if let rounds = generation.speculativeRounds {
            note("speculative rounds \(rounds): drafted \(generation.draftedTokens ?? 0), kept \(generation.acceptedDrafts ?? 0)"
                + " (by position \((generation.acceptedByPosition ?? []).map(String.init).joined(separator: "-")))")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard FileManager.default.createFile(atPath: reportPath, contents: try encoder.encode(report)) else {
            throw Failure("could not write the report")
        }
        note("report written; passed \(report.passed)")
        ProcessForcedExit.finish(status: report.passed ? 0 : 2, reason: "tp-check-mimo-complete")
    }

    /// QualificationComparator's verdict for two runs of one request, and
    /// with `--bitwise yes` the exact equality of everything recorded.
    private static func compare(_ fields: [String: String]) throws {
        guard let referencePath = fields["--reference"], let candidatePath = fields["--candidate"],
              let nearTie = Float(fields["--near-tie-ulps"] ?? "4"), nearTie >= 0,
              ["yes", "no"].contains(fields["--bitwise"] ?? "no") else {
            throw Failure("mimo compare needs --reference and --candidate [--bitwise yes|no] [--near-tie-ulps U]")
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
            let shared = zip(reference.cacheSHA256, candidate.cacheSHA256).filter { $0.0 != nil && $0.1 != nil }
            let equal = reference.tokenIDs == candidate.tokenIDs
                && bits(reference.topLogits) == bits(candidate.topLogits)
                && bits(reference.topLogprobs) == bits(candidate.topLogprobs)
                && reference.topTokenIDs == candidate.topTokenIDs
                && reference.stepRowSHA256 == candidate.stepRowSHA256 && reference.stepRowSHA256 != nil
                && reference.finalLogits.map { $0.map(\.bitPattern) } == candidate.finalLogits.map { $0.map(\.bitPattern) }
                && reference.finalLogits != nil
                && reference.cacheSHA256.count == candidate.cacheSHA256.count && !shared.isEmpty
                && shared.allSatisfy { $0.0 == $0.1 }
            lines.append("bitwise (tokens, top logits and log probabilities, every step's row, final row, \(shared.count) rank cache(s)): "
                + (equal ? "IDENTICAL" : "DIFFER"))
            passed = passed && equal
        }
        if let referenceRoutes = reference.routeSets, let candidateRoutes = candidate.routeSets {
            lines.append(routeDiagnostic(reference: referenceRoutes, candidate: candidateRoutes,
                promptTokens: reference.promptTokens,
                tokenDivergence: reference.tokenIDs.indices.first { index in
                    index >= candidate.tokenIDs.count || reference.tokenIDs[index] != candidate.tokenIDs[index]
                }))
        }
        lines.append("verdict \(comparison.verdict.rawValue); passed \(passed)")
        print(lines.joined(separator: "\n"))
        Darwin.exit(passed ? 0 : 3)
    }

    /// Where two runs' routed expert sets first differ, over the positions whose
    /// inputs are still equal: the prompt, then each output token fed back before
    /// the first token divergence. Reported, never required. Routed layers are
    /// numbered among the routed layers only.
    private static func routeDiagnostic(reference: [[[Int]]], candidate: [[[Int]]], promptTokens: Int,
                                        tokenDivergence: Int?) -> String {
        let comparable = min(reference.count, candidate.count, promptTokens + (tokenDivergence ?? Int.max / 2))
        var differing = 0, layers = 0
        var first: (position: Int, layer: Int)?
        for position in 0 ..< comparable {
            let count = min(reference[position].count, candidate[position].count)
            layers = max(layers, count)
            for layer in 0 ..< count where reference[position][layer] != candidate[position][layer] {
                differing += 1
                if first == nil { first = (position, layer) }
            }
        }
        var line = "route sets: \(comparable) positions x \(layers) routed layers with equal inputs (prompt \(promptTokens), "
            + "first token divergence \(tokenDivergence.map(String.init) ?? "none")): \(differing) differ"
        if let first {
            let place = first.position < promptTokens ? "prompt position \(first.position)" : "output \(first.position - promptTokens)"
            line += "; first at \(place), routed layer \(first.layer): reference \(reference[first.position][first.layer])"
                + " candidate \(candidate[first.position][first.layer])"
        }
        return line
    }

    /// One report as the comparator reads it. Each step's near-tie unit is a
    /// bfloat16 place: the head's logits are BF16 before selection widens them.
    private static func subject(_ report: Report) throws -> QualificationSubject {
        let identity: [String: Any] = [
            "modelID": report.modelID, "profileID": "tp-check-mimo", "requestID": report.requestID,
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

    /// Cross-rank sums at MiMo V2.6 Flash widths (hidden 4,096): one decode
    /// row, a 7-row verify window and a 2,048-token chunk, each `count` times,
    /// native and sealed.
    private static func allSum(_ fields: [String: String]) throws {
        guard let backend = QwenTensorParallelGroup.Backend(rawValue: fields["--backend"] ?? "ring"),
              let count = Int(fields["--count"] ?? "97"), (1 ... 10_000).contains(count) else {
            throw Failure("mimo allsum takes [--backend ring|socket|jaccl] [--count N]")
        }
        let group = try QwenTensorParallelGroup(backend: backend)
        note("rank \(group.rank) of \(group.size) over \(backend.rawValue)\(backend.correctnessOnly ? " (correctness only, not a pair timing)" : "")")
        let shapes = [[1, 1, 4096], [1, 7, 4096], [1, 2048, 4096]]
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
                note(String(format: "mimo allsum sealed=%d shape=%@ bytes=%d per_sum=%.3f ms max_error=%g", sealed ? 1 : 0,
                            shape.map(String.init).joined(separator: "x"), shape.reduce(4, *), each, error))
                guard error == 0 else { throw Failure("a cross-rank sum returned a wrong value") }
            }
        }
        try pass(sealed: false)
        let codec = try QwenTensorParallelSealCodec.bench(group: group, scope: Data("mimo-tp-allsum".utf8))
        try codec.install()
        group.sealed = codec
        try pass(sealed: true)
        note("mimo allsum passed")
    }
}
