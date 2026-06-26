// comms-bench — measure the TENSOR-PARALLEL comms floor over the ring.
//
//   swift run -c release comms-bench [hiddenSize=4096] [layers=40] [tokens=64]
//
// TP does ~2 all-reduces per transformer layer per token (after attention-out
// and after the MLP down-projection). Each all-reduce moves one hidden-state
// vector. This harness joins the SAME ring the cluster uses (reads [cluster]
// from provider.toml) and times `2*layers` collectives per simulated token,
// over `tokens` tokens — giving the per-token comms floor that decides whether
// TP can approach single-node speed.
//
// A 2-node all-reduce ≈ allGather(localPartial) + local sum. We use allGather
// of a [hiddenSize] bf16-sized int32 payload as the cost proxy (same wire
// volume + the same CPU-stream GPU<->CPU crossing the real reduce would pay).
//
// Run on BOTH nodes (each reads its own node_id/rank from provider.toml).

import Foundation
import MLX
import ProviderCore

func log(_ m: String) { print("[comms-bench] \(m)") }

let argv = CommandLine.arguments
let hiddenSize = argv.count > 1 ? (Int(argv[1]) ?? 4096) : 4096
let layers = argv.count > 2 ? (Int(argv[2]) ?? 40) : 40
let tokens = argv.count > 3 ? (Int(argv[3]) ?? 64) : 64
let reducesPerToken = 2 * layers

let cfg = (try? ConfigManager.load(from: ConfigManager.defaultConfigPath())) ?? ConfigManager.loadDefault()
guard let clusterSettings = cfg.cluster, clusterSettings.enabled else {
    FileHandle.standardError.write(Data("ERROR: provider.toml needs an enabled [cluster] section\n".utf8)); exit(1)
}
let plan = try ClusterPlan.resolve(clusterSettings)

// Join the ring (same env materialization as ClusterHeadBringup).
let stateDir = (try? ConfigManager.defaultConfigPath().deletingLastPathComponent())
    ?? FileManager.default.temporaryDirectory
let env = try MLXRingEnvironment.materialize(plan, directory: stateDir)
for (k, v) in env { setenv(k, v, 1) }

log("node \(plan.nodeId) rank \(plan.rank)/\(plan.worldSize) — joining ring …")
let group = try MLXDistributedGroup.initialize(backend: plan.backend, strict: true)
log("ring joined. hiddenSize=\(hiddenSize) layers=\(layers) → \(reducesPerToken) reduces/token, \(tokens) tokens")

// Payload sized like one bf16 hidden-state vector (2 bytes/elem ≈ hiddenSize int16;
// we use int32 elements of count hiddenSize as a conservative cost proxy).
func payload() -> MLXArray { MLXArray((0..<hiddenSize).map { Int32($0 & 0x7fff) }, [hiddenSize]) }

// Warmup (exclude cold ring/codepath).
for _ in 0..<(2 * reducesPerToken) {
    let g = try group.allGather(payload()); g.eval()
}

var perToken = [Double]()
let tStart = DispatchTime.now().uptimeNanoseconds
for t in 0..<tokens {
    let t0 = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<reducesPerToken {
        let g = try group.allGather(payload())
        g.eval()                       // each reduce is a barrier — same as TP would pay
    }
    let dtMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
    perToken.append(dtMs)
    if plan.isHead && (t % 8 == 0) {
        FileHandle.standardError.write(Data("  token \(t): \(String(format: "%.1f", dtMs)) ms comms\n".utf8))
    }
}
let totalMs = Double(DispatchTime.now().uptimeNanoseconds - tStart) / 1_000_000

if plan.isHead {
    let warm = Array(perToken.dropFirst(4))
    let mean = warm.reduce(0, +) / Double(max(1, warm.count))
    let perReduce = mean / Double(reducesPerToken)
    log(String(format: "RESULT: %.2f ms/token comms floor (%.3f ms/reduce, %d reduces) over %.1fs total",
               mean, perReduce, reducesPerToken, totalMs / 1000))
    log(String(format: "  → at this comms floor, TP decode ceiling ≈ %.1f tok/s (comms-only, ignoring compute overlap)",
               1000.0 / mean))
}
