# Provider

The provider is the Apple Silicon Mac node that runs inference. It is implemented in Swift as the `darkbloom` CLI, with shared logic in `ProviderCore` and a small `darkbloom-enclave` helper for attestation/signing operations. The provider connects outbound to the coordinator over WebSocket, decrypts prompts in-process, runs inference via `mlx-swift-lm`, and encrypts responses back to the coordinator.

The provider is the decryption endpoint for prompts. Its hardened process and Secure Enclave-bound identity are the core privacy guarantee.

## Responsibilities

| Responsibility | Where it lives |
|---|---|
| CLI entry point and subcommand dispatch | `provider-swift/Sources/darkbloom/main.swift`, `provider-swift/Sources/darkbloom/Darkbloom.swift` |
| Coordinator WebSocket client and protocol codec | `provider-swift/Sources/ProviderCore/Coordinator/CoordinatorClient.swift`, `CoordinatorClientCodec.swift` |
| Main event loop: requests, heartbeats, challenges, model swaps | `provider-swift/Sources/ProviderCore/ProviderLoop.swift` |
| Secure Enclave identity, attestation signing, code-identity | `provider-swift/Sources/ProviderCore/Security/SecureEnclaveIdentity.swift`, `AttestationSigner.swift`, `AttestationBuilder.swift` |
| Batch scheduling and inference engine bridge | `provider-swift/Sources/ProviderCore/Inference/BatchScheduler.swift`, `MultiModelBatchSchedulerEngine.swift` |
| Model discovery, weight hashing, prefetch/hotswap | `provider-swift/Sources/ProviderCore/Models/ModelScanner+Discovery.swift`, `Server/ModelPrefetchCoordinator.swift` |
| In-process local OpenAI-compatible HTTP endpoint (optional unified mode) | `provider-swift/Sources/ProviderCore/Server/LocalInferenceHTTP.swift`, `StandaloneServer.swift` |
| Crypto: NaCl Box, node keypair, response encryption | `provider-swift/Sources/ProviderCore/Crypto/NodeKeyPair.swift`, `X25519ChaChaPoly.swift` |
| KV cache, prefix caching, disk accounting | `provider-swift/Sources/ProviderCore/KVCache/` |
| Security hardening: anti-debug, env scrub, SIP checks | `provider-swift/Sources/ProviderCore/Security/SecurityHardening.swift`, `EnvironmentScrubber.swift`, `AntiDebug.swift` |

## Key modules

### CLI (`provider-swift/Sources/darkbloom/`)

`main.swift` is the entry point. Long-running serve modes (`start --foreground`, `start --local`) are hosted under an `NSApplication(.accessory)` run loop so the process can receive APNs code-identity pushes; other commands run through ArgumentParser's async dispatch. `Darkbloom.swift` declares the top-level `AsyncParsableCommand` with subcommands: `start`, `stop`, `restart`, `status`, `doctor`, `models`, `login`, `logout`, `benchmark`, `update`, `verify`, `enroll`, `unenroll`, `logs`, `report`, `autoupdate`, `watchdog`, and `local`.

### ProviderCore

`ProviderCore` is a Swift library shared by the CLI and the enclave helper. It contains:

- **Coordinator client** (`Coordinator/`): maintains the WebSocket connection, reconnection backoff, and the advertised model store.
- **ProviderLoop** (`ProviderLoop.swift`): the actor-based event loop. It owns per-model inference slots (`modelSlots`), handles inference requests, cancellations, `load_model` / `prefetch_model` / `desired_models` messages, and attestation challenges.
- **Inference** (`Inference/`): `BatchScheduler` and `MultiModelBatchSchedulerEngine` translate coordinator requests into `mlx-swift-lm` calls. Each loaded model gets its own slot with continuous batching and prefix caching.
- **Security** (`Security/`): Secure Enclave key generation, attestation blob construction, code-identity response handling, and runtime hardening checks.
- **Crypto** (`Crypto/`): X25519 keypair for E2E encryption and ChaCha20-Poly1305 helpers used in some local paths. The coordinator↔provider wire uses NaCl Box via `swift-sodium` for cross-language compatibility with Go `nacl/box`.
- **KV cache** (`KVCache/`): prefix caching in RAM, optional encrypted disk persistence, and a global KV-cache budget.

### Attestation and identity

At startup the provider creates or loads a persistent Secure Enclave P-256 identity (`Security/PersistentEnclaveKey.swift`) and an X25519 node keypair (`Crypto/NodeKeyPair.swift`). The attestation blob signed by the SE key contains hardware identity, SIP/Secure Boot state, the X25519 public key, and the provider binary hash. The coordinator verifies the signature and binds the X25519 key to that identity.

APNs code-identity attestation (v0.6.0+) is implemented in `ProviderCore/Apns/APNsBridge.swift`. The coordinator pushes an encrypted nonce to the device token; the provider decrypts it with its SE-bound key and returns a signature over the WebSocket connection.

### darkbloom-enclave helper

`provider-swift/Sources/darkbloom-enclave-cli/` is a small executable that wraps Secure Enclave attestation/signing helpers. It is used by `install.sh` to render an attestation blob before the main provider daemon is running. Subcommands include `attest`, `sign`, `info`, and `wallet-address`.

## Privacy-relevant boundaries

- **Provider as decryption endpoint**: The provider's X25519 private key is generated in-process and never leaves the Mac. Only this process can open the coordinator's per-request NaCl Box. See `Crypto/NodeKeyPair.swift` and the decryption path in `ProviderLoop.swift`.
- **In-process inference**: Inference runs inside the `darkbloom` process via `mlx-swift-lm`. There is no subprocess or local server that another process can observe. The optional local HTTP endpoint (`LocalInferenceHTTP.swift`) serves from the same loaded models but is still in-process.
- **Secure Enclave binding**: The SE P-256 identity and the X25519 node key are bound to the provider binary and machine. Attestation challenges prove liveness and fresh SIP/Secure Boot status.
- **Memory and disk**: Model weights and KV cache live in unified memory. Optional encrypted KV-cache persistence uses a Secure-Enclave-wrapped KEK. See `KVCache/EncryptedKVStore.swift` and `KVCache/SecureEnclaveKeyWrappingService.swift`.
- **No prompt logging**: The provider decrypts prompts only to feed the inference engine. It does not log prompt content; logs contain request IDs, model IDs, and token counts.

For the hop-by-hop encryption model, see [`../security/encryption.md`](../security/encryption.md) and the coordinator-side description in [`coordinator.md`](coordinator.md).

## Outdated claims corrected

- The old `ARCHITECTURE.md` listed two binaries (`darkbloom` and `darkbloom-enclave`) and described `darkbloom-enclave` as legacy-named `eigeninference-enclave`. The current `Package.swift` produces `darkbloom-enclave` as a first-class helper; the legacy symlink is retained by `install.sh` for backward compatibility.
- The old doc claimed inference is "in-process" with no IPC. This remains true for the Swift `mlx-swift` backend, but the optional unified local endpoint (`LocalInferenceHTTP.swift`) exposes an in-process HTTP server surface for the same models.
- The old doc's claim that "Python path is locked to signed bundle" refers to the deprecated Python/inprocess-MLX backend, which is no longer routable.
