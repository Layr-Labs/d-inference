// cluster-run — run ONE model split across the cluster, over the real MLX ring.
//
//   swift run -c release cluster-run <model-dir> "<prompt>"
//
// Reads the [cluster] section of provider.toml (cluster_id, node_id, ring-ordered
// members) to learn this node's rank + the ring host list, materializes the MLX
// ring environment, joins the ring, loads ONLY this rank's layer slice, and runs
// a greedy pipeline decode:
//
//   head (rank 0):  embed(seq) -> own layers -> ring-send hidden to next
//   tail (rank N-1): ring-recv hidden -> own layers -> norm+lm_head -> sample
//                     -> all_gather the sampled token so every rank advances
//
// Run the SAME command on every node (each reads its own node_id from config).
// The head prints the generated text.
//
// Status:
//   * Activations cross the ring ENCRYPTED: ephemeral X25519 key agreement over
//     the ring + per-hop ChaCha20-Poly1305 (ClusterLinkCrypto). A tap sees only
//     ciphertext, with forward secrecy. NOT YET attested — binding the ephemeral
//     keys to a Secure-Enclave identity needs the coordinator-signed roster
//     (ClusterHandshake/ClusterRoster), which this coordinator-less harness lacks.
//   * KV cache: incremental decode (prefill once, then 1 token/step).
//   * Layer split: auto memory-weighted (each node ∝ its usable RAM).

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import ProviderCore

func die(_ m: String) -> Never { FileHandle.standardError.write(Data("ERROR: \(m)\n".utf8)); exit(1) }

// ---- args ----
let argv = CommandLine.arguments
guard argv.count >= 3 else { die("usage: cluster-run <model-dir> \"<prompt>\"") }
let modelDir = URL(fileURLWithPath: argv[1], isDirectory: true)
let prompt = argv[2]
let maxTokens = 64

// ---- resolve cluster plan from provider.toml ----
let cfg: ProviderConfig
do {
    cfg = try ConfigManager.load(from: ConfigManager.defaultConfigPath())
} catch { die("could not load provider.toml: \(error)") }
guard let clusterSettings = cfg.cluster, clusterSettings.enabled else {
    die("provider.toml has no enabled [cluster] section")
}
let plan: ClusterPlan
do { plan = try ClusterPlan.resolve(clusterSettings) } catch { die("invalid [cluster]: \(error)") }

print("[rank \(plan.rank)/\(plan.worldSize)] node=\(plan.nodeId) role=\(plan.isHead ? "head" : plan.isTail ? "tail" : "middle")")

// ---- materialize ring env + join the ring ----
do {
    let dir = try ConfigManager.defaultConfigPath().deletingLastPathComponent()
    let env = try MLXRingEnvironment.materialize(plan, directory: dir)
    for (k, v) in env { setenv(k, v, 1) }
    print("[rank \(plan.rank)] ring env: MLX_HOSTFILE=\(env["MLX_HOSTFILE"] ?? "?") MLX_RANK=\(env["MLX_RANK"] ?? "?")")
} catch { die("ring env materialize failed: \(error)") }

print("[rank \(plan.rank)] joining MLX ring … (blocks until all \(plan.worldSize) nodes connect)")
let group: MLXDistributedGroup
do {
    group = try MLXDistributedGroup.initialize(backend: .ring, strict: true)
} catch { die("ring init failed: \(error)") }
guard group.size == plan.worldSize else {
    die("ring size \(group.size) != configured worldSize \(plan.worldSize)")
}
guard group.rank == plan.rank else {
    die("ring rank \(group.rank) != configured rank \(plan.rank) (check MLX_RANK / member order)")
}
print("[rank \(plan.rank)] ring joined ✓ (size \(group.size))")

// ---- even contiguous layer split ----
// Read an Int field from config.json. Multimodal configs (e.g. Gemma 4) nest the
// text tower's dims under `text_config`; prefer that, falling back to the top
// level for flat configs (Llama / Mistral / GPT-OSS).
func configInt(_ dir: URL, _ key: String) -> Int? {
    guard let data = try? Data(contentsOf: dir.appending(component: "config.json")),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    if let textCfg = obj["text_config"] as? [String: Any], let v = textCfg[key] as? Int { return v }
    return obj[key] as? Int
}
func totalLayersFromConfig(_ dir: URL) -> Int {
    guard let n = configInt(dir, "num_hidden_layers") else {
        die("cannot read num_hidden_layers from config.json")
    }
    return n
}
let N = totalLayersFromConfig(modelDir)

// Memory-WEIGHTED layer split: each node gets layers in proportion to its
// usable RAM, so a smaller machine holds fewer layers and does NOT swap. An
// even split on an asymmetric pair (24 GB + 32 GB) overloads the smaller Mac →
// swap → ~1 token/minute.
//
// The weights are determined AUTOMATICALLY: every node measures its own usable
// memory and the ring all-gathers the values, so each rank computes the same
// split with no per-node config. Reserve OS + KV/activation headroom from the
// detected total. Config `memory_gb` (if set on every member) overrides the
// auto value; otherwise we use the gathered measurements.
let gbF = 1_073_741_824.0
let osReserveGb = 10.0   // macOS + KV/activation + GPU working-buffer headroom

// This node's usable budget for weights.
let detectedTotalGb = Double(ProcessInfo.processInfo.physicalMemory) / gbF
let detectedUsableGb = max(2.0, detectedTotalGb - osReserveGb)
let configuredGb = clusterSettings.members.first { $0.nodeId == plan.nodeId }?.memoryGb
let myBudgetGb = configuredGb ?? detectedUsableGb

// Exchange budgets over the ring: all_gather a [worldSize] vector where each
// rank wrote its budget at its own index.
var budgetVec = [Float](repeating: 0, count: plan.worldSize)
budgetVec[plan.rank] = Float(myBudgetGb)
let gathered0 = try group.allGather(MLXArray(budgetVec, [plan.worldSize]))
gathered0.eval()
// all_gather concatenates each rank's [worldSize] vector → [worldSize*worldSize];
// rank r's real value sits at index r*worldSize + r.
let flat = gathered0.asArray(Float.self)
var budgets = [Double](repeating: 0, count: plan.worldSize)
for r in 0..<plan.worldSize { budgets[r] = Double(flat[r * plan.worldSize + r]) }

let weights = clusterSettings.members.enumerated().map { (i, m) in
    LayerPartition.NodeWeight(nodeId: m.nodeId, weightBytes: UInt64(max(1.0, budgets[i]) * gbF))
}
let plan2 = try LayerPartition.partition(totalLayers: N, nodes: weights)
let interval = plan2[plan.rank]
let split = zip(plan2, budgets).map { "\($0.0.nodeId):\($0.0.count)L@\(String(format: "%.0f", $0.1))GB" }.joined(separator: "  ")
print("[rank \(plan.rank)] auto memory-weighted split → \(split)")
print("[rank \(plan.rank)] layers \(interval.start)..<\(interval.end) of \(N)")

// ---- pin MLX's memory ceiling BELOW physical RAM ----
// Without this, MLX's default (~1.5x working set) lets its buffer cache grow
// past RAM into swap, stalling a command buffer on disk until the ~5s GPU
// watchdog kills it (kIOGPUCommandBufferCallbackErrorTimeout). Cap the memory
// limit and keep the cache small so freed buffers are released, not hoarded.
let physical = ProcessInfo.processInfo.physicalMemory
let memLimit = Int(Double(physical) * 0.80)        // hard ceiling at 80% of RAM
MLX.GPU.set(memoryLimit: memLimit, relaxed: false)
MLX.GPU.set(cacheLimit: 512 * 1024 * 1024)         // 512 MB cache cap
print("[rank \(plan.rank)] MLX memory limit \(memLimit / (1024*1024*1024)) GB, cache 512 MB")

// ---- load this rank's shard (only its layers) ----
// Pick the architecture-specific shard from config.json's model_type. Both
// conform to PipelineModelShard, so the decode loop below is arch-agnostic.
func modelTypeFromConfig(_ dir: URL) -> String {
    guard let data = try? Data(contentsOf: dir.appending(component: "config.json")),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let t = obj["model_type"] as? String else { return "" }
    return t
}
let modelType = modelTypeFromConfig(modelDir)
print("[rank \(plan.rank)] model_type=\(modelType), loading shard weights …")
let shard: any PipelineModelShard
do {
    switch modelType {
    case "gpt_oss":
        shard = try GPTOSSShardAdapter.load(directory: modelDir, interval: interval)
    case "gemma4", "gemma4_text":
        shard = try Gemma4ShardAdapter.load(directory: modelDir, interval: interval)
    default:
        die("unsupported model_type '\(modelType)' for clustering (have: gpt_oss, gemma4)")
    }
} catch { die("shard load failed: \(error)") }
print("[rank \(plan.rank)] shard loaded ✓")

// ---- tokenizer (every rank loads it; both need the sequence length) ----
let tokenizer: any Tokenizer
do { tokenizer = try await LocalTokenizerLoader().load(from: modelDir) }
catch { die("tokenizer load failed: \(error)") }

var seq: [Int]
do {
    seq = try tokenizer.applyChatTemplate(
        messages: [["role": "user", "content": prompt]], tools: nil, additionalContext: nil)
} catch { die("tokenize failed: \(error)") }

let hiddenSize = { () -> Int in
    guard let h = configInt(modelDir, "hidden_size") else { die("cannot read hidden_size") }
    return h
}()

let headRank = 0
let tailRank = plan.worldSize - 1

// ---- encrypted ring: ephemeral X25519 key exchange over the ring ----
// Each node makes a fresh ephemeral X25519 keypair, all-gathers the 32-byte
// public keys, and derives a shared key with each ring neighbor. Activations
// are then AEAD-sealed (ClusterLinkCrypto) so a tap on the wire sees only
// ciphertext, with forward secrecy from the ephemeral keys.
//
// NOTE: this gives confidentiality + forward secrecy on the link. It does NOT
// yet bind the keys to an attested Secure-Enclave identity — that requires the
// coordinator-signed roster (ClusterHandshake/ClusterRoster), which this
// standalone harness has no coordinator for. The attestation binding is the
// remaining production step.
func bytesToInt32Array(_ d: Data) -> MLXArray { MLXArray(d.map { Int32($0) }, [d.count]) }
func int32ArrayToBytes(_ a: MLXArray) -> Data { Data(a.asArray(Int32.self).map { UInt8(truncatingIfNeeded: $0) }) }

let ephemeral = X25519KeyAgreementKeyPair()
let myPub = ephemeral.publicKey  // 32 bytes
// all_gather the 32-byte pubkeys → [worldSize*32], rank r's key at r*32.
let pubGather = try group.allGather(bytesToInt32Array(myPub))
pubGather.eval()
let allPubBytes = int32ArrayToBytes(pubGather)
func peerPub(_ rank: Int) -> Data { allPubBytes.subdata(in: rank*32 ..< rank*32 + 32) }

// Derive a directional session with a neighbor. Both ends use the SAME salt
// (sorted pubkeys) + sharedInfo, so the ECDH→HKDF master secret matches.
func session(withRank peerRank: Int, peerNodeId: String) throws -> ClusterSession {
    let peer = peerPub(peerRank)
    let salt = (myPub.lexicographicallyPrecedes(peer) ? myPub + peer : peer + myPub)
    let master = try ephemeral.symmetricKey(
        peerPublicKey: peer, salt: salt,
        sharedInfo: Data("darkbloom-cluster-ring-v1|\(plan.clusterId)".utf8))
    return ClusterSession(
        clusterId: plan.clusterId, localNodeId: plan.nodeId,
        peerNodeId: peerNodeId, masterSecret: master)
}

let memberIds = clusterSettings.members.map(\.nodeId)
var sealCh: ClusterSealingChannel?
var openCh: ClusterOpeningChannel?
if let next = plan.nextRank {
    let s = try session(withRank: next, peerNodeId: memberIds[next])
    sealCh = ClusterSealingChannel(key: s.sendKey())
}
if let prev = plan.prevRank {
    let s = try session(withRank: prev, peerNodeId: memberIds[prev])
    openCh = ClusterOpeningChannel(key: s.recvKey())
}
print("[rank \(plan.rank)] encrypted ring link established ✓ (X25519 + ChaCha20-Poly1305)")

// AEAD ciphertext length is deterministic from the activation shape, so the
// receiver can size its recvLike buffer: encode header (2 + ndim*4) + payload
// (elements * 2 bytes for float16) + AEAD overhead (12 nonce + 16 tag).
func sealedLen(width: Int) -> Int {
    let header = 2 + 3 * 4               // [1, width, hidden] → ndim 3
    let payload = 1 * width * hiddenSize * 2
    return header + payload + 28
}
let reqId = "clusterrun"

print("[rank \(plan.rank)] starting decode (\(maxTokens) tokens max) …\n")

// Incremental decode with a persistent KV cache:
//   step 0 (prefill): process the FULL prompt; the cache stores its K/V.
//   step >0 (decode):  process ONLY the 1 new token; attention reuses the
//                      cached K/V for all prior positions.
// This is the difference between O(L) total work and O(L^2) — the dominant
// cost in the first (cacheless) version. The head feeds `inputTokens`; every
// rank's recvLike template width must match the number of tokens in flight.
var generated = [Int]()
var prefillNs: UInt64 = 0
var decodeNs: UInt64 = 0
for step in 0..<maxTokens {
    let stepStart = DispatchTime.now().uptimeNanoseconds
    // Tokens entering the pipeline THIS step: whole prompt on prefill, then the
    // single most-recent token.
    let inputTokens: [Int] = step == 0 ? seq : [seq[seq.count - 1]]
    let width = inputTokens.count

    // Each non-head rank receives the SEALED hidden state from its predecessor,
    // opens it, runs its owned layers, then re-seals and sends downstream. The
    // plaintext activation never crosses the wire — only AEAD ciphertext.
    let ctx = ClusterFrameContext(
        clusterId: plan.clusterId, requestId: reqId,
        layerRange: "hop-\(plan.rank == headRank ? headRank : plan.rank - 1)", seq: UInt64(step))
    var hidden: MLXArray
    if plan.isHead {
        hidden = shard.embed(tokens: inputTokens)
    } else {
        // Receive ciphertext bytes (deterministic length) and open them.
        let cipherTemplate = MLXArray.zeros([sealedLen(width: width)], dtype: .int32)
        let cipherArr = try group.recvLike(cipherTemplate, from: plan.rank - 1)
        cipherArr.eval()
        let plain = try openCh!.open(int32ArrayToBytes(cipherArr), context: ctx)
        hidden = try ActivationCodec.decode(plain)
    }
    hidden = shard.runOwnedLayers(hidden)

    if !plan.isTail {
        // Seal this rank's output and ship ciphertext to the next rank.
        // Normalize the wire dtype to bfloat16 so sealedLen's 2-byte payload
        // math is exact regardless of the model's compute dtype, WITHOUT the
        // range loss an fp16 cast would risk on hidden-state activations
        // (bf16 keeps the same exponent range as the model's bf16 compute).
        let outCtx = ClusterFrameContext(
            clusterId: plan.clusterId, requestId: reqId,
            layerRange: "hop-\(plan.rank)", seq: UInt64(step))
        let wireHidden = hidden.asType(.bfloat16)
        let sealed = try sealCh!.seal(ActivationCodec.encode(wireHidden), context: outCtx)
        let dep = try group.send(bytesToInt32Array(sealed), to: plan.rank + 1)
        dep.eval()   // force the transmit
    }

    // The tail samples; everyone learns the token via all_gather.
    var tokenScalar = MLXArray([Int32(0)])
    if plan.isTail {
        let logits = shard.projectToLogits(hidden)
        let lastAxis = logits.ndim - 1
        let ids = argMax(logits, axis: lastAxis)
        ids.eval()
        let tok = Int(ids.asArray(Int32.self).last ?? 0)
        tokenScalar = MLXArray([Int32(tok)])
    }
    let gathered = try group.allGather(tokenScalar)
    gathered.eval()
    let allTokens = gathered.asArray(Int32.self)
    let nextToken = Int(allTokens[tailRank])

    seq.append(nextToken)
    generated.append(nextToken)

    let stepNs = DispatchTime.now().uptimeNanoseconds - stepStart
    if step == 0 { prefillNs = stepNs } else { decodeNs += stepNs }

    if plan.rank == headRank {
        let piece = tokenizer.decode(tokenIds: [nextToken])
        FileHandle.standardOutput.write(Data(piece.utf8))
        let ms = Double(stepNs) / 1_000_000
        FileHandle.standardError.write(Data("  [\(step == 0 ? "prefill" : "tok \(step)") \(String(format: "%.0f", ms)) ms]\n".utf8))
    }
    // crude EOS: stop on the tokenizer's eos id if present
    if let eos = tokenizer.eosTokenId, nextToken == eos { break }
}

if plan.rank == headRank {
    let decodeTokens = max(1, generated.count - 1)
    let decodeSec = Double(decodeNs) / 1_000_000_000
    let tps = decodeSec > 0 ? Double(decodeTokens) / decodeSec : 0
    print("\n\n[head] done — \(generated.count) tokens")
    print(String(format: "[head] prefill %.1fs · decode %.2f tok/s (%.0f ms/tok)",
                 Double(prefillNs) / 1_000_000_000, tps,
                 decodeTokens > 0 ? Double(decodeNs) / 1_000_000 / Double(decodeTokens) : 0))
} else {
    print("[rank \(plan.rank)] done")
}
