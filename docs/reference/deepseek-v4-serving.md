# DeepSeek-V4 single-machine serving

How the provider serves DeepSeek-V4-Flash-4bit (284B-total / 13B-active MoE,
141GB on disk) on 36–128GB Apple Silicon machines. Everything below shipped on
the `deepseek-v4-flash-4bit` branch (provider) + `deepseek-v4-flash`
(Layr-Labs/mlx-swift-lm).

## Why it needs four subsystems

| Constraint | Subsystem |
|---|---|
| 141GB weights > any fleet box's RAM (and > the 90% `UnifiedMemoryCap`) | MoE expert SSD streaming |
| The batched engine can't represent DSV4's pooling/rotating hybrid caches | Sequential serving route |
| The checkpoint ships **no chat template**; tools use a bespoke DSML syntax | Native prompt encoder + DSML parser |
| M5 NAX bf16 GEMM kernels are nondeterministic for DSV4's HC shapes | `MLX_METAL_NO_NAX` release builds |

## 1. Expert SSD streaming (mlx-swift-lm `ExpertStreaming/`)

DSV4's non-expert weights are only ~4GB at 4-bit; the other ~137GB is 256
routed experts × 41 MoE layers, of which each token touches 6 per layer.

- **Load**: `StreamedWeightsModel.shouldStreamWeight` filters `switch_mlp`
  keys BEFORE shard eval (`Load.swift`) — the expert bytes are never read;
  full-model load is seconds at ~4GB resident.
- **Forward**: `StreamingQuantizedSwitchGLU` run-length groups the routed
  (token, expert) pairs (`gatherSort`), fetches missing experts via
  contiguous-per-expert `pread` (expert axis is outermost in the stacked
  tensors; fds cached per shard), stacks ≤16-expert chunks, and runs the SAME
  `gatherQuantizedMM` kernels as the resident path — parity is bit-exact.
- **Cache**: `ExpertCache` — process-wide byte-budgeted LRU keyed
  (layer, expert), ~13.6MB per mxfp4 expert. `purgeAll()` on model unload
  (wired in `BatchScheduler.stopCurrentEngine`), `setByteBudget` on load.
- **Budget** (`ExpertStreamingAdmission`, provider): everything derives from
  `UnifiedMemoryCap.hardCapBytes()` — `cache = cap − resident×1.2 −
  activationReserve − 8GB KV target`, clamped [0, 70GB]; explicit
  `expert_cache_gb` is clamped so it can never overcommit the cap. Admission
  (`ModelScanner`) advertises `resident + cache` instead of the naive
  on-disk×1.2.
- **Perf reality** (M5 Max, 70GB cache): steady-state hit rate 90–93%,
  decode 2.0–2.3 tok/s — bound by cold-miss disk reads (~0.3–0.8GB/token),
  not syscalls or GPU syncs. `DSV4_STREAM_PREFETCH` (last-token lookahead) is
  opt-in and measured useless at production cache sizes; frequency-profile
  warming is the active research lever.

Config: `[backend] stream_experts = true`, `expert_cache_gb = 0` (auto).
Env (harness/debug): `DSV4_STREAM_EXPERTS`, `DSV4_EXPERT_CACHE_GB`,
`DSV4_STREAM_CHUNK_EXPERTS`, `DSV4_STREAM_EVAL_THRESHOLD_MB`.

## 2. Sequential serving (provider `BatchScheduler`)

`Scheduler.supportsBatchedServing(cacheLayout:)` probes `model.newCache()` at
load; DSV4's `DeepseekV4LayerCache` fails it → `requiresSequentialServing`:

- Every request routes through `runSequentialRawTextPath`
  (`BatchScheduler+SequentialRawRunner.swift`): mlx-swift-lm's public
  `generateTokens` (raw token loop — CANNOT tool-parse or consume text) +
  incremental detokenization, with the same admission/billing/cancellation
  bookkeeping as the B=1 fast path. OpenAI `seed` is honored by seeding the
  RNG (sound because the route is single-request-exclusive).
- Exclusivity: one request at a time; others get the retryable
  `token_budget_exhausted` rejection. Heartbeats clamp advertised
  concurrency to 1 (`effectiveMaxConcurrentRequests`) so the coordinator
  doesn't dispatch guaranteed bounces.

## 3. Prompt encoding + DSML tools

There is no Jinja template — the official repo publishes a reference Python
encoder (`encoding/encoding_dsv4.py`) and golden fixtures instead.

- `DeepseekV4Encoding` (ProviderCoreFoundation) is a faithful Swift port:
  `<｜User｜>/<｜Assistant｜>` turns, `<think>` thinking/chat modes,
  drop-thinking rules (auto-disabled with tools), the `## Tools` DSML block,
  `<tool_result>` ordering, `reasoning_effort=max` prefix. The four official
  golden fixtures are mirrored as tests (byte-exact; tool-schema JSON compared
  semantically — Swift dictionaries can't preserve wire key order).
- Wired via `DeepseekV4TemplateFix` at all tokenization seams
  (`streamChatCompletion`, `/apply-template`, `submit`). `TemplateRenderCheck`
  runs the native encoder at scan time so `template_render_ok` stays honest.
- Tool-call output parses via `DSMLToolCallParser`
  (`ToolCallFormat.dsml`, model type `deepseek_v4*`), streaming-robust,
  multiple `invoke`s per block. Reasoning (`reasoning</think>content`,
  implicit-open think) splits via the existing deepseek parser, auto-selected
  by model type on all endpoints.

## 4. NAX

See `docs/spikes/nax-nondeterminism-m5.md`. Summary: M5 Neural-Accelerator
bf16 GEMM kernels drift run-to-run for some shapes (DSV4's hyper-connection
GEMM among them; 10-second repro `DSV4Smoke --op-stress`). Releases build with
`-Xcc -DMLX_METAL_NO_NAX`; Gemma-4 A/B measured zero cost. Re-test each mlx
bump.

## Validation surface

- mlx-swift-lm: `DeepseekV4Tests` (analytic RoPE, clamps, caches, quantized
  wo_a, newCache regression), `ExpertStreamingTests` (layout parser,
  byte-range math, LRU, decode/prefill parity, lifecycle), `ToolTests` (DSML).
- provider: `SequentialServingTests`, `ExpertStreamingAdmissionTests`
  (per-box-size cap fit), `SafetensorsSizingTests`,
  `DeepseekV4EncodingTests` (golden fixtures), scanner/config suites.
- Reference parity: pre-head hidden state vs mlx-lm PR #1192 at cosine 0.9987
  on real weights; resident-vs-streamed logits bit-identical.
- Live E2E (M5 Max): `darkbloom start --local` serving chat, split reasoning,
  DSML tool round-trip, tool-result follow-up, SSE streaming.
