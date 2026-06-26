// batch-bench — batched single-node decode benchmark.
//
//   swift run -c release batch-bench <model-dir> [batchSize] [maxTokens] [iterations]
//
// Companion to `solo-bench`. Where solo-bench measures one request at a time,
// this harness submits B concurrent decode requests through the SAME
// continuous-batching path the provider serves production traffic with
// (`BatchScheduler` → `BatchedEngine`), and reports the AGGREGATE decode
// throughput. Comparing aggregate tok/s at B>1 against the B=1 number
// quantifies the continuous-batching throughput multiplier — how much more
// total work one box does when it folds N requests into one batched forward
// pass instead of running them serially.
//
// Approach: use `BatchScheduler` directly (the production scheduler), not a
// lower-level batched generate. The scheduler is a self-contained actor:
// `init` → `loadModel(container:modelId:)` → N concurrent `submitTokenized`
// calls that the engine coalesces into batched forward passes → drain each
// request's `AsyncStream<GenerationEvent>`. No coordinator, no networking, no
// HTTP server needed. This is both the simplest standalone path AND the most
// representative of production decode.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import ProviderCore

func die(_ m: String) -> Never { FileHandle.standardError.write(Data("ERROR: \(m)\n".utf8)); exit(1) }

let argv = CommandLine.arguments
guard argv.count >= 2 else {
    die("usage: batch-bench <model-dir> [batchSize=4] [maxTokens=96] [iterations=4]")
}
let modelDir = URL(fileURLWithPath: argv[1], isDirectory: true)
let batchSize = argv.count > 2 ? max(1, Int(argv[2]) ?? 4) : 4
let maxTokens = argv.count > 3 ? (Int(argv[3]) ?? 96) : 96
let iterations = argv.count > 4 ? (Int(argv[4]) ?? 4) : 4

// Match the cluster/solo runs' GPU memory posture.
let physical = ProcessInfo.processInfo.physicalMemory
MLX.GPU.set(memoryLimit: Int(Double(physical) * 0.80), relaxed: false)

print(
    "batch-bench: \(modelDir.lastPathComponent), batchSize=\(batchSize), "
        + "maxTokens=\(maxTokens), iterations=\(iterations)")

// Load the model container exactly as the provider does (same API as solo-bench).
let container = try await LLMModelFactory.shared.loadContainer(
    from: modelDir, using: LocalTokenizerLoader())

// Tokenizer for prompt → token IDs. We tokenize ourselves and feed the
// scheduler's `submitTokenized` (the same entry the OpenAI bridge uses),
// rather than the higher-level `submit(ChatCompletionRequest:)`, so the
// benchmark prompt path is minimal and explicit.
let tokenizer = try await LocalTokenizerLoader().load(from: modelDir)

// One scheduler instance, sized so all B requests can be co-resident in a
// single batch (maxConcurrentRequests == batchSize). kvBudget=nil keeps the
// default per-model budget. This is the production scheduler — concurrent
// submits are coalesced into batched forward passes by the engine.
let scheduler = BatchScheduler(
    maxConcurrentRequests: batchSize,
    defaultMaxTokens: maxTokens)
await scheduler.loadModel(container: container, modelId: modelDir.lastPathComponent)
print("model loaded.\n")

/// Build the prompt-token list for request `index`. We vary each prompt
/// slightly (append the index) so identical-prefix caching doesn't collapse
/// the batch into one shared-KV degenerate case — we want B genuinely
/// independent decodes sharing one batched forward pass.
func promptTokens(forIndex index: Int) throws -> [Int] {
    let content = "Explain pipeline parallelism in two sentences. (variant #\(index))"
    let messages: [[String: any Sendable]] = [["role": "user", "content": content]]
    return try tokenizer.applyChatTemplate(
        messages: messages, tools: nil, additionalContext: nil)
}

/// Result of draining one request's event stream.
struct RequestResult: Sendable {
    let completionTokens: Int
    let startedAt: ContinuousClock.Instant
    let firstTokenAt: ContinuousClock.Instant?
    let finishedAt: ContinuousClock.Instant
}

/// Submit one request and drain its stream to completion, timing it.
func runOne(index: Int) async throws -> RequestResult {
    let tokens = try promptTokens(forIndex: index)
    let started = ContinuousClock.now
    var firstTokenAt: ContinuousClock.Instant?
    var completion = 0
    let stream = await scheduler.submitTokenized(
        promptTokens: tokens,
        maxTokens: maxTokens,
        temperature: 0.0,
        requestId: "bench-\(index)-\(UUID().uuidString.prefix(8))")
    for await event in stream {
        switch event {
        case .chunk:
            if firstTokenAt == nil { firstTokenAt = .now }
            completion += 1
        case .info(_, let completionTokens, _):
            if completionTokens > completion { completion = completionTokens }
        case .error(let message):
            die("request \(index) failed: \(message)")
        }
    }
    return RequestResult(
        completionTokens: completion,
        startedAt: started,
        firstTokenAt: firstTokenAt,
        finishedAt: .now)
}

func secs(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

struct IterStats {
    let aggregateTps: Double
    let perRequestTps: Double
    let wallClock: Double
    let avgLatency: Double
}

func runIteration() async throws -> IterStats {
    let wallStart = ContinuousClock.now
    // Submit all B requests concurrently; the scheduler/engine batches them.
    var results: [RequestResult] = []
    try await withThrowingTaskGroup(of: RequestResult.self) { group in
        for i in 0..<batchSize {
            group.addTask { try await runOne(index: i) }
        }
        for try await r in group { results.append(r) }
    }
    let wallClock = secs(ContinuousClock.now - wallStart)

    // Aggregate decode throughput: total decode tokens across the batch over
    // the wall-clock window from first submit to last completion. We subtract
    // one token per request (the prefill/first token) to isolate the decode
    // phase, mirroring solo-bench's `decodeToks = completion - 1`.
    let totalDecodeTokens = results.reduce(0) { $0 + max(1, $1.completionTokens - 1) }
    let aggregateTps = Double(totalDecodeTokens) / max(0.0001, wallClock)

    // Per-request decode tok/s: each request's decode tokens over its own
    // first-token → finish window, averaged. Shows the latency cost an
    // individual request pays for sharing the batch.
    var perReqTpsSum = 0.0
    var latencySum = 0.0
    for r in results {
        let decodeTokens = max(1, r.completionTokens - 1)
        let firstToken = r.firstTokenAt ?? r.startedAt
        let decodeWindow = max(0.0001, secs(r.finishedAt - firstToken))
        perReqTpsSum += Double(decodeTokens) / decodeWindow
        latencySum += secs(r.finishedAt - r.startedAt)
    }
    let perRequestTps = perReqTpsSum / Double(results.count)
    let avgLatency = latencySum / Double(results.count)

    return IterStats(
        aggregateTps: aggregateTps,
        perRequestTps: perRequestTps,
        wallClock: wallClock,
        avgLatency: avgLatency)
}

// ── Run ───────────────────────────────────────────────────────────────────
var kept: [IterStats] = []
for i in 1...iterations {
    let s = try await runIteration()
    let tag = i == 1 ? " (cold — discard)" : ""
    print(
        String(
            format:
                "iter %d: aggregate %.1f tok/s · per-req %.1f tok/s · wall %.2fs · avg latency %.2fs%@",
            i, s.aggregateTps, s.perRequestTps, s.wallClock, s.avgLatency, tag))
    if i > 1 { kept.append(s) }
}

// ── Summary table ───────────────────────────────────────────────────────────
print("\n  batchSize | aggregate tok/s | per-request tok/s | wall-clock")
print("  ----------+-----------------+-------------------+-----------")
if kept.isEmpty {
    print("  (no warm iterations — increase iterations to >1)")
} else {
    let n = Double(kept.count)
    let aggAvg = kept.reduce(0.0) { $0 + $1.aggregateTps } / n
    let perReqAvg = kept.reduce(0.0) { $0 + $1.perRequestTps } / n
    let wallAvg = kept.reduce(0.0) { $0 + $1.wallClock } / n
    print(
        String(
            format: "  %9d | %15.1f | %17.1f | %8.2fs",
            batchSize, aggAvg, perReqAvg, wallAvg))
}

await scheduler.unloadModel()
