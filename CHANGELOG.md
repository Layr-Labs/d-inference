# Changelog

## Unreleased (v0.8.5 candidate - provider)

### Provider (Swift)

#### Performance

- **Qwen3.6 E=256 expert-tile prefill route + fused gate_up** - Instantiates the Gemma4 descriptor/tile kernel family for Qwen's 256-expert shapes (mlx `d3c82db`), fuses the routed gate/up projection into one gather (`SwitchGLU(fuseGateUp: true)`, per-layer and per-load with heterogeneous-quantization split fallback across every checkpoint key space), and adds the opt-in `trust` refinement that skips the per-chunk retract drain. Measured on M4 Max, prod artifact: routed MoE block -26.3% at T=512; end-to-end prefill 1243→1364 tok/s default, 1433 with `trust` (+15.2%) at 8k; 2k +7.4%, 32k +6.6%. (#617, mlx-swift-lm#107)
- **Qwen3.6 MTP: GDN capture-verify, target_prefix acceptance, single-forward drafts** *(behind the `mtp` beta flag, default off)* - Replaces the serial target verify (measured 0.70x vs MTP-off) with one `[1,1+k]` forward capturing per-position recurrent states (1.08x), lifts the `temperature == 0` eligibility gate via pre-sampled target-token acceptance (exact at any temperature; temp-0.7 speculates at 0.70-0.77 acceptance), and defers the draft pair to eliminate the second MTP-head forward + 286 MB lm_head re-read per round: **116.5 tok/s vs 104.8 MTP-off (1.11-1.13x) at 0.78 acceptance**, B=1 greedy, release, paired sessions. (#616, mlx-swift-lm#106/#108)
- **mlx gpu::eval use-after-free fix** - A stale `MTL::CommandBuffer` captured across `eval_gpu` could crash any primitive that syncs mid-eval (deterministic SIGSEGV on the E=256 route; previously survived on allocator luck). (mlx#5/#7)

#### Fixes

- **Inline-MTP inspection resolves HF-cache symlinks and rejects loudly** - Symlinked snapshots (the standard HF `blobs/` layout) silently disabled inline MTP: `inspectInlineArtifact` required regular files and reported nothing. Inspection now resolves links and validates targets; every genuine rejection logs a concrete reason and path. Untrusted operator-path inspection stays symlink-rejecting. (#618)

#### Observability

- **MTP posture and acceptance on the local `/metrics` endpoint** - `mtp_enabled`, `mtp_active`, `mtp_rounds_total`, `mtp_tokens_proposed_total`, `mtp_tokens_accepted_total`, and `mtp_inactive_reason{model,reason}` (including `inline_artifact_invalid`) in both `--local` and unified serving modes - acceptance was previously observable only in Datadog Logs. (#619)

### Coordinator

#### Fixes

- **Expose exact Hugging Face repositories in model feeds** - Registry metadata can now override `hugging_face_id` independently of the internal routing ID. Both `/v1/models` and `/v1/models/openrouter` honor the override for concrete and aliased models, with an authenticated `hugging-face-id` admin action for existing registry rows. (#620)

---

## v0.8.4 (2026-08-13)

### Provider (Swift)

#### Fixes

- **Stream Qwen3.6 reasoning deltas immediately (TTFT fix)** - Qwen3.6-style chat templates pre-open the `<think>` block at the prompt tail, so model output carries only the closing tag and the streaming think parser buffered the entire block before emitting anything: measured prod TTFT was `755ms + 12.51ms x reasoning_tokens` (r = 0.9878) while the first byte arrived in ~76ms. The engine now probes the rendered prompt tail (`ReasoningPromptProbe`) and injects one synthetic `<think>` open ahead of model output — gated on an active think-format parser and streaming — so `reasoning_content` streams per chunk and TTFT reflects real first-token latency. Text and VLM paths; the marker never reaches the prompt, the consumer, or the TB-007 hash domain. (#614)

---

## v0.8.3 (2026-08-12)

### Provider (Swift)

#### Features

- **Qwen3.6-35B-A3B VLM with inline MTP** - Adds production-path text, image, and tool inference for the combined Qwen artifact. The runtime preserves request-owned recurrent and three-axis mRoPE state, causal vision attention, exact rollback, and source-matched target/assistant memory accounting. MTP remains depth-one, serial, and exact-target-verified; video, prefix reuse, paged KV, compiled decode, packed prefill, and rectangular MTP remain fail-closed.

#### Release Safety

- The model is registered as beta/ready without an alias or active-version promotion. Provider rollout and model promotion remain separate reviewed operations after the signed `v0.8.3` bundle passes a controlled fleet canary.

---

## v0.8.2 (2026-08-10)

### Provider (Swift)

#### Performance

- **Gemma 4 26B-A4B v0.8.2 optimization stack** — Layer-18 lazy prefill submission; coupled weighted-expert-unsort + safe-R1 expert-QMM gate (both default-on via `[gemma_optimizations]`); the VLM wrapper's directly shared text tower; packed multimodal prefill inside q=128 query blocks; source-matched metallib enforced across CI/release/packaged smoke. Final performance and retention deltas are pending a same-tree A/B measurement on the reviewed release tree. Earlier gitignored measurements predated the final kernel edits and are not release evidence. Dropped before the final cut: expert gate/up packing, dense gate/up packing, standalone weighted-unsort, standalone R1. `0cc5fc9c9`

#### Security

- **Keep inline video plaintext off disk** — The provider decodes coordinator-inlined MP4/QuickTime bytes through a bounded, memory-backed AVFoundation asset, retains the byte owner through metadata probing and frame sampling, and rejects external asset references. Exact-name legacy `vlm-<UUID>.mp4` files are purged once after single-instance lock acquisition on both coordinator-connected and standalone launch paths.
- **Close unintended provider-derived plaintext egress paths** — Provider inference failures cross the WebSocket and client boundary only as closed-vocabulary codes/reasons, while browser/provider free-form telemetry and automatic provider log reporting are retired. The explicit `darkbloom report` support command remains operator-initiated, preserves macOS unified-log privacy redaction, supports local `--dry-run` review, and uses authenticated upload plus admin-only retrieval.

---

## Unreleased (Apr 26 - May 25, 2026)

26 commits since `aa74499`.

### Coordinator

#### Features

- **DB-backed model registry** (#203) -- Model catalog is now stored in Postgres with R2-hosted manifests. Includes readable prefixes, runtime limits, runtime parameters, hardened validation, and provider inventory preservation across catalog updates. `50e8887b`
- **Token-budget routing with engine-level admission** (#171) -- Replaces heuristic-based routing with engine-reported capacity signals. Providers report real `activeTokens`, `maxTokensPotential`, and token budget usage. Coordinator uses EWMA observed TPS, fleet median fallback, and token-budget admission. 5 new fields on `BackendSlotCapacity` (backward-compatible). 25+ new tests. `78314b4e`
- **Speculative TTFT dispatch** (#171) -- Parallel dispatch to a backup provider at 50% of the TTFT deadline. First provider to deliver a token wins; loser is cancelled. No double-billing. OpenRouter TTFT SLA enforcement (5s base + 1ms/input token). `78314b4e`
- **Early 429 with Retry-After for capacity signaling** (#171) -- Returns 429 instead of 503 when fleet is at capacity (no uptime penalty on OpenRouter). `GET /v1/models/capacity` endpoint for observability. `ModelCapacitySnapshot` with per-model routable/warm/cold providers, aggregate TPS, estimated TTFT, and token budget headroom. `78314b4e`
- **Coordinator-driven model preload protocol** (#110) -- New `load_model` / `load_model_status` WebSocket messages allow the coordinator to push model warm-up requests to providers ahead of demand. `56b050b4`
- **Datadog observability stack** (#143) -- DogStatsD, APM, journald log collection on dev GCE VM. Structured metrics: attestation counters, model_type tags, provider-count gauges, completion-tokens counter, fleet version/binary hash observability, billing histograms (reservation, settlement, provider credits, platform fees), store latency, input token metrics. `56b050b4`
- **X-Timing latency decomposition header** (#136) -- Single JSON header with per-phase microsecond breakdown: `parse_us`, `reserve_us`, `route_us`, `queue_us`, `encrypt_us`, `dispatch_us`, `provider_us`. `56b050b4`

#### Bug Fixes

- **Structured JSON 404 for unimplemented /v1/* endpoints** (#168) -- Catch-all handler returns `application/json` errors instead of Go's default `text/plain` 404. Prevents OpenAI SDK parse failures on `/v1/embeddings`, `/v1/moderations`, etc. Added openai-go SDK compatibility tests. `e108da5f`
- **OpenAI error response `code` and `param` fields** (#144) -- `errorResponse` now populates `code` and `param` per the OpenAI API spec. `insufficient_quota` canonical code, `param="model"` on model errors. All 202 existing call sites backward-compatible. `e108da5f`
- **Require country for Stripe payout onboarding** (#179) -- `2e262b73`
- **Stripe dashboard metadata** -- `35582c82`
- **Prevent double-decrement on untrusted provider disconnect** (#143) -- `MarkUntrusted` race fix: hold write lock through counter decrement. Heartbeat no longer revives untrusted providers. `56b050b4`
- **Skip Python/dangerous-modules check for Swift runtime** (#143) -- Private text routing gate correctly bypasses Python-specific checks for Swift providers. `56b050b4`
- **Fix planner pending leak** (#171) -- Changed `planner.complete()` to `planner.cancel()` in request completion path. Without this, pending entries accumulated until `maxQueuedRequests` (128), permanently bricking the provider. `78314b4e`
- **Refund provider-specific extra on generic dispatch** (#171) -- All 14 failure paths after `reserveAdditionalForProvider` now refund the delta in `handleGenericInference`. `78314b4e`
- **activeRequests counted per-model, not per-provider** (#171) -- `ModelCapacitySnapshot` now counts only pending requests matching the specific model. `78314b4e`
- **Link test providers to user account** (#174) -- Ensures payout destination check passes for test providers. `f4219c4f`

#### Breaking / Protocol Changes

- **Go module path changed** -- `github.com/eigeninference/coordinator/internal/X` -> `github.com/eigeninference/d-inference/coordinator/X`. Module path is now `github.com/eigeninference/d-inference`. `coordinator/internal/` flattened to `coordinator/`. `56b050b4`
- **Bundle filename changed** -- Coordinator now accepts `darkbloom-bundle-<platform>.tar.gz` (was `eigeninference-bundle-`). `56b050b4`

---

### Provider (Swift)

#### Features

- **Swift provider runtime shipped** (#110) -- Full `darkbloom` CLI with `serve`, `start`, `stop`, `status`, `doctor`, `models`, `benchmark`, `login`, `logout`, `enroll`, `update`, `verify` subcommands. Production inference via MLX-Swift on Apple Silicon. GPU-only enforcement. Rename from `eigeninference` to `darkbloom` with backward compatibility. `56b050b4`
- **Continuous batching** (#110) -- All concurrent requests merged into one batched forward pass per step via `BatchGenerator`. Bit-identical against single-stream greedy. Near-linear throughput scaling (B=4/B=1 = 3.8x on Qwen, 2.9x on Gemma MoE). `56b050b4`
- **Multi-model concurrent serving** (#167) -- `953b8f02`
- **MLXLMServer adoption for OpenAI protocol** (#208) -- `ca8983c4`
- **BatchedEngine migration** (#207) -- `BatchScheduler` migrated from `BatchGenerator` to `BatchedEngine`. `80fc0ee7`
- **Idle-timeout model unload** (#110) -- Provider unloads model after 60 minutes idle (configurable). Next request lazy-reloads. `56b050b4`
- **Persistent Secure Enclave key** (#146) -- Replaces ephemeral CryptoKit SE keys with persistent Security framework keys in the macOS data protection keychain. Bound to signing team's keychain access group. .app bundle with embedded provisioning profile. `56b050b4`
- **Token budget engine-level admission** (#171) -- `BatchScheduler` reports real token budget usage. EWMA decode TPS tracker. Engine-level admission gate rejects with `token_budget_exhausted`. Dynamic token budget sized from model weight bytes and available memory. `78314b4e`
- **Architecture-aware kvBytesPerToken** (#171) -- Computed from config.json metadata (layer count, KV heads, head dim) instead of weight-bytes heuristic. Handles hybrid attention (Gemma 4), GQA/MQA, recurrent layers (Qwen3.5), and VLM wrappers. 4x reduction on Qwen3.5 models. `78314b4e`
- **Rust-to-Swift bridge auto-update** (#110) -- Rust provider auto-updates to Swift bundles, rewrites launchd plist, handles .app bundle layout. `56b050b4`

#### Performance

- Greedy fast-path optimization: `nil` sampler for temperature=0 uses vectorized fallback (+6-13% decode TPS). `56b050b4`
- mlx-swift-lm double buffering, UInt32 token tensors. `56b050b4`
- Release-mode BatchGenerator B=4 matches mlx_lm Python reference (Qwen: ~1130 vs 1119 tok/s; Gemma: ~186 vs 181 tok/s). `56b050b4`

---

### Console UI

- **Refresh earn calculator and landing page** (#185) -- `ed6d655e`
- **Fix Next.js version vulnerability** (#172) -- `2f65bb41`
- **Analytics tracking fix** -- `f7dab6fa`

---

### Testbed / E2E

- **Integration test suite** (#136) -- 12 E2E tests with real Swift provider (Postgres + coordinator + provider per test). Tests: NonStreaming, Streaming, Concurrent, Encryption, Billing, Payout, Referral, InsufficientBalance, InvalidModel, AttestationHeaders. `56b050b4`
- **Load generator and profiling** (#136) -- Configurable concurrency, streaming, benchmark CI with PR comment posting. Heavy-load 100-concurrent 10KB benchmark. Latency regression assertions. `56b050b4`
- **Performance test suite** (#110) -- Warm/cold TTFT, encrypted E2E, batched throughput, decode-TPS bracket tests for Qwen 0.6B and Gemma 26B MoE. `56b050b4`

---

### Security

- **Harden release registration and binary hash policy** (#99) -- Release download URL derived from allowlist. `b5dd0488`
- **Harden release workflow protections** (#103) -- `e515244f`
- **Rust-to-Swift cutover hardening** (#110) -- Post-codesign verification of entitlements, provisioning profile validation (team ID, access group, expiration), MLX wheel pinning, prod hard-fail on Swift tests. `56b050b4`
- **STRIDE threat model** (#110) -- 40 threats across 9 trust boundaries. Automated PR review workflow via Claude API. `56b050b4`
- **Typed response structs for OpenAI endpoints** (#166) -- `7fbfa9fc`

---

### Billing

- **Remove deprecated Solana/wallet-based provider payouts** (#178) -- `fe994fc9`

---

### CI / Infrastructure

- **Migrate CI workflows to Blacksmith** (#182) -- `ff8527a4`
- **CI runs on any PR** (#119) -- Not just master/main. `98a3a024`
- **Remove racing deploy-dev-coordinator workflow** (#137) -- Eliminates race condition with Cloud Build. `cf4c0efa`
- **DEV_/PROD_ prefixed repo secrets** -- Environment-scoped R2 + coordinator secrets for release isolation. `56b050b4`
- **Native Postgres fallback for CI** -- Docker/colima replaced with `initdb + postgres` on macOS runners. `56b050b4`
- **Correct version comments for SHA-pinned actions** (#160) -- `85cedc7e`

---

### Housekeeping

- **Remove unused dependencies** (#112) -- `7ccc592f`
- **Remove stale Python integration test** (#109) -- `e6d63a86`
- **Bump mlx-swift and mlx-swift-lm submodules** (#206) -- Re-homed to Layr-Labs forks. `5919dac1`
- **Darkbloom license agreement** (#173) -- `dde67b28`
- **Update README** (#176) -- `7451a473`
