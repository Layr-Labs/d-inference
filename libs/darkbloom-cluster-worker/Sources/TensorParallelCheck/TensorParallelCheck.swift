import CryptoKit
import DarkbloomClusterRuntime
import Darwin
import Foundation
import MLX

// Tensor-parallel qualification for the dense Qwen 3.5-family models.
//
//   darkbloom-cluster-tp-check run --mode full|simulated|tp --model-dir DIR --request FILE --report FILE
//       [--backend jaccl|ring] [--timing lazy|explicit] [--record-top K] [--repeats N] [--warmup yes|no]
//       [--wired-residency yes|no] [--deadline-seconds S] [--output-count N]
//   darkbloom-cluster-tp-check compare --reference FILE --candidate FILE [--near-tie-ulps U]
//
// `full` is the unsharded model on one Mac (this code path's single-Mac
// reference); `simulated` is the single-process tensor-parallel oracle (the
// ranks' float32 partial sums added in one process); `tp` is one rank of a
// two-rank run, over JACCL (two Macs) or the local ring (two ranks on one Mac,
// correctness only). Greedy, no multi-token prediction, no prefix cache. A
// report names roles and chips only, never a host, an address or a path.

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func note(_ message: String) {
    FileHandle.standardError.write(Data(("[tp-check] " + message + "\n").utf8))
}

func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

func chipName() -> String {
    var size = 0
    guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return "unknown" }
    return String(cString: bytes)
}

/// The fields of a qualification request this tool reads.
struct Request: Decodable {
    let requestID: String
    let modelID: String
    let promptTokenIDs: [Int]
    let promptTokenIDsSHA256: String
    let outputCount: Int
    let chunkSize: Int
}

struct RunReport: Codable {
    var tokenIDs: [Int]
    var tokenIDsSHA256: String
    var firstTokenSeconds: Double
    var prefillTokensPerSecond: Double
    var decodeSeconds: Double
    var decodeTokensPerSecond: Double
    var stepP50Milliseconds: Double
    var stepP90Milliseconds: Double
    var stepMaxMilliseconds: Double
    var peakActiveBytes: Int
}

struct Report: Codable {
    var schema = "darkbloom_cluster_tp_check_report_v1"
    var mode: String
    var role: String
    var rank: Int
    var size: Int
    var backend: String?
    var timing: String?
    var correctnessOnly: Bool
    var chip: String
    var modelConfigurationSHA256: String
    var modelID: String
    var requestID: String
    var promptTokens: Int
    var promptTokenIDsSHA256: String
    var outputCount: Int
    var chunkSize: Int
    var environment: [String: String]
    var loadSeconds: Double
    var loadedActiveBytes: Int
    var loadedParameterBytes: Int
    var wiredResidencyBytes: Int?
    var reductionsPerForward: Int?
    var floatingReductions: Int?
    var runs: [RunReport] = []
    var topTokenIDs: [[Int]]?
    var topLogits: [[Float]]?
    var repeatsIdentical = false
    var ranksAgree: Bool?
    var passed = false
}

struct Options {
    var command = "run"
    var mode = "full"
    var modelDirectory = ""
    var request = ""
    var report = ""
    var backend = QwenTensorParallelGroup.Backend.jaccl
    var timing = QwenTensorParallelReductionTiming.lazy
    var recordTop = 0
    var repeats = 1
    var warmup = true
    var wiredResidency = true
    var deadlineSeconds = 900
    var outputCount: Int?
    var reference = ""
    var candidate = ""
    var nearTieULPs: Float = 4

    init(_ arguments: [String]) throws {
        guard let first = arguments.first, ["run", "compare"].contains(first) else {
            throw Failure("usage: darkbloom-cluster-tp-check run|compare ...")
        }
        command = first
        var index = 1
        func value() throws -> String {
            guard index + 1 < arguments.count else { throw Failure("\(arguments[index]) needs a value") }
            index += 1
            return arguments[index]
        }
        func yesNo(_ text: String) throws -> Bool {
            guard ["yes", "no"].contains(text) else { throw Failure("expected yes or no, got \(text)") }
            return text == "yes"
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--mode": mode = try value()
            case "--model-dir": modelDirectory = try value()
            case "--request": request = try value()
            case "--report": report = try value()
            case "--backend":
                guard let b = QwenTensorParallelGroup.Backend(rawValue: try value()) else { throw Failure("unknown backend") }
                backend = b
            case "--timing":
                guard let t = QwenTensorParallelReductionTiming(rawValue: try value()) else { throw Failure("unknown timing") }
                timing = t
            case "--record-top": recordTop = Int(try value()) ?? -1
            case "--repeats": repeats = Int(try value()) ?? 0
            case "--warmup": warmup = try yesNo(try value())
            case "--wired-residency": wiredResidency = try yesNo(try value())
            case "--deadline-seconds": deadlineSeconds = Int(try value()) ?? 0
            case "--output-count": outputCount = Int(try value())
            case "--reference": reference = try value()
            case "--candidate": candidate = try value()
            case "--near-tie-ulps": nearTieULPs = Float(try value()) ?? -1
            default: throw Failure("unknown argument \(arguments[index])")
            }
            index += 1
        }
        if command == "run" {
            guard ["full", "simulated", "tp"].contains(mode), !modelDirectory.isEmpty, !request.isEmpty, !report.isEmpty,
                  (0...64).contains(recordTop), (1...8).contains(repeats), (30...7200).contains(deadlineSeconds) else {
                throw Failure("run needs --mode full|simulated|tp, --model-dir, --request, --report and bounded options")
            }
            guard !FileManager.default.fileExists(atPath: report) else { throw Failure("the report file already exists") }
            if mode == "tp" && recordTop > 0 { throw Failure("a tp rank does not record logits") }
        } else {
            guard !reference.isEmpty, !candidate.isEmpty, nearTieULPs >= 0 else {
                throw Failure("compare needs --reference and --candidate")
            }
        }
    }
}

enum Statistics {
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, max(0, Int((p * Double(sorted.count - 1)).rounded())))]
    }
}

func tokenDigest(_ ids: [Int]) -> String { sha256Hex(Data(ids.map(String.init).joined(separator: ",").utf8)) }

func fnv(_ text: String) -> UInt64 {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3 }
    return hash
}

enum RunCommand {
    static func run(_ options: Options) throws -> Report {
        let requestData = try Data(contentsOf: URL(fileURLWithPath: options.request))
        guard requestData.count < 1 << 20 else { throw Failure("request file too large") }
        let request = try JSONDecoder().decode(Request.self, from: requestData)
        guard tokenDigest(request.promptTokenIDs) == request.promptTokenIDsSHA256 else {
            throw Failure("the request's prompt token digest does not match its tokens")
        }
        let outputCount = options.outputCount ?? request.outputCount
        guard (1...4096).contains(outputCount), (1...4096).contains(request.chunkSize) else { throw Failure("request bounds") }
        let directory = URL(fileURLWithPath: options.modelDirectory)
        let configurationSHA = sha256Hex(try Data(contentsOf: directory.appendingPathComponent("config.json")))
        let environment = ProcessInfo.processInfo.environment
        let recorded = ["MLX_METAL_FAST_SYNCH", "MLX_ENABLE_TF32", "DARKBLOOM_BF16_WEIGHTS",
                        "DARKBLOOM_CBV2_ATTN_QUERY_BLOCK", "MLX_QUANTIZED_CONSTANT_CACHE"]
        let snapshot = Dictionary(uniqueKeysWithValues: recorded.compactMap { key in environment[key].map { (key, $0) } })

        var group: QwenTensorParallelGroup?
        let role: QwenTensorParallelModel.Role
        switch options.mode {
        case "full": role = .full
        case "simulated": role = .simulated(size: 2)
        default:
            let g = try QwenTensorParallelGroup(backend: options.backend)
            group = g
            role = .shard(rank: g.rank, size: g.size)
            note("rank \(g.rank) of \(g.size) over \(options.backend.rawValue)\(options.backend == .ring ? " (correctness only, not a pair timing)" : "")")
            let workload = [Int32(outputCount), Int32(request.chunkSize), Int32(request.promptTokenIDs.count),
                            Int32(options.repeats), options.warmup ? 1 : 0, options.timing == .lazy ? 1 : 2]
            guard try g.agree(workload),
                  try g.digestsEqual(fnv(configurationSHA + request.promptTokenIDsSHA256 + snapshot.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";"))) else {
                throw Failure("the ranks disagree on the workload, the model configuration, the prompt or the arithmetic environment")
            }
        }

        note("loading \(role.label)")
        let model = try QwenTensorParallelModel.load(modelDirectory: directory, role: role, reduction: group,
                                                     timing: options.timing)
        note("loaded in \(String(format: "%.1f", model.loadSeconds)) s, active \(model.loadedActiveBytes) bytes")
        var residency: ProcessStageResidency?
        if options.wiredResidency {
            residency = try ProcessStageResidency(bytes: model.loadedActiveBytes + (4 << 30))
        }
        if let group { guard try group.agree([7]) else { throw Failure("load barrier failed") } }

        var report = Report(mode: options.mode, role: role.label, rank: group?.rank ?? 0, size: group?.size ?? 1,
            backend: group.map { options.backend.rawValue }, timing: group.map { _ in options.timing.rawValue },
            correctnessOnly: options.backend == .ring && group != nil, chip: chipName(),
            modelConfigurationSHA256: configurationSHA, modelID: request.modelID, requestID: request.requestID,
            promptTokens: request.promptTokenIDs.count, promptTokenIDsSHA256: request.promptTokenIDsSHA256,
            outputCount: outputCount, chunkSize: request.chunkSize, environment: snapshot,
            loadSeconds: model.loadSeconds, loadedActiveBytes: model.loadedActiveBytes,
            loadedParameterBytes: model.loadedParameterBytes, wiredResidencyBytes: residency?.receipt.appliedBytes,
            reductionsPerForward: group == nil ? nil : model.plan.reductionsPerForward)

        if options.warmup {
            let warm = Array(request.promptTokenIDs.prefix(min(64, request.promptTokenIDs.count)))
            _ = try model.generate(prompt: warm, outputCount: 4, chunk: request.chunkSize)
            Memory.clearCache()
            note("warmup done")
        }
        for index in 0..<options.repeats {
            Memory.peakMemory = 0
            let generation = try model.generate(prompt: request.promptTokenIDs, outputCount: outputCount,
                chunk: request.chunkSize, recordTop: index == 0 ? options.recordTop : 0)
            let steps = generation.stepSeconds
            let run = RunReport(tokenIDs: generation.tokenIDs, tokenIDsSHA256: tokenDigest(generation.tokenIDs),
                firstTokenSeconds: generation.firstTokenSeconds,
                prefillTokensPerSecond: Double(request.promptTokenIDs.count) / generation.firstTokenSeconds,
                decodeSeconds: generation.decodeSeconds,
                decodeTokensPerSecond: steps.isEmpty ? 0 : Double(steps.count) / generation.decodeSeconds,
                stepP50Milliseconds: Statistics.percentile(steps, 0.5) * 1e3,
                stepP90Milliseconds: Statistics.percentile(steps, 0.9) * 1e3,
                stepMaxMilliseconds: (steps.max() ?? 0) * 1e3, peakActiveBytes: generation.peakActiveBytes)
            report.runs.append(run)
            if index == 0 && options.recordTop > 0 {
                report.topTokenIDs = generation.topTokenIDs
                report.topLogits = generation.topLogits
            }
            note(String(format: "run %d: first token %.3f s (%.0f tok/s prefill), decode %.2f tok/s (p50 %.2f ms, p90 %.2f ms), tokens %@",
                        index, run.firstTokenSeconds, run.prefillTokensPerSecond, run.decodeTokensPerSecond,
                        run.stepP50Milliseconds, run.stepP90Milliseconds, String(run.tokenIDsSHA256.prefix(16))))
            Memory.clearCache()
        }
        report.repeatsIdentical = Set(report.runs.map(\.tokenIDsSHA256)).count == 1
        if let group {
            report.floatingReductions = group.floatingReductions
            report.ranksAgree = try group.digestsEqual(fnv(report.runs.map(\.tokenIDsSHA256).joined(separator: ",")))
            guard try group.agree([report.repeatsIdentical && report.ranksAgree == true ? 1 : 0]) else {
                report.passed = false
                return report
            }
            report.passed = report.repeatsIdentical && report.ranksAgree == true
        } else {
            report.passed = report.repeatsIdentical
        }
        residency?.end()
        return report
    }
}

/// The near-tie rule (D4): tokens equal, or the first differing token was, in
/// the reference, within `nearTieULPs` units in the last place (bfloat16, at the
/// reference's top logit) of the reference's own choice.
enum CompareCommand {
    struct Outcome: Encodable {
        var reference: String
        var candidate: String
        var verdict: String
        var equalPrefix: Int
        var compared: Int
        var firstDifference: Int?
        var referenceToken: Int?
        var candidateToken: Int?
        var referenceTop1Logit: Float?
        var referenceGapToCandidate: Float?
        var gapULPs: Float?
        var reasons: [String] = []
    }

    static func bf16ULP(_ value: Float) -> Float {
        guard value.isFinite, value != 0 else { return Float(sign: .plus, exponent: -133, significand: 1) }
        return Float(sign: .plus, exponent: value.exponent - 7, significand: 1)
    }

    static func run(_ options: Options) throws -> Outcome {
        let decoder = JSONDecoder()
        let reference = try decoder.decode(Report.self, from: Data(contentsOf: URL(fileURLWithPath: options.reference)))
        let candidate = try decoder.decode(Report.self, from: Data(contentsOf: URL(fileURLWithPath: options.candidate)))
        var outcome = Outcome(reference: "\(reference.role) on \(reference.chip)", candidate: "\(candidate.role) on \(candidate.chip)",
                              verdict: "incomparable", equalPrefix: 0, compared: 0)
        guard let left = reference.runs.first?.tokenIDs, let right = candidate.runs.first?.tokenIDs else {
            outcome.reasons.append("a report has no run"); return outcome
        }
        if reference.promptTokenIDsSHA256 != candidate.promptTokenIDsSHA256 || reference.modelConfigurationSHA256 != candidate.modelConfigurationSHA256
            || reference.chunkSize != candidate.chunkSize {
            outcome.reasons.append("the reports are for different prompts, models or chunk sizes"); return outcome
        }
        let count = min(left.count, right.count)
        outcome.compared = count
        var first: Int?
        for index in 0..<count where left[index] != right[index] { first = index; break }
        outcome.equalPrefix = first ?? count
        guard let index = first else {
            outcome.verdict = left.count == right.count ? "tokensEqual" : "tokensEqualPrefix"
            if left.count != right.count { outcome.reasons.append("output counts differ (\(left.count) vs \(right.count))") }
            return outcome
        }
        outcome.firstDifference = index
        outcome.referenceToken = left[index]
        outcome.candidateToken = right[index]
        guard let ids = reference.topTokenIDs, let logits = reference.topLogits, ids.indices.contains(index),
              logits[index].count >= 2 else {
            outcome.verdict = "diverged"
            outcome.reasons.append("the reference has no recorded logits at step \(index); a near tie cannot be shown")
            return outcome
        }
        let top1 = logits[index][0]
        outcome.referenceTop1Logit = top1
        guard let rank = ids[index].firstIndex(of: right[index]) else {
            outcome.verdict = "diverged"
            outcome.reasons.append("the candidate's token is not among the reference's top \(ids[index].count)")
            return outcome
        }
        let gap = top1 - logits[index][rank]
        outcome.referenceGapToCandidate = gap
        outcome.gapULPs = gap / bf16ULP(top1)
        outcome.verdict = gap <= options.nearTieULPs * bf16ULP(top1) ? "divergedAtNearTie" : "diverged"
        return outcome
    }
}

@main enum TensorParallelCheck {
    static func main() {
        do {
            let options = try Options(Array(CommandLine.arguments.dropFirst()))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            if options.command == "compare" {
                let outcome = try CompareCommand.run(options)
                print(String(decoding: try encoder.encode(outcome), as: UTF8.self))
                Darwin.exit(["tokensEqual", "divergedAtNearTie"].contains(outcome.verdict) ? 0 : 3)
            }
            try ProcessForcedExit.routeTerminationSignals()
            ProcessNativeMemoryRelease.installForForcedExit()
            try ProcessDeadline.arm(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
                + UInt64(options.deadlineSeconds) * 1_000_000_000, status: 124)
            let report = try RunCommand.run(options)
            let data = try encoder.encode(report)
            guard FileManager.default.createFile(atPath: options.report, contents: data) else {
                throw Failure("could not write the report")
            }
            note("report written; passed \(report.passed)")
            ProcessForcedExit.finish(status: report.passed ? 0 : 2, reason: "tp-check-complete")
        } catch {
            note("failed: \(error)")
            ProcessForcedExit.finish(status: 1, reason: "tp-check-error")
        }
    }
}
