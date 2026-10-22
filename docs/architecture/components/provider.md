# Provider process

> Last updated: 2026-10-22

The provider is the Apple Silicon Mac that decrypts prompts and runs inference.
It ships as one Swift package (`provider-swift/`) producing the `darkbloom` CLI,
a `darkbloom-enclave` helper and an optional `darkbloom-fan-helper`, all built
on the `ProviderCore` library and the three pinned MLX submodules described in
[`mlx-swift.md`](mlx-swift.md). This page maps the process's components; the
inference path itself is in [`../inference.md`](../inference.md).

## Context

The provider connects outbound to the coordinator over WebSocket, decrypts each
request in-process with its X25519 node key, serves it through one in-process
CBv2 engine per resident model, and encrypts the response back. It is the
decryption endpoint of the hop-by-hop model
([`../security/encryption.md`](../security/encryption.md)), so everything that
touches plaintext — template rendering, tokenisation, the engine, the KV cache —
lives inside this one hardened process. The authoritative provider version is
`ProviderCore.version` in `provider-swift/Sources/ProviderCore/ProviderCore.swift`.

## Mechanism

### Binaries and libraries (`provider-swift/Package.swift`)

| Product | Kind | Role |
|---|---|---|
| `darkbloom` | executable | CLI: `start`, `status`, `doctor`, `logs`, `benchmark`, `models`, `fan`, `watchdog`; long-running serve modes host an `NSApplication(.accessory)` run loop for APNs pushes (`provider-swift/Sources/darkbloom/main.swift`, `provider-swift/Sources/darkbloom/Darkbloom.swift`) |
| `darkbloom-enclave` | executable | Secure Enclave helper used by [coordinator/api/install.sh](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/coordinator/api/install.sh) before the daemon runs: `attest`, `sign`, `info` (`provider-swift/Sources/darkbloom-enclave-cli/`) |
| `darkbloom-fan-helper` | executable | Opt-in root LaunchDaemon for fan control; never installed by default (`provider-swift/Sources/DarkbloomFanHelper/`) |
| `ProviderCore` | library | Everything below; shared by the CLI and helpers |
| `ProviderCoreFoundation` | library | Pure-Foundation pieces also linked by publish tooling: `WeightHasher`, `PromptContractIdentity`, `TemplateRenderCheck`, `ModelScanner`, `Manifest` (`provider-swift/Sources/ProviderCoreFoundation/`) |
| `DarkbloomFanCore`, `DarkbloomFanProtocol`, `DarkbloomFanService` | libraries | SMC access, XPC boundary and lease validation for the fan helper |

### `ProviderCore` components

| Component | Responsibility | Code |
|---|---|---|
| Coordinator client | WebSocket connection, reconnection backoff, protocol codec, registration | `provider-swift/Sources/ProviderCore/Coordinator/CoordinatorClient.swift`, `provider-swift/Sources/ProviderCore/Coordinator/CoordinatorClientCodec.swift` |
| `ProviderLoop` (actor) | Event loop: inference requests and cancellations, `load_model` / `prefetch_model` / `desired_models`, heartbeats and capacity, attestation challenges, startup preload, idle timeout, auto-update | `provider-swift/Sources/ProviderCore/ProviderLoop.swift` and its `ProviderLoop+*.swift` extensions |
| Inference | `MultiModelBatchSchedulerEngine` → one `EngineV2Bridge` per model → CBv2; slot construction, memory model, deadlines, MTP, vision | `provider-swift/Sources/ProviderCore/Inference/` — [`../inference.md`](../inference.md), [`../hardware-support.md`](../hardware-support.md) |
| KV cache tiers | Encrypted SSD attention snapshots and complete checkpoints (`KVCacheSSD/`); resident paged blocks and recurrent checkpoints require explicit memory opt-in. `KVCache/` retains the legacy cache API and the shared key-wrapping service | `provider-swift/Sources/ProviderCore/KVCacheSSD/`, `provider-swift/Sources/ProviderCore/KVCache/` — [`../prefix-cache.md`](../prefix-cache.md) |
| Model discovery and download | Scan of the Hugging Face cache, quantization detection, padded memory estimate, catalog client, prefetch and hot-swap | `provider-swift/Sources/ProviderCore/Models/`, `provider-swift/Sources/ProviderCore/Server/ModelPrefetchCoordinator.swift` |
| Local / standalone serving | OpenAI-compatible HTTP on loopback or tailnet (`start --local`, `--local-endpoint`) using the upstream `MLXLMServer` router over the same engine | `provider-swift/Sources/ProviderCore/Server/StandaloneServer.swift`, `provider-swift/Sources/ProviderCore/Server/LocalInferenceHTTP.swift` |
| Security and identity | Secure Enclave P-256 identity, attestation blob, APNs code-identity, anti-debug, environment scrub, SIP/boot checks | `provider-swift/Sources/ProviderCore/Security/`, `provider-swift/Sources/ProviderCore/Apns/APNsBridge.swift` — [`../security/attestation.md`](../security/attestation.md) |
| Crypto | X25519 node keypair; NaCl Box via `swift-sodium` for the coordinator wire | `provider-swift/Sources/ProviderCore/Crypto/NodeKeyPair.swift` |
| Service management | launchd agents for the provider and the crash-recovery watchdog (`io.darkbloom.watchdog`), env allowlist (`passthroughEnvKeys`), daemon state file, sleep prevention | `provider-swift/Sources/ProviderCore/Service/LaunchAgent.swift`, `provider-swift/Sources/ProviderCore/Service/WatchdogAgent.swift`, `provider-swift/Sources/ProviderCore/Service/DaemonStateFile.swift`, `provider-swift/Sources/ProviderCore/Service/ProcessLifecycle.swift` |
| Hardware and telemetry | Chip identity, memory, thermal state; request profiles and telemetry allowlists | `provider-swift/Sources/ProviderCore/Hardware/`, `provider-swift/Sources/ProviderCore/Telemetry/` — [`../telemetry.md`](../telemetry.md) |

```mermaid
flowchart LR
    Coord[coordinator] -- WebSocket, NaCl Box --> CC[CoordinatorClient]
    CC --> PL[ProviderLoop]
    PL --> MM[MultiModelBatchSchedulerEngine]
    LH[StandaloneServer / LocalInferenceHTTP] --> MM
    MM --> B1[EngineV2Bridge model A]
    MM --> B2[EngineV2Bridge model B]
    B1 --> E[CBv2 EngineV2 → Metal]
    B2 --> E
    B1 -. capability and identity gates .-> SSD[Encrypted SSD snapshots / complete checkpoints]
    B1 -. explicit memory opt-in .-> RAM[Resident paged blocks / recurrent checkpoints]
    PL --> SE[Secure Enclave identity / attestation]
```

### Process boundaries

`ProviderLoop+Serve.swift` reads App Attest messages, authorization status and
connection invalidation before forwarding slower events to its ordered work
consumer. An inference handler awaiting a model load therefore cannot hold a
renewal reply or a received grant update. Both consumers belong to the same
serve invocation; shutdown finishes the work stream and waits for its consumer.
The [attestation lifecycle](../security/attestation.md#provider-connection-control)
owns the connection and trust guarantees.

An accepted request whose model is not resident releases the work consumer when
it starts waiting for the load (`ProviderLoop+WorkFIFO.swift`), so later
inference requests, cancels and attestation challenges are not held behind
weight loading. A coordinator cancel for the waiting request is applied when its
admission returns, where the serial consumer applied it. Connection, drain and
model-management events, and the end of the work stream, still wait for it. So
does a request for another model that is not resident, before its pre-accept
capacity check (`awaitReleasedLoads`): the waiting load has not yet taken the
memory or slot that check sizes. Native MiMo requests keep the serial consumer.
`DARKBLOOM_TTFT_COLD_LOAD_RELEASE=0` restores the fully serial consumer.

- **In-process inference.** The MLX stack is linked into the `darkbloom`
  binary; there is no Python interpreter and no inference subprocess. Runtime verification can launch a child for paged-kernel preflight
  (`PagedKernelPreflight`, `runtime-smoke`); platform checks and service
  management also invoke system tools. The crash-recovery watchdog is
  managed separately by launchd. The optional local HTTP
  endpoint serves from the same loaded models in the same process.
- **Fan helper.** A separate root LaunchDaemon that accepts an activity lease
  only from the exact Darkbloom signing identity and can write only the SMC fan
  keys exposed by `DarkbloomFanCore`; it receives no prompts, keys or network
  (`provider-swift/Sources/DarkbloomFanProtocol/FanIPC.swift`,
  `provider-swift/Sources/DarkbloomFanHelper/FanXPCService.swift`).
- **promptsidecar** is a coordinator-side process; the provider computes the
  same contract identity locally and never talks to it
  ([../prompt-contract-sidecar.md](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/architecture/prompt-contract-sidecar.md)).

### Reconnect and attestation lifecycle

`ProviderLoop.run` captures the existing process key for `CoordinatorClient`'s
endpoint-resumption responder. `CoordinatorClient.connectAndRun` gives every
socket a fresh registration nonce and clears its resume state on teardown.
The normal provider installs
the [protocol-1 resumption responder](../../reference/protocol-messages.md#app-attest-endpoint-resumption-candidate)
without requiring the worker flag. It is synchronous, with no Apple operation,
model-state change or key persistence. It proves custody only; the platform decides
whether the new connection may serve. Unexpected disconnect still cancels that
connection's inference requests; this does not resume interrupted completions
or prove two-minute engine continuity.

Apple exchanges use `AppAttestShadowReply`, a capability bound to their original
`NWConnection`, rather than the reconnectable outbound router. Late results are
discarded after transport replacement, even before `ProviderLoop` consumes the
disconnect event. Sources: `provider-swift/Sources/ProviderCore/Coordinator/CoordinatorClient+Connection.swift`
(`connectAndRun`), `Coordinator/AppAttestShadowReply.swift` (`sendAppAttestShadow`)
and `provider-swift/Sources/ProviderCore/ProviderLoop+Serve.swift` (`run`).

The default App Attest implementation stays in-process. The internal,
default-off [worker candidate](../security/identity-binding.md#supervised-app-attest-worker-candidate)
uses another invocation of the same signed executable, with no inference or
endpoint private key in the child. `cancelAppAttestShadow` invalidates the old
exchange generation and chains worker retirement before the next transport can
start verification. `stopAppAttestWorkerAndWait` is a terminal shutdown barrier.
The separate `stopAppAttestWorkerForUpdateAndWait` guards installation and every
update restart, including an already-installed candidate. A failed reap withholds
drain completion or postpones update; a fresh `prepare` may retry retained-owner
cleanup only after a failed update returns to idle, never after terminal shutdown.
No worker-stall recovery restarts inference or falls back to in-process Apple
work (`provider-swift/Sources/ProviderCore/ProviderLoop+AppAttestShadow.swift`,
`ProviderLoop+Lifecycle.swift`, `ProviderLoop+AutoUpdate.swift`).

## Invariants

1. Prompts are decrypted only inside this process and never logged; logs carry
   request ids, model ids and token counts — `ProviderLoop+InboundDecode.swift`,
   `ProviderLoop+InferenceHandler.swift`.
2. The X25519 private key is generated in the parent and remains only in that
   process's memory, including with the worker candidate selected; it is never
   exported to the worker or persisted — `Crypto/NodeKeyPair.swift`,
   `ProviderLoop+AppAttestWorker.swift`.
3. The SE P-256 identity binds the node key, binary hash, SIP and boot state
   into every attestation — `Security/AttestationBuilder.swift`,
   `Security/PersistentEnclaveKey.swift`.
4. Installed daemons receive only allowlisted environment variables —
   `Service/LaunchAgent.swift` (`passthroughEnvKeys`).
5. One `EngineV2Bridge` per resident model, at most `max_model_slots` (default
   `3`) — `ProviderLoop+ModelLoading.swift`, `Config/ProviderConfig.swift`.

## Failure modes

| Symptom | Cause | Where |
|---|---|---|
| Daemon exits at start | Metal or RAM preflight failed ([`../hardware-support.md`](../hardware-support.md)) | `provider-swift/Sources/darkbloom/Start/StartCommand+Preflight.swift` |
| Provider offline after a crash | Watchdog agent stopped or persistently disabled | `Service/WatchdogAgent.swift` |
| Env knob has no effect on the installed daemon | Not in `passthroughEnvKeys` | `Service/LaunchAgent.swift` |
| Attestation trust downgraded | SIP off, boot-security warning, or stale APNs code-identity | `Security/BootSecurity.swift`, `Apns/APNsBridge.swift` — [`../../provider/attestation.md`](../../provider/attestation.md) |

## Code map

| Concern | Path |
|---|---|
| CLI | `provider-swift/Sources/darkbloom/` |
| Enclave helper | `provider-swift/Sources/darkbloom-enclave-cli/` |
| Core library | `provider-swift/Sources/ProviderCore/` |
| Foundation-only library | `provider-swift/Sources/ProviderCoreFoundation/` |
| Fan control | `provider-swift/Sources/DarkbloomFanCore/`, `provider-swift/Sources/DarkbloomFanProtocol/`, `provider-swift/Sources/DarkbloomFanService/`, `provider-swift/Sources/DarkbloomFanHelper/` |
| Cache setup and outcomes | `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/EngineV2SlotFactory+AttentionPrefixCache.swift`, `provider-swift/Sources/ProviderCore/Inference/Engine/Bridge/EngineV2RequestUsageSignal.swift` |
| Download publication and catalog bounds | `provider-swift/Sources/ProviderCore/Models/ModelDownloader+Manifest.swift`, `provider-swift/Sources/ProviderCore/Models/ModelCatalogClient+Bounds.swift` |
| Shared system command execution | `provider-swift/Sources/ProviderCore/Process/SecurityCommandRunner.swift`; doctor probes retain deadlines through `provider-swift/Sources/ProviderCore/Process/BoundedProcess.swift` |
| CLI config mutations | `provider-swift/Sources/darkbloom/ConfigMutation.swift` (`withMutableConfig`) |
| Tests | `provider-swift/Tests/` |

## Related

- [`mlx-swift.md`](mlx-swift.md) — the three pinned submodules and the metallib
- [`../inference.md`](../inference.md), [`../prefix-cache.md`](../prefix-cache.md), [`../hardware-support.md`](../hardware-support.md)
- [`../security/encryption.md`](../security/encryption.md), [`../../provider/attestation.md`](../../provider/attestation.md)
- [coordinator.md](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/architecture/components/coordinator.md) — the other side of the WebSocket
- [`../../provider/cli-reference.md`](../../provider/cli-reference.md), [`../../provider/fan-control.md`](../../provider/fan-control.md)
