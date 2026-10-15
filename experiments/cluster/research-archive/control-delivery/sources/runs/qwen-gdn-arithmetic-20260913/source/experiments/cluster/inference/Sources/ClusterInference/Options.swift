import Foundation

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Options {
    enum ExecutionPath: String { case ordinary, cbv2Contiguous = "cbv2-contiguous" }
    enum Mode: String {
        case baseline, ffnTP = "ffn-tp", localParity = "local-parity"
        case loaderParity = "loader-parity", operatorParity = "operator-parity", capability
        case tokenSelectionCheck = "token-selection-check"
        case worker, workerTP = "worker-tp", workerProtocolCheck = "worker-protocol-check"
        case adapterCheck = "adapter-check", gemmaLoaderCheck = "gemma-loader-check"
        case qwenOutputCheck = "qwen-output-check"
        case qwenGDNInputCheck = "qwen-gdn-input-check"
        case qwenGDNArithmeticCheck = "qwen-gdn-arithmetic-check"
        var isGDNDiagnostic: Bool { self == .qwenGDNInputCheck || self == .qwenGDNArithmeticCheck }
        var isWorker: Bool { self == .worker || self == .workerTP }
    }
    var mode = Mode.baseline
    var transport = ClusterTransport.jaccl
    var partition = QwenPartitionKind.ffn
    var attentionOutputPrecision = AttentionOutputPrecision.native
    var ffnOutputPrecision = FFNOutputPrecision.native
    var ffnBranchPrecision = FFNBranchPrecision.native
    var executionPath = ExecutionPath.ordinary
    var localCorrectness = false
    var expectedArtifactAggregateSHA256: String?
    var modelDirectory: URL?
    var synthetic = false
    var syntheticDType: String = "float32"
    var syntheticProfile: String = "tiny"
    var promptCount = 128
    var chunkSize = 128
    var decodeCount = 16
    var repeats = 3
    var warmups = 1
    var seed: UInt64 = 7
    var timeoutSeconds = 300
    var epoch: String?
    var tokensFile: URL?
    var logitsFile: URL?
    var teacherTokensFile: URL?
    var routingFile: URL?
    var routingReplayFile: URL?
    var gemmaDiagnostic = false
    var gemmaBoundaryFile: URL?
    var hasRoutingDiagnostic: Bool { routingFile != nil || routingReplayFile != nil }

    static let usage = """
    cluster-inference --mode baseline|ffn-tp|worker|worker-tp|worker-protocol-check|adapter-check|gemma-loader-check|qwen-output-check|qwen-gdn-input-check|qwen-gdn-arithmetic-check|local-parity|loader-parity|operator-parity|token-selection-check|capability
      --model-dir PATH | --synthetic
      [--transport jaccl|loopback-test]
      [--local-correctness --artifact-aggregate-sha256 HEX64]
      [--partition ffn|full]
      [--execution-path ordinary|cbv2-contiguous]
      [--attention-output-precision native|float32]
      [--ffn-output-precision native|float32] (dense Qwen only)
      [--ffn-branch-precision native|float32|float32-through-norm] (Gemma only)
      [--synthetic-dtype float32|bfloat16]
      [--synthetic-profile tiny|qwen9-heads|qwen27-heads|qwen-moe|gemma-moe|gemma-moe-w8]
      [--prompt-tokens 128] [--chunk-size 128] [--decode-tokens 16]
      [--repeats 3] [--warmups 1] [--seed 7]
      [--timeout-seconds 300]
      [--epoch HEX32] (required for persistent worker modes)
      [--tokens-file JSON] [--teacher-tokens-file JSON] [--logits-file PATH]
      [--routing-file PATH | --routing-replay-file BASELINE_TRACE]
      [--gemma-diagnostic [--gemma-boundary-file PATH]]

    Token files contain arrays of integer token IDs. Without a token file, the
    prompt is a deterministic synthetic token sequence; it is not natural text.
    TP selects rank zero's argmax and synchronizes it before continuation.
    Optional teacher tokens fix continuation for numerical comparisons.
    Timing includes synchronized model execution, excludes weight loading, and
    reports prefill through the first generated token separately from decode.
    TP requires exactly two JACCL ranks. Configure MLX_RANK, MLX_IBV_DEVICES,
    and MLX_JACCL_COORDINATOR identically to the transport probe.
    Explicit --transport loopback-test requires synthetic cooperative execution,
    or --local-correctness for bounded real dense Qwen one-shot TP.
    It uses MLX_RANK and MLX_HOSTFILE with two 127.0.0.1 ports to test real
    multi-process collectives locally. It is not an RDMA or performance test.
    Real local correctness requires a pinned aggregate, prompt/logit files,
    prompt<=128, chunk<=32, output<=4, teacher history for multiple outputs,
    one repetition, zero warmups and timeout<=180. Workers cannot use it.
    Routing capture is a bounded synthetic qwen-moe diagnostic: baseline or
    ffn-tp, zero warmups, one repetition, at most 512 prompt and 32 output
    tokens, with logits and teacher-token files. Its timings are invalid.
    Routing replay deliberately substitutes baseline router logits to diagnose
    expert-selection amplification. It cannot qualify ordinary inference.
    Float32 attention-output precision widens attention/GDN output projections
    and their reductions, then casts once to the incoming activation dtype.
    Float32 FFN-output precision applies the same arithmetic to dense Qwen's
    down projection. It leaves gate/up projections and activation unchanged.
    qwen-output-check isolates final norm/head arithmetic on the same hidden
    tensor; it requires native policies, at most 512 prompt tokens, one output,
    one repetition and zero warmups. It is never a throughput measurement.
    qwen-gdn-input-check captures the first GDN's normalized input and compares
    reconstructed full/selected fused projections. It requires native CBv2,
    one chunk of 1...32 tokens, one output/run, zero warmups and timeout<=180.
    Real artifacts require a token file and --artifact-aggregate-sha256 HEX64.
    This solo diagnostic has no transport and never qualifies throughput.
    qwen-gdn-arithmetic-check uses the same admission and unchanged model forward,
    then compares FP32 reconstructed projections and native projections padded to
    full output width. It reports partition agreement and departure from native.
    Gemma Float32 FFN-branch precision widens after the ordinary input norm,
    retains Float32 through projections, expert weighting and branch reduction,
    then casts once before each output norm. Router arithmetic stays unchanged.
    Gemma diagnostics evaluate full logits after each explicit prompt chunk,
    drain optional boundary captures before advancing, and invalidate timings.
    They require a Gemma synthetic one-run baseline/TP, at most128 prompt and
    16 output tokens, zero warmups, and logits plus teacher-token files.
    cbv2-contiguous selects dense Qwen's production model/state interfaces with
    request-owned contiguous KV. It does not enable production scheduling or MTP.
    Persistent workers read bounded version-5 JSONL commands from stdin and emit
    JSONL events. Each request gets a fresh cache; weights stay loaded. Fixed-count
    greedy text generation only, with no production batching or state handoff.
    timeout-seconds bounds startup and idle time; each request supplies its own
    bounded timeout. Cancellation retires the entire worker epoch externally.
    """

    init(arguments: [String]) throws {
        var i = 0
        var explicitSyntheticDType = false
        var explicitSyntheticProfile = false
        var benchmarkFlags = Set<String>()
        while i < arguments.count {
            let flag = arguments[i]
            if flag == "--help" { print(Self.usage); exit(0) }
            if flag == "--synthetic" { synthetic = true; i += 1; continue }
            if flag == "--local-correctness" { localCorrectness = true; i += 1; continue }
            if flag == "--gemma-diagnostic" { gemmaDiagnostic = true; i += 1; continue }
            guard i + 1 < arguments.count else { throw ProbeError("Missing value for \(flag)") }
            let value = arguments[i + 1]
            if ["--prompt-tokens", "--chunk-size", "--decode-tokens", "--repeats", "--warmups"].contains(flag) {
                benchmarkFlags.insert(flag)
            }
            func integer() throws -> Int {
                guard let n = Int(value) else { throw ProbeError("Invalid integer for \(flag)") }
                return n
            }
            switch flag {
            case "--mode":
                guard let parsed = Mode(rawValue: value) else { throw ProbeError("Unknown mode \(value)") }
                mode = parsed
            case "--transport":
                guard let parsed = ClusterTransport(rawValue: value) else {
                    throw ProbeError("Unknown transport \(value)")
                }
                transport = parsed
            case "--partition":
                guard let parsed = QwenPartitionKind(rawValue: value) else { throw ProbeError("Unknown partition \(value)") }
                partition = parsed
            case "--model-dir": modelDirectory = URL(fileURLWithPath: value)
            case "--artifact-aggregate-sha256": expectedArtifactAggregateSHA256 = value
            case "--attention-output-precision":
                guard let parsed = AttentionOutputPrecision(rawValue: value) else {
                    throw ProbeError("Unsupported attention output precision")
                }
                attentionOutputPrecision = parsed
            case "--ffn-output-precision":
                guard let parsed = FFNOutputPrecision(rawValue: value) else {
                    throw ProbeError("FFN output precision must be native or float32")
                }
                ffnOutputPrecision = parsed
            case "--ffn-branch-precision":
                guard let parsed = FFNBranchPrecision(rawValue: value) else {
                    throw ProbeError("FFN branch precision must be native, float32 or float32-through-norm")
                }
                ffnBranchPrecision = parsed
            case "--execution-path":
                guard let parsed = ExecutionPath(rawValue: value) else {
                    throw ProbeError("Execution path must be ordinary or cbv2-contiguous")
                }
                executionPath = parsed
            case "--synthetic-dtype":
                guard ["float32", "bfloat16"].contains(value) else { throw ProbeError("Unsupported synthetic dtype") }
                syntheticDType = value; explicitSyntheticDType = true
            case "--synthetic-profile":
                guard ["tiny", "qwen9-heads", "qwen27-heads", "qwen-moe", "gemma-moe", "gemma-moe-w8"].contains(value) else {
                    throw ProbeError("Unsupported synthetic profile")
                }
                syntheticProfile = value; explicitSyntheticProfile = true
            case "--prompt-tokens": promptCount = try integer()
            case "--chunk-size": chunkSize = try integer()
            case "--decode-tokens": decodeCount = try integer()
            case "--repeats": repeats = try integer()
            case "--warmups": warmups = try integer()
            case "--timeout-seconds": timeoutSeconds = try integer()
            case "--epoch": epoch = value
            case "--seed":
                guard let n = UInt64(value) else { throw ProbeError("Invalid seed") }; seed = n
            case "--tokens-file": tokensFile = URL(fileURLWithPath: value)
            case "--teacher-tokens-file": teacherTokensFile = URL(fileURLWithPath: value)
            case "--logits-file": logitsFile = URL(fileURLWithPath: value)
            case "--routing-file": routingFile = URL(fileURLWithPath: value)
            case "--routing-replay-file": routingReplayFile = URL(fileURLWithPath: value)
            case "--gemma-boundary-file": gemmaBoundaryFile = URL(fileURLWithPath: value)
            default: throw ProbeError("Unknown option \(flag)")
            }
            i += 2
        }
        guard mode == .capability || mode == .workerProtocolCheck || mode == .adapterCheck || synthetic != (modelDirectory != nil) else {
            throw ProbeError("Choose exactly one of --synthetic and --model-dir")
        }
        guard !explicitSyntheticDType || synthetic else { throw ProbeError("synthetic-dtype requires --synthetic") }
        guard !explicitSyntheticProfile || synthetic else { throw ProbeError("synthetic-profile requires --synthetic") }
        guard attentionOutputPrecision == .native || mode == .baseline || mode == .ffnTP || mode.isWorker else {
            throw ProbeError("Attention output precision applies to baseline or cooperative execution")
        }
        guard ffnOutputPrecision == .native ||
            ((mode == .baseline || mode == .ffnTP || mode.isWorker)
                && (!synthetic || ["tiny", "qwen9-heads", "qwen27-heads"].contains(syntheticProfile))) else {
            throw ProbeError("Float32 FFN output precision requires dense Qwen baseline or cooperative execution")
        }
        guard ffnBranchPrecision == .native ||
            ((mode == .baseline || mode == .ffnTP || mode.isWorker)
                && (!synthetic || syntheticProfile.hasPrefix("gemma-"))) else {
            throw ProbeError("Float32 FFN branch precision requires Gemma baseline or cooperative execution")
        }
        guard mode != .tokenSelectionCheck || (synthetic && transport == .loopbackTest) else {
            throw ProbeError("token-selection-check requires synthetic weights and explicit loopback-test transport")
        }
        guard promptCount > 0, chunkSize > 0, decodeCount > 0, repeats > 0, warmups >= 0 else {
            throw ProbeError("Counts must be positive (warmups may be zero)")
        }
        if executionPath == .cbv2Contiguous {
            guard (mode == .baseline || mode == .ffnTP || mode.isWorker || mode.isGDNDiagnostic),
                !synthetic || ["tiny", "qwen9-heads", "qwen27-heads"].contains(syntheticProfile),
                ffnBranchPrecision == .native, !hasRoutingDiagnostic,
                !gemmaDiagnostic, gemmaBoundaryFile == nil else {
                throw ProbeError("cbv2-contiguous requires dense Qwen baseline or cooperative execution")
            }
            guard decodeCount <= 4096, promptCount <= 32768 - decodeCount, chunkSize <= 32768 else {
                throw ProbeError("cbv2-contiguous exceeds request context/output/chunk limits")
            }
        }
        guard !(mode == .localParity || mode == .loaderParity || mode == .operatorParity) || synthetic else {
            throw ProbeError("Parity modes are restricted to the bounded synthetic Qwen model")
        }
        guard partition != .full || mode == .ffnTP || mode == .workerTP || mode == .operatorParity || mode == .loaderParity else {
            throw ProbeError("Full partition requires cooperative TP, loader-parity or operator-parity mode")
        }
        guard (1...86400).contains(timeoutSeconds) else {
            throw ProbeError("timeout-seconds must be between 1 and 86400")
        }
        guard transport != .loopbackTest || localCorrectness || (synthetic && (mode == .ffnTP || mode == .workerTP || mode == .tokenSelectionCheck)) else {
            throw ProbeError("loopback-test requires synthetic execution or explicit bounded local-correctness")
        }
        if mode.isGDNDiagnostic { try QwenGDNInputAdmission.validateOptions(self) }
        else { try LocalCorrectness.validateOptions(self) }
        if mode.isWorker {
            guard let epoch, epoch.count == 32, epoch.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                benchmarkFlags.isEmpty, tokensFile == nil, teacherTokensFile == nil,
                logitsFile == nil, !hasRoutingDiagnostic
            else { throw ProbeError("Workers require --epoch HEX32 and receive all request inputs through JSONL commands") }
        } else if epoch != nil {
            throw ProbeError("epoch is only valid for persistent workers")
        }
        if syntheticProfile.hasPrefix("gemma-") {
            guard partition == .ffn, attentionOutputPrecision == .native,
                ![Mode.localParity, .loaderParity, .operatorParity].contains(mode) else {
                throw ProbeError("Gemma fixtures use native FFN plans and Gemma-specific loader checks")
            }
        }
        if mode == .gemmaLoaderCheck {
            guard synthetic, syntheticProfile.hasPrefix("gemma-") else {
                throw ProbeError("gemma-loader-check requires a bounded Gemma synthetic fixture")
            }
        }
        if mode == .qwenOutputCheck {
            guard executionPath == .ordinary, attentionOutputPrecision == .native,
                ffnOutputPrecision == .native, ffnBranchPrecision == .native,
                !synthetic || ["tiny", "qwen9-heads", "qwen27-heads"].contains(syntheticProfile),
                promptCount <= 512, chunkSize <= 512, decodeCount == 1,
                repeats == 1, warmups == 0, teacherTokensFile == nil,
                logitsFile == nil, !hasRoutingDiagnostic, !gemmaDiagnostic else {
                throw ProbeError("qwen-output-check requires bounded dense Qwen ordinary/native execution, one output/run, zero warmups and no other diagnostics")
            }
        }
        if hasRoutingDiagnostic {
            guard synthetic, syntheticProfile == "qwen-moe", mode == .baseline || mode == .ffnTP,
                warmups == 0, repeats == 1, promptCount <= 512, decodeCount <= 32,
                logitsFile != nil, teacherTokensFile != nil,
                !(routingFile != nil && routingReplayFile != nil),
                (routingFile ?? routingReplayFile)?.standardizedFileURL != logitsFile?.standardizedFileURL
            else { throw ProbeError("Routing diagnostics require a bounded one-run synthetic MoE fixture, one diagnostic mode, distinct logits and routing files, and teacher tokens") }
        }
        guard gemmaBoundaryFile == nil || gemmaDiagnostic else {
            throw ProbeError("Gemma boundary capture requires the explicit diagnostic schedule")
        }
        if gemmaDiagnostic {
            guard synthetic, syntheticProfile.hasPrefix("gemma-"), mode == .baseline || mode == .ffnTP,
                warmups == 0, repeats == 1, promptCount <= 128, decodeCount <= 16,
                logitsFile != nil, teacherTokensFile != nil, !hasRoutingDiagnostic,
                gemmaBoundaryFile?.standardizedFileURL != logitsFile?.standardizedFileURL else {
                throw ProbeError("Gemma diagnostics require bounded synthetic baseline/TP, zero warmups, one run and distinct logits/capture plus teacher files")
            }
        }
    }
}

func emitJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data + Data([10]))
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
