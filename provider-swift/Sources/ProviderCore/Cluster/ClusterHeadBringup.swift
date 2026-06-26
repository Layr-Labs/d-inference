/// ClusterHeadBringup -- bring a node into the cluster ring and return the
/// pieces the proven decode loop (`ClusterPipeline` / `ClusterServer`) needs:
/// the ring group, this rank's loaded shard, the tokenizer, and the directional
/// encrypted-link sessions (ephemeral X25519 agreed over the ring).
///
/// Shared by cluster-run (one-shot) and cluster-provider (server). Joins the MLX
/// ring (blocks until all nodes connect), does the auto memory-weighted split,
/// loads only this rank's layer slice, and agrees per-neighbor session keys.
///
/// Activations cross the ring ENCRYPTED (X25519 + ChaCha20-Poly1305, forward
/// secrecy). Attestation binding of the ephemeral keys to Secure-Enclave
/// identities is the coordinator-roster follow-up.

import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon

public enum ClusterHeadBringupError: Error, CustomStringConvertible {
    case rankMismatch(expected: Int, got: Int)
    case unsupportedModelType(String)
    case configRead(String)

    public var description: String {
        switch self {
        case .rankMismatch(let e, let g): return "ring rank \(g) != configured rank \(e)"
        case .unsupportedModelType(let t): return "unsupported model_type '\(t)' (have: gpt_oss, gemma4)"
        case .configRead(let m): return "config read failed: \(m)"
        }
    }
}

/// Everything a node needs to participate in the cluster decode loop.
public struct ClusterContext {
    public let plan: ClusterPlan
    public let group: MLXDistributedGroup
    public let shard: any PipelineModelShard
    public let tokenizer: any Tokenizer
    public let eosTokenIds: Set<Int>
    public let hiddenSize: Int
    /// Directional sessions for the encrypted ring link.
    public let sendSession: ClusterSession?   // toward nextRank (nil on tail)
    public let recvSession: ClusterSession?   // from prevRank (nil on head)
    /// HEAD ONLY: the cluster registration JSON — {cluster_id, members:[…]} —
    /// assembled from every node's signed attestation gathered over the ring.
    /// The head relays this to the coordinator so it can verify each member.
    public let clusterRegistrationJSON: Data?

    /// Fresh sealing/opening channels for one request (nonce sequence restarts).
    public func makeChannels() -> (ClusterSealingChannel?, ClusterOpeningChannel?) {
        (sendSession.map { ClusterSealingChannel(key: $0.sendKey()) },
         recvSession.map { ClusterOpeningChannel(key: $0.recvKey()) })
    }

    /// Build a ClusterPipeline for one request with fresh channels.
    public func makePipeline() -> ClusterPipeline {
        let (seal, open) = makeChannels()
        return ClusterPipeline(plan: plan, group: group, shard: shard,
                               hiddenSize: hiddenSize, sealCh: seal, openCh: open)
    }
}

public enum ClusterHeadBringup {

    private static func configInt(_ dir: URL, _ key: String) throws -> Int {
        guard let data = try? Data(contentsOf: dir.appending(component: "config.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ClusterHeadBringupError.configRead(key) }
        // Multimodal configs (e.g. Gemma 4) nest the text tower's dims under
        // `text_config`; prefer that, falling back to the top level for flat
        // configs (Llama / Mistral / GPT-OSS).
        if let textCfg = obj["text_config"] as? [String: Any], let v = textCfg[key] as? Int {
            return v
        }
        guard let v = obj[key] as? Int else { throw ClusterHeadBringupError.configRead(key) }
        return v
    }

    private static func modelType(_ dir: URL) -> String {
        guard let data = try? Data(contentsOf: dir.appending(component: "config.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["model_type"] as? String else { return "" }
        return t
    }

    /// Join the ring, load this rank's shard, agree encrypted-link sessions, and
    /// return a `ClusterContext`. Blocks on ring init until all nodes connect.
    ///
    /// `attestationJSON` is THIS node's signed Secure-Enclave attestation blob
    /// (built by the caller from its SE identity). All nodes gather their blobs
    /// over the ring so the head can assemble the cluster registration the
    /// coordinator verifies. Pass nil to skip cluster attestation (e.g. on a
    /// platform without SE).
    public static func bringUp(plan: ClusterPlan, modelDir: URL, attestationJSON: Data? = nil) async throws -> ClusterContext {
        // 1. Ring env + join.
        let stateDir = (try? ConfigManager.defaultConfigPath().deletingLastPathComponent())
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let env = try MLXRingEnvironment.materialize(plan, directory: stateDir)
        for (k, v) in env { setenv(k, v, 1) }

        let physical = ProcessInfo.processInfo.physicalMemory
        MLX.GPU.set(memoryLimit: Int(Double(physical) * 0.80), relaxed: false)
        MLX.GPU.set(cacheLimit: 512 * 1024 * 1024)

        let group = try MLXDistributedGroup.initialize(backend: plan.backend, strict: true)
        guard group.rank == plan.rank else {
            throw ClusterHeadBringupError.rankMismatch(expected: plan.rank, got: group.rank)
        }

        // 2. Auto memory-weighted split via all-gathered budgets.
        let totalLayers = try configInt(modelDir, "num_hidden_layers")
        let gbF = 1_073_741_824.0
        let myBudget = max(2.0, Double(physical) / gbF - 10.0)
        var budgetVec = [Float](repeating: 0, count: plan.worldSize)
        budgetVec[plan.rank] = Float(myBudget)
        let bg = try group.allGather(MLXArray(budgetVec, [plan.worldSize]))
        bg.eval()
        let flat = bg.asArray(Float.self)
        let weights = plan.members.enumerated().map { (i, m) in
            LayerPartition.NodeWeight(
                nodeId: m.nodeId,
                weightBytes: UInt64(max(1.0, Double(flat[i * plan.worldSize + i])) * gbF))
        }
        let interval = try LayerPartition.partition(totalLayers: totalLayers, nodes: weights)[plan.rank]

        // 3. Load this rank's shard by architecture.
        let mt = modelType(modelDir)
        let shard: any PipelineModelShard
        switch mt {
        case "gpt_oss": shard = try GPTOSSShardAdapter.load(directory: modelDir, interval: interval)
        case "gemma4", "gemma4_text": shard = try Gemma4ShardAdapter.load(directory: modelDir, interval: interval)
        default: throw ClusterHeadBringupError.unsupportedModelType(mt)
        }

        // 4. Tokenizer + EOS + hidden size.
        let tokenizer = try await LocalTokenizerLoader().load(from: modelDir)
        var eos = Set<Int>()
        if let e = tokenizer.eosTokenId { eos.insert(e) }
        let hiddenSize = try configInt(modelDir, "hidden_size")

        // 5. Encrypted-link sessions: ephemeral X25519 agreed over the ring.
        let ephemeral = X25519KeyAgreementKeyPair()
        let myPub = ephemeral.publicKey
        func toI32(_ d: Data) -> MLXArray { MLXArray(d.map { Int32($0) }, [d.count]) }
        func toBytes(_ a: MLXArray) -> Data { Data(a.asArray(Int32.self).map { UInt8(truncatingIfNeeded: $0) }) }
        let pg = try group.allGather(toI32(myPub)); pg.eval()
        let allPub = toBytes(pg)
        func peerPub(_ r: Int) -> Data { allPub.subdata(in: r*32 ..< r*32 + 32) }
        func session(_ peerRank: Int, _ peerId: String) throws -> ClusterSession {
            let peer = peerPub(peerRank)
            let salt = myPub.lexicographicallyPrecedes(peer) ? myPub + peer : peer + myPub
            let master = try ephemeral.symmetricKey(
                peerPublicKey: peer, salt: salt,
                sharedInfo: Data("darkbloom-cluster-ring-v1|\(plan.clusterId)".utf8))
            return ClusterSession(clusterId: plan.clusterId, localNodeId: plan.nodeId,
                                  peerNodeId: peerId, masterSecret: master)
        }
        let ids = plan.members.map(\.nodeId)
        let sendSession = try plan.nextRank.map { try session($0, ids[$0]) }
        let recvSession = try plan.prevRank.map { try session($0, ids[$0]) }

        // 6. Attestation gather: every node contributes its signed SE attestation
        // blob over the ring (fixed-width frame: 4-byte big-endian length +
        // payload, padded). The head assembles them into the cluster
        // registration JSON the coordinator verifies. Skipped if no blob.
        // The attestation gather is opt-in: DARKBLOOM_CLUSTER_ATTEST=1. It adds a
        // third ring all_gather (of each node's attestation blob) which can
        // stress the ring transport; keeping it off by default preserves the
        // known-working inference path while it's validated on hardware.
        var clusterRegJSON: Data? = nil
        if let myBlob = attestationJSON, ProcessInfo.processInfo.environment["DARKBLOOM_CLUSTER_ATTEST"] == "1" {
            let frameW = 4 * 1024   // attestation blobs are ~hundreds of bytes; keep the ring frame small (a 64KB all_gather tripped the ring transport)
            var framed = Data()
            var len = UInt32(min(myBlob.count, frameW - 4)).bigEndian
            withUnsafeBytes(of: &len) { framed.append(contentsOf: $0) }
            framed.append(myBlob.prefix(frameW - 4))
            if framed.count < frameW { framed.append(Data(count: frameW - framed.count)) }
            let gatheredBlobs = try group.allGather(
                MLXArray(framed.map { Int32($0) }, [frameW]))
            gatheredBlobs.eval()
            if plan.isHead {
                let all = gatheredBlobs.asArray(Int32.self)
                var membersJSON = [[String: Any]]()
                for r in 0..<plan.worldSize {
                    let base = r * frameW
                    let l = Int(UInt32(bigEndian: (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(UInt8(truncatingIfNeeded: all[base + $1])) }))
                    let bodyBytes = (0..<l).map { UInt8(truncatingIfNeeded: all[base + 4 + $0]) }
                    if let blobObj = try? JSONSerialization.jsonObject(with: Data(bodyBytes)) {
                        membersJSON.append(["node_id": ids[r], "rank": r, "attestation": blobObj])
                    }
                }
                let reg: [String: Any] = ["cluster_id": plan.clusterId, "members": membersJSON]
                clusterRegJSON = try? JSONSerialization.data(withJSONObject: reg)
            }
        }

        return ClusterContext(
            plan: plan, group: group, shard: shard, tokenizer: tokenizer,
            eosTokenIds: eos, hiddenSize: hiddenSize,
            sendSession: sendSession, recvSession: recvSession,
            clusterRegistrationJSON: clusterRegJSON)
    }
}
