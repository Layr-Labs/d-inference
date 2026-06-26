// cluster-provider — the HEAD node of a cluster, acting as a real Darkbloom
// provider against a coordinator, driving the PROVEN ring decode loop
// (ClusterPipeline / ClusterServer — the same loop verified in cluster-run).
//
//   swift run -c release cluster-provider <model-dir> [coordinator-ws-url]
//
// Run on the HEAD node (rank 0). On the OTHER ranks, run the peer companion
// (cluster-run will also do; or `cluster-provider --peer`). Reads [cluster] from
// provider.toml for topology.
//
// Design: the MLX ring is a single ordered stream, so the head serializes
// requests — one generation at a time. Per request the head broadcasts the
// descriptor (prompt ids + maxTokens) to peers via the control round
// (ClusterServer.exchangeRequest), then all ranks run ClusterPipeline.generate
// in lockstep; the head streams tokens back to the coordinator.
//
// Honesty: the coordinator attests THIS head node. Per-member attestation
// (cluster roster) is the coordinator-side follow-up. Inter-node link is
// encrypted regardless.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import ProviderCore

func die(_ m: String) -> Never { FileHandle.standardError.write(Data("ERROR: \(m)\n".utf8)); exit(1) }
func log(_ m: String) { print("[cluster-provider] \(m)") }

let argv = CommandLine.arguments
guard argv.count >= 2 else { die("usage: cluster-provider <model-dir> [coordinator-ws-url] [--peer]") }
let modelDir = URL(fileURLWithPath: argv[1], isDirectory: true)
let isPeerFlag = argv.contains("--peer")
let overrideURL = argv.dropFirst(2).first(where: { !$0.hasPrefix("--") })

let cfg = (try? ConfigManager.load(from: ConfigManager.defaultConfigPath())) ?? ConfigManager.loadDefault()
guard let clusterSettings = cfg.cluster, clusterSettings.enabled else {
    die("provider.toml needs an enabled [cluster] section")
}
let plan = try ClusterPlan.resolve(clusterSettings)

// ---- this node's SE identity + attestation (gathered over the ring so the
// head can relay EVERY member's attestation to the coordinator) ----
// Each node (head AND peers) builds its own signed attestation blob; bringUp
// all-gathers them. The head also reuses its signer + X25519 key to attest to
// the coordinator directly.
let signer = try SecureEnclaveIdentity.createEphemeral()
let keyPair = NodeKeyPair.generate()
let attestationBuilder = signer.map { AttestationBuilder(identity: $0) }
let myAttestationJSON = try attestationBuilder?.buildAttestationJSON(
    encryptionPublicKey: keyPair.publicKeyBase64)

// ---- bring the node into the ring ----
log("node \(plan.nodeId) rank \(plan.rank)/\(plan.worldSize) — joining ring + loading shard (start all nodes) …")
let ctx = try await ClusterHeadBringup.bringUp(plan: plan, modelDir: modelDir, attestationJSON: myAttestationJSON)
log("cluster ready ✓ (encrypted ring link established)")

let server = ClusterServer(plan: plan, group: ctx.group, pipeline: ctx.makePipeline(), eosTokenIds: ctx.eosTokenIds)

// Continuous batching (Phase 3) is opt-in via [cluster].batched. When on, the
// head runs the ClusterBatchScheduler and peers run the batched control loop.
let batchedMode = clusterSettings.batched
let batchServer = ClusterBatchServer(
    plan: plan, group: ctx.group, shard: ctx.shard,
    hiddenSize: ctx.hiddenSize, eosTokenIds: ctx.eosTokenIds)

// =====================================================================
// PEER path: no coordinator. Loop in lockstep with the head until shutdown.
// =====================================================================
if !plan.isHead || isPeerFlag {
    if batchedMode {
        log("peer mode (BATCHED) — replaying head composition until shutdown")
        try batchServer.runBatchedPeerLoop(makeChannels: { ctx.makeChannels() })
    } else {
        log("peer mode — serving the head in lockstep until shutdown")
        try server.runPeerLoop(makeChannels: { ctx.makeChannels() })
    }
    log("peer shutdown")
    exit(0)
}

// =====================================================================
// HEAD path: connect to the coordinator, serialize requests through the ring.
// =====================================================================
guard let attestationBuilder, let myAttestationJSON else {
    die("Secure Enclave unavailable — required to attest to the coordinator")
}
let attestation = RawJSON(rawBytes: myAttestationJSON)
// The cluster registration (every member's attestation) gathered during bringUp.
let clusterReg = ctx.clusterRegistrationJSON.map { RawJSON(rawBytes: $0) }
if clusterReg != nil { log("relaying \(plan.worldSize)-member cluster attestation to coordinator") }

let coordinatorURL = overrideURL ?? cfg.coordinator.url
let modelId = modelDir.lastPathComponent
let hardware = try HardwareDetector.detect()
let modelInfo = ModelInfo(
    id: modelId, modelType: nil, sizeBytes: 0, estimatedMemoryGb: 0,
    weightHash: nil, isVision: false, templateRenderOK: true)

let client = CoordinatorClient(
    config: CoordinatorClientConfig(
        url: coordinatorURL, hardware: hardware, models: [modelInfo],
        backendName: "mlx-swift",   // must equal coordinator's privateTextBackendSupported / runtime-integrity backend; "mlx-swift-cluster" is excluded from routing
        heartbeatInterval: TimeInterval(cfg.coordinator.heartbeatIntervalSecs),
        publicKey: keyPair.publicKeyBase64, attestation: attestation,
        privateOnly: cfg.coordinator.privateOnly,
        cluster: clusterReg),
    stats: AtomicProviderStats(), state: ProviderState())
let (events, sendFn) = await client.start()
log("connecting to coordinator \(coordinatorURL) …")

// Encode one generated token as an encrypted OpenAI SSE chunk frame back to the
// request's sender. Used by the batched head path (the ring thread). Captures
// locals (not the main-actor `ctx`) so it is safe to call cross-thread.
let frameTokenizer = ctx.tokenizer
let frameKeyPair = keyPair
let frameModelId = modelId
let sendTokenFrame: @Sendable (Int, String, Data) -> Void = { tok, requestId, senderKey in
    let piece = frameTokenizer.decode(tokenIds: [tok])
    guard !piece.isEmpty else { return }
    let escaped = piece
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
    let frame = "data: {\"id\":\"\(requestId)\",\"object\":\"chat.completion.chunk\",\"model\":\"\(frameModelId)\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\(escaped)\"},\"finish_reason\":null}]}"
    if let enc = try? frameKeyPair.encryptPayload(recipientPublicKey: senderKey, plaintext: Data(frame.utf8)) {
        sendFn(.inferenceChunk(requestId: requestId, data: "", encryptedData: enc))
    }
}

// =====================================================================
// HEAD path — BATCHED (continuous batching, Phase 3). The ClusterBatchScheduler
// owns the ring on its own thread; the event loop only decrypts + enqueues.
// =====================================================================
if batchedMode {
    log("head mode (BATCHED) — continuous-batching scheduler")
    let scheduler = ClusterBatchScheduler(
        server: batchServer, plan: plan, group: ctx.group, shard: ctx.shard,
        hiddenSize: ctx.hiddenSize, eosTokenIds: ctx.eosTokenIds, maxConcurrent: 8)

    // requestId -> (senderKey, promptLen) for token routing + usage accounting.
    final class Routes: @unchecked Sendable {
        let lock = NSLock(); var keys: [String: Data] = [:]; var prompt: [String: Int] = [:]
        func set(_ id: String, _ k: Data, _ p: Int) { lock.lock(); keys[id] = k; prompt[id] = p; lock.unlock() }
        func key(_ id: String) -> Data? { lock.lock(); defer { lock.unlock() }; return keys[id] }
        func promptLen(_ id: String) -> Int { lock.lock(); defer { lock.unlock() }; return prompt[id] ?? 0 }
        func drop(_ id: String) { lock.lock(); keys[id] = nil; prompt[id] = nil; lock.unlock() }
    }
    let routes = Routes()

    let ringThread = Thread {
        do {
            try scheduler.run(
                makeChannels: { ctx.makeChannels() },
                onToken: { reqId, tok in
                    if let k = routes.key(reqId) { sendTokenFrame(tok, reqId, k) }
                },
                onComplete: { reqId, generated in
                    sendFn(.inferenceComplete(
                        requestId: reqId,
                        usage: UsageInfo(promptTokens: UInt64(routes.promptLen(reqId)),
                                         completionTokens: UInt64(generated)),
                        seSignature: nil, responseHash: nil))
                    routes.drop(reqId)
                })
        } catch { FileHandle.standardError.write(Data("batched scheduler error: \(error)\n".utf8)) }
    }
    ringThread.stackSize = 16 << 20
    ringThread.start()

    for await event in events {
        switch event {
        case .connected:
            log("registered ✓ (BATCHED, serving \(modelId) across \(plan.worldSize) nodes)")
        case .disconnected:
            log("disconnected (will retry)")
        case .attestationChallenge(let nonce, let timestamp):
            if let r = try? attestationBuilder.buildChallengeResponse(
                nonce: nonce, timestamp: timestamp, providerPublicKey: keyPair.publicKeyBase64) {
                sendFn(.attestationResponse(AttestationResponsePayload(
                    nonce: r.nonce, signature: r.signature, statusSignature: r.statusSignature,
                    publicKey: r.publicKey, hypervisorActive: r.hypervisorActive,
                    rdmaDisabled: r.rdmaDisabled, sipEnabled: r.sipEnabled,
                    secureBootEnabled: r.secureBootEnabled, binaryHash: r.binaryHash,
                    activeModelHash: r.activeModelHash, pythonHash: r.pythonHash,
                    runtimeHash: r.runtimeHash, templateHashes: r.templateHashes,
                    modelHashes: r.modelHashes)))
            }
        case let .inferenceRequest(requestId, ciphertext, senderPublicKey):
            guard let senderKey = senderPublicKey, senderKey.count == 32,
                  let plain = try? keyPair.decrypt(senderPublicKey: senderKey, ciphertext: ciphertext),
                  let req = try? JSONDecoder().decode(ChatCompletionRequest.self, from: plain) else {
                sendFn(.inferenceError(requestId: requestId, error: "decrypt/parse failed", statusCode: 400)); break
            }
            guard let promptTokens = try? ctx.tokenizer.applyChatTemplate(
                messages: req.messages.map { ["role": $0.role, "content": $0.content] },
                tools: nil, additionalContext: nil) else {
                sendFn(.inferenceError(requestId: requestId, error: "tokenize failed", statusCode: 400)); break
            }
            sendFn(.inferenceAccepted(requestId: requestId))
            routes.set(requestId, senderKey, promptTokens.count)
            scheduler.enqueue(ClusterBatchRequest(
                requestId: requestId, promptTokens: promptTokens, maxTokens: req.max_tokens ?? 512))
        default:
            break
        }
    }
    exit(0)
}

// ---------------------------------------------------------------------------
// The MLX ring is a single ordered stream and the peers loop on a control-round
// `all_gather` continuously. The head must therefore drive that SAME collective
// at the SAME cadence from a SINGLE thread — otherwise the peer sits parked in a
// lone `all_gather` the head hasn't joined, the ring times out (~25 s), and the
// head drops off the coordinator. So ONE dedicated control thread OWNS the ring:
// it broadcasts an IDLE descriptor when no request is pending (keeping lockstep
// with the peer) and a REAL descriptor when serving. The coordinator event loop
// below NEVER touches the ring — it only enqueues decrypted requests.
// ---------------------------------------------------------------------------
final class PendingQueue: @unchecked Sendable {
    struct Item { let requestId: String; let prompt: [Int]; let maxTokens: Int; let senderKey: Data }
    private let lock = NSLock()
    private var items: [Item] = []
    func push(_ i: Item) { lock.lock(); items.append(i); lock.unlock() }
    func pop() -> Item? { lock.lock(); defer { lock.unlock() }; return items.isEmpty ? nil : items.removeFirst() }
}
let queue = PendingQueue()

let controlThread = Thread {
    var reqCounter = 0
    while true {
        guard let item = queue.pop() else {
            // Idle keepalive round: matches the peer's `exchangeRequest` so both
            // sides rendezvous on the ring barrier; the sleep paces the spin.
            _ = try? server.exchangeRequest(ClusterServer.idleDescriptor)
            Thread.sleep(forTimeInterval: 0.1)
            continue
        }
        reqCounter += 1
        let requestId = item.requestId
        let senderKey = item.senderKey
        do {
            // Broadcast the real descriptor to peers, then run the proven loop in
            // lockstep. Per-token timing lets you benchmark ring transport
            // (Wi-Fi vs Thunderbolt). First onToken fires after prefill.
            _ = try server.exchangeRequest(
                ClusterRequestDescriptor(promptTokens: item.prompt, maxTokens: item.maxTokens))
            let pipeline = ctx.makePipeline()
            var completion = 0
            let genStart = DispatchTime.now().uptimeNanoseconds
            var prevTokenNs = genStart
            var prefillNs: UInt64 = 0
            var decodeNs: UInt64 = 0
            print("\n[req \(reqCounter)] prompt=\(item.prompt.count) tok, generating \(item.maxTokens) …")
            _ = try pipeline.generate(
                promptTokens: item.prompt, maxTokens: item.maxTokens,
                requestId: "req-\(reqCounter)", eosTokenIds: ctx.eosTokenIds,
                onToken: { tok in
                    let now = DispatchTime.now().uptimeNanoseconds
                    let stepNs = now - prevTokenNs
                    prevTokenNs = now
                    if completion == 0 { prefillNs = stepNs } else { decodeNs += stepNs }
                    completion += 1
                    let piece = ctx.tokenizer.decode(tokenIds: [tok])
                    let ms = Double(stepNs) / 1_000_000
                    FileHandle.standardError.write(Data(
                        "  [\(completion == 1 ? "prefill" : "tok \(completion-1)") \(String(format: "%.0f", ms)) ms] \(piece)\n".utf8))
                    if !piece.isEmpty {
                        // The coordinator parses each chunk as a full OpenAI SSE
                        // frame ("data: {chat.completion.chunk}") and extracts
                        // choices[0].delta.content — raw token text yields empty
                        // content. Wrap the token in the OpenAI delta shape, then
                        // encrypt the whole frame back to the request's sender key
                        // (encryptPayload sets ephemeral_public_key = this head's
                        // registered X25519 key, matched to provider.PublicKey).
                        let escaped = piece
                            .replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "\"", with: "\\\"")
                            .replacingOccurrences(of: "\n", with: "\\n")
                            .replacingOccurrences(of: "\r", with: "\\r")
                            .replacingOccurrences(of: "\t", with: "\\t")
                        let frame = "data: {\"id\":\"\(requestId)\",\"object\":\"chat.completion.chunk\",\"model\":\"\(modelId)\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\(escaped)\"},\"finish_reason\":null}]}"
                        if let enc = try? keyPair.encryptPayload(recipientPublicKey: senderKey, plaintext: Data(frame.utf8)) {
                            sendFn(.inferenceChunk(requestId: requestId, data: "", encryptedData: enc))
                        }
                    }
                })
            // Decode tok/s is the headline number to compare across transports.
            let decodeToks = max(1, completion - 1)
            let decodeSec = Double(decodeNs) / 1_000_000_000
            let tps = decodeSec > 0 ? Double(decodeToks) / decodeSec : 0
            print(String(format: "[req \(reqCounter)] prefill %.2fs · decode %.2f tok/s (%.0f ms/tok) · %d tokens\n",
                         Double(prefillNs) / 1_000_000_000, tps,
                         Double(decodeNs) / 1_000_000 / Double(decodeToks), completion))
            sendFn(.inferenceComplete(
                requestId: requestId,
                usage: UsageInfo(promptTokens: UInt64(item.prompt.count), completionTokens: UInt64(completion)),
                seSignature: nil, responseHash: nil))
        } catch {
            sendFn(.inferenceError(requestId: requestId, error: "generation failed: \(error)", statusCode: 500))
        }
    }
}
controlThread.stackSize = 16 << 20
controlThread.start()

// Coordinator event loop: decrypt + tokenize + enqueue ONLY. Never touches the
// ring (the control thread owns it).
for await event in events {
    switch event {
    case .connected:
        log("registered ✓ (serving \(modelId) across \(plan.worldSize) nodes)")

    case .disconnected:
        log("disconnected (will retry)")

    case .attestationChallenge(let nonce, let timestamp):
        if let r = try? attestationBuilder.buildChallengeResponse(
            nonce: nonce, timestamp: timestamp, providerPublicKey: keyPair.publicKeyBase64) {
            sendFn(.attestationResponse(AttestationResponsePayload(
                nonce: r.nonce, signature: r.signature, statusSignature: r.statusSignature,
                publicKey: r.publicKey, hypervisorActive: r.hypervisorActive,
                rdmaDisabled: r.rdmaDisabled, sipEnabled: r.sipEnabled,
                secureBootEnabled: r.secureBootEnabled, binaryHash: r.binaryHash,
                activeModelHash: r.activeModelHash, pythonHash: r.pythonHash,
                runtimeHash: r.runtimeHash, templateHashes: r.templateHashes,
                modelHashes: r.modelHashes)))
        }

    case let .inferenceRequest(requestId, ciphertext, senderPublicKey):
        guard let senderKey = senderPublicKey, senderKey.count == 32,
              let plain = try? keyPair.decrypt(senderPublicKey: senderKey, ciphertext: ciphertext),
              let req = try? JSONDecoder().decode(ChatCompletionRequest.self, from: plain) else {
            sendFn(.inferenceError(requestId: requestId, error: "decrypt/parse failed", statusCode: 400)); break
        }
        guard let promptTokens = try? ctx.tokenizer.applyChatTemplate(
            messages: req.messages.map { ["role": $0.role, "content": $0.content] },
            tools: nil, additionalContext: nil) else {
            sendFn(.inferenceError(requestId: requestId, error: "tokenize failed", statusCode: 400)); break
        }
        sendFn(.inferenceAccepted(requestId: requestId))
        queue.push(PendingQueue.Item(
            requestId: requestId, prompt: promptTokens,
            maxTokens: req.max_tokens ?? 512, senderKey: senderKey))

    default:
        break
    }
}
