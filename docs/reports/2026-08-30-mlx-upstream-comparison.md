# Upstream MLX comparison — what's worth importing (2026-08-30)

> Last updated: 2026-08-30 · commit `5d400cf75`

Comparison of our three vendored forks against upstream `ml-explore` HEAD, scoped to the
production workload: **B=1–5 continuous batching, decode-weighted**, serving
`qwen3.5-35b-a3b`, `qwen3.6-35b-a3b-vl-mtp-mxfp8`, `gpt-oss-20b`, `gemma-4-26b`
variants, and `qwen3-vl-30b-a3b-instruct` (roster confirmed live via
`GET https://api.darkbloom.dev/v1/pricing`).

Method: upstream clones in a session scratchpad; merge-base per fork; every candidate
commit checked first for a prior port (our June 2026 selective port cites upstream
hashes) and then logic-compared against our files. Verdicts were verified against actual
code on both sides, not commit messages.

## Baseline facts

| Repo | Ours | Upstream | Divergence |
|---|---|---|---|
| `libs/mlx-swift-lm` | `fe01df9` (fork of ml-explore/mlx-swift-lm) | `37688d2` main | merge-base 2026-04-17; 211 upstream commits we lack, 210 ours they mostly lack |
| `libs/mlx-swift` | `1d452d8` (0.31.4 + 24) | `d737cd0` main | merge-base 2026-06-18; 17 upstream commits we lack |
| `libs/mlx` (core) | `d3c82db0` = pre-v0.32.0 base **+ 7 commits / 13 files** | `v0.32.2` (2026-08-25) | our base is **33 commits behind v0.32.0**; 279 more to v0.32.2 |

Two constraints that shape everything below:

1. **Direction.** Upstream mlx-swift's core pin (`ce45c52`) is **227 commits behind
   v0.32.0** — behind us. No "bump to upstream mlx-swift(-lm)" is ever a valid move;
   every item is a cherry-pick/port onto our forks.
2. **Bidirectional flow.** Several recent upstream Qwen perf commits are near-verbatim
   copies of our work landed *after* ours (upstream #573's `weighted_expert_unsort`
   kernel is byte-identical to our `SwitchLayers.swift`; #572 mirrors our GDN fusion,
   ours 2026-08-21 vs theirs 2026-08-28). Check dates before porting any future
   upstream "Qwen perf" commit — it may be an echo of ours.
3. Upstream mlx-swift-lm now floors on mlx-swift ≥ 0.31.6 for new API; each ported
   snippet needs a per-item API check against our 0.31.4+24 fork (none of the
   recommended imports below hit a missing API — the router/TurboFlash kernels use
   `MLXFast.metalKernel`, which we have).

---

## Tier 0 — correctness bugs live in production today

### 1. CBv2 streaming detokenizer silently drops characters (concept from upstream `45693f6`)
`DetokenizerV2.emit(upTo:)` computes the streamed delta as a **byte-count suffix**
(`stable[emittedBytes...]` guarded by `stable.count > emittedBytes`,
`Libraries/MLXLMCommon/ContinuousBatchingV2/DetokenizerV2.swift:101-106`). When a
SentencePiece decode collapses whitespace at an append boundary (upstream demonstrated
on Gemma: `"\n  "` + `","` → `"\n ,"`), the new decode is no longer than
`emittedBytes`, the delta is `""`, and the character (in upstream's case a structural
JSON comma) is silently dropped from streamed text. We serve gemma-4-26b and
`BatchedToolStreamHandler` parses accumulated *text*, so this can corrupt tool args.
Fix: apply upstream's common-prefix-diff concept to `DetokenizerV2` (their patch
targets their `NaiveStreamingDetokenizer`; ours in `Tokenizer.swift:133` has the same
bug but is unused by CBv2). **Effort S. Trigger frequency unmeasured — add a
regression test with the Gemma whitespace-collapse case.**

### 2. Qwen 3.5/3.6 JSON tool calls are lost + int 0/1 becomes Bool (`3260260` + one fix from `7871b09`)
Our `qwen3_5*` tool parsing resolves to `.xmlFunction` only
(`Tool/ToolCallFormat.swift:220`) — a pure `<function=…>` regex. When the model emits
its known Hermes-JSON dialect inside `<tool_call>`, the parse returns nil and the call
ships as plain text. Upstream's `Qwen35ToolCallParser` (JSON fallback) ports cleanly
onto our `ToolCallParser` protocol. Import together with the embedded `7871b09` fix:
our `JSONValue.from` matches `as Bool` before `as Int` (`Tool/Value.swift:63-66`), so
NSNumber `0/1` from JSONSerialization becomes `true/false` — `{"limit": 1}` →
`{"limit": true}` — a live bug for XML-parsed calls today and inherited by the new JSON
path if not fixed jointly. The rest of `7871b09` is superseded by our
`GemmaFunctionParser` work. **Effort S.**

### 3. Image requests skip the sRGB tone curve (`2118561`)
Our image branch resamples without the sRGB step (`MLXVLM/Models/Qwen3VL.swift:103`
→ `:68`) while the video path applies `.toSRGB()` (`:42-44`) — the exact asymmetry
upstream fixed. Dark-content contrast reaches the ViT ~12x crushed on **both** served
VL towers (Qwen3.5/3.6-VL hold `Qwen3VLVision.VisionModel`). One-line fix; the helper
exists in `MediaProcessing.swift:63`. **Effort S. Quality bug, not perf.**

### 4. GDN recurrence precision (`d5d8b29`)
Our `gatedDeltaUpdate` kernel (`Libraries/MLXLLM/Models/GatedDelta.swift:62-67`) is the
exact pre-image of upstream's patch: no Kahan compensation, no
`#pragma clang fp reassociate/contract(off)` on the state-accumulation loop. Error
feeds `delta` → state and compounds across T on both Qwen 35Bs (LLM + VLM share this
kernel). Transplants nearly verbatim (variable names match); negligible cost in a
bandwidth-bound kernel. Numerics change uniformly across target/drafter/MTP-verify, so
**regenerate any golden logit-digest fixtures**. **Effort S.**

### 5. Compiler-cache data race in mlx-swift (delta of `df9ae26`)
Our `97b3c92` lock-order fix covers the deadlock half (evalLock outermost,
recursive) — equivalent to upstream. But `CompiledFunction.deinit` still calls
`mlx_detail_compile_erase(id)` **with no lock** (`Source/MLX/Transforms+Compile.swift:34-36`),
racing `CompilerCache::find`'s insert/rehash. Memory-corruption class; fires on model
unload/reload and compiled-closure churn. Importable delta ≈ 5 lines (erase under
evalLock); skip upstream's repro executable and debug machinery. Pairs with core
`8e00a2d9` ("Make mx.compile cache erasing thread safe") in the core bump below.
**Effort S.**

---

## Tier 1 — B=1–5 performance

### 6. mlx core bump to v0.32.2 — the headline perf item
We are 33 commits **behind v0.32.0** plus the 279 to v0.32.2, and the range is dense
with kernels aimed exactly at our shape. Directly applicable (Qwen geometry verified
from the served checkpoint configs in the local HF cache, GPT-OSS from
`openai/gpt-oss-20b` config.json — Qwen 3.5/3.6 35B: 16 Q / 2 KV heads = **GQA-8**,
**head_dim 256**, E=256 K=8, affine 4-bit g64; GPT-OSS 20B: 64 Q / 8 KV = **GQA-8**,
head_dim 64, E=32 K=4):

- `fa0d4463` **read each K/V byte once in gqa-8 decode attention** — all three primary
  models decode as GQA-8
- `714a7efc` **fused full-attention path for head_dim 256 on NAX** — both Qwen 35Bs
- `548dd80e` `qmv_wide` small-batch quantized matvec + `e7838d5e` raised qmv batch
  limit on M5-class GPUs — the B=1–5 decode projection shape
- `#3888` `gemv_wide` for fp16/bf16 matmuls of a few rows
- `c7ff35d9` skip unnecessary simdgroup work in **quantised MoE matmuls on NAX**,
  `a082cb91` 32-row block in `qmm_t_nax` when one block covers all of M,
  `a076a632` pick BM from rows-per-expert in `gather_qmm_rhs_nax` — MoE expert GEMMs
  at tiny rows-per-expert, all three models
- `a1316145` `rms_single_row` register caching, `#3882` Metal WAR-tracking hash reuse,
  `#3843` NAX Q@K.T unroll, `#3875` SDPA block rounding
- correctness riders: `56e026d8` dequantize in fp32, `4947e3b6` qmm floor fix,
  `01d4e123` re-disable `qmm_n_nax` + fix group_size < 64 (we ship g64), `8e00a2d9`
  compile-cache thread safety

Our patch set to rebase is small (7 commits, 13 files: `metal/quantized.{h,metal,cpp}`
E=256 expert-tile route, allocator buffer-count bounds, `gpu::eval` UAF fix,
`gemma4_expert_qmm.h`, device diagnostics). Conflict risk concentrates in
`metal/quantized.*`, where upstream's NAX qmm work overlaps our tile route —
**re-bench whether the E=256 route still beats upstream's improved `gather_qmm` after
the bump; it may be partially superseded.** The mlx-c pin (`60df937`, 2026-06-26) may
need a matching bump for new C surface; regenerate Cmlx JIT sources (upstream mlx-swift
`da31870` auto-derives the jit-source lists in `update-mlx.sh` — worth taking to make
this and future bumps cheaper). Post-v0.32.2 main (27 commits) has nothing
decode-critical; v0.32.2 is the right target. **Effort M (mostly rebase + re-bench).
Highest expected aggregate decode win of anything in this report.**

### 7. Multi-turn recurrent-state persistence for the Qwen hybrids (concept from `4b0b416`) — largest TTFT win
**Premise correction discovered during verification: our fork does *no* multi-turn
prefix reuse at all for the Qwen hybrids.** `CBv2ModelCapabilities.initialRecurrentTarget`
sets `supportsPrefixReuse: false` (`ContinuousBatchingV2/RecurrentStateV2.swift:42`),
Qwen35's `cbv2Capabilities` never re-enables it, and the provider slot factory refuses
to build the SSD prefix cache for recurrent targets
(`provider-swift/.../EngineV2SlotFactory.swift:436`). Every multi-turn
qwen3.5/qwen3.6 request cold-prefills its entire history. (Our `frozenFullReplay`
covers sliding-window hybrids — Gemma4/GPT-OSS; `PrefixReplayTape` is MTP-window
replay, not cross-request.)

Upstream's concept — persist per-layer recurrent state (+ the M-RoPE position anchor)
alongside KV, restore on exact-boundary match, fail closed — is the *enabler*, and maps
naturally onto CBv2: donate the committed `CBv2RecurrentLayerState` rows
(~61 MiB/request for the 35Bs: 30 GDN layers × 2 MiB fp32 SSM + conv tail) into
`SSDPrefixCache` at end-of-request; adopt only when the matched boundary equals the
snapshot boundary exactly (recurrent state cannot be truncated); prefill the suffix
only. O(1) bit-exact restore fits the existing `PrefixCachePolicy.adoptionIsExact`
gate. Upstream's code itself doesn't transplant (ChatSession world). For the VL
variant, persist the `CBv2PositionState` anchor with the snapshot (this is the part of
upstream `65be34c`/`4b0b416` that becomes a required co-import; the M-RoPE drift bug
itself is structurally absent from CBv2). **Effort L. Multi-turn TTFT goes from
O(full history) to O(new turn) on both Qwen 35Bs.**

### 8. Vision tower: per-image fused SDPA (`f7cacbc`) + image token budget (`93d46d8`)
Our vision attention is byte-identical to upstream's pre-image: dense `[1, L, L]`
`-1e9` joint mask + SDPA that falls off the fused kernel at head-dim 72
(`MLXVLM/Models/Qwen3VL.swift:605-620`); both served VL models use this tower.
Upstream measured 28.7→12.5 GB and 59.8→36.3 s prefill on one large image. Core
`3a621991` ("Support head dimension 72 in Metal full attention", in the v0.32.2 bump)
compounds with this. Also: our images ride the artifact's advertised `maxPixels`
(≈16 MP per our own comment at `Qwen3VL.swift:25-27`) while video is clamped to 512²;
upstream's 1,280-vision-token default + honoring `processing?.maxPixels` (which our
code currently ignores) aligns the image path with our own video-path philosophy.
**Effort S each. Bounds worst-case vision prefill memory/latency at B=1–5.**

### 9. Interleaved M-RoPE optimization (`f1bfca4`)
All three of our sites still build the per-frequency slice loop + `stacked` per
attention layer per forward (`MLXVLM/Models/Qwen3VL.swift:984-1004`,
`MLXVLM/Models/Qwen35.swift:396-414`, `MLXLLM/Models/Qwen35.swift:1266-1300`).
Upstream's precomputed `mropeIndices` + one `takeAlong` is numerics-identical (their
parity tests assert it). Exposure: for the 35B hybrids, text-only requests bypass
M-RoPE (device `positionOffsets`), so the win is media-request prefill/decode; for
qwen3-vl-30b-a3b it's every decode step (~48 layers × 64 slices ≈ 3,000 tiny lazy ops
per token on its serving path). Direct port at the two MLXVLM sites; small
re-derivation for our MLXLLM `Qwen35MRoPE`. **Effort S.**

### 10. Generalized fused MoE router top-k → apply to GPT-OSS and Qwen3-VL-30B (`#567`/`#568` kernel)
For Qwen 3.5/3.6 ours is the superset (`qwen35A3BRowOwnedRouterKernel`, rows 1–16 —
matches B=1–5; upstream gates to one row). But upstream's `MoERouterTopK.swift` is the
generality superset (any E≤1024/K/dtype, bit-identical-to-argPartition by
construction), and *neither* side currently covers our non-Qwen models. The import is
the kernel file + our own adoption: **GPT-OSS** (`GPTOSS.swift:73` argPartition chain,
E=32/K=4; widen the row gate for CBv2 — saves 2 of 3 serial dispatches per MoE layer
× 24 layers, low-single-digit decode %) and **Qwen3-VL-30B** (`Qwen3VL.swift:1188`,
E=128/K=8, drop-in on its single-sequence seam). Gemma4's tail
(softmax-over-selected-K + `perExpertScale`) is outside the kernel's contract — a
variant, only if wanted. **Effort S per adoption.**

### 11. Fold the GDN decode conv into our existing compiled micro-closures (concept from `0321f28`)
Separable from the compiled-decode question: at S==1 the GDN depthwise conv is 4
multiply-adds, and our eager decode still runs `silu(conv1d(concat(...)))`
(`MLXLLM/Models/Qwen35.swift:543/546`). Our decode already ships
`compile(shapeless: true)` elementwise closures behind `MLX_COMPILED_DECODE`
(`SwitchLayers.swift:22`); folding `silu(decodeConv(...))` into one imports the trick
without reversing the bc69878 decision. Upstream's +1.77% was measured inside
whole-step segments — **A/B the micro-closure form before keeping.** **Effort S.**

### 12. Byte-balanced parallel weight loading (`e36d8ce`)
Ours parallelizes per *file*; large 4-bit 20–35B checkpoints ship in ~4 shards on
14+ cores → 4-way parallelism with a straggler shard. Upstream orders tensors by file
offset and splits into contiguous byte-balanced groups (≥256 MiB, up to 16-way) —
sub-file parallelism. Their 1.8x is vs serial; our expected gain is the
shard-vs-core imbalance. Keep our F_RDADVISE prefetch (we measured −13% warm on
GPT-OSS vs upstream's "often negative" — decide empirically on our hardware).
Load-time only — model-swap latency, not serving. **Effort S–M (merge into our
Load.swift around the quantization-policy staging, not a paste).**

### 13. Balanced prefill chunk sizing (two-line formula from `4c7874b`)
Our scheduler grants `min(remaining, chunk=512, budget)`, so a trailing small
remainder chunk pays a full engine step (upstream measured ~3x per-token cost for the
leftover; ~9% full-prefill at 32K). The import is only
`chunkLength = ceil(count / ceil(count/step))` applied in `SchedulerV2`'s chunk
proposal — none of upstream's `PrefillParameters` machinery maps. Watch: packed
cohorts require equal lengths across requests, arbitrary chunk lengths churn
shape-keyed kernel/JIT caches, multimodal block snapping constrains boundaries.
**Effort S–M; long-prompt TTFT only.**

### 14. Single-dispatch short-context decode attention (concept from TurboFlash `5c1d95a`)
TurboFlash itself is upstream's quantized-KV (TurboQuant) attention — N/A, we removed
KV quantization from CBv2 deliberately. But the dispatch idea transfers: our paged
flash-decode kernel always launches part + merge even when `maxParts == 1`
(`ContinuousBatchingV2/Paged/PagedAttentionKernel.swift`). A fused single-dispatch
pass-A variant for short contexts (sinks must fold into pass A; merge owns them today)
skips a kernel launch + partial buffers per layer per step on short-context traffic.
**Effort M; plausible small B=1–5 decode win, unmeasured.**

---

## Tier 2 — cheap defensive imports

| Item | What | Effort |
|---|---|---|
| Tied-embedding sanitize (`44a136c`/`3de04ab`) | Our removal of `lm_head.weight` leaves `lm_head.scales/.biases` → strict-update load refusal for tied **quantized** checkpoints. Verified not biting today (all served configs untied), but present at `MLXLLM/Qwen35.swift:1841,2123`, `MLXVLM/Qwen35.swift:1567` (worse: leftovers renamed to `language_model.lm_head.*`), `Qwen3MoE.swift:256`. Import the prefix filter. | S |
| Safetensors index convention (`d661402` final form) | Our loader globs every `*.safetensors` recursively and ignores the index (`Load.swift:136-140`); pollution fails loudly, but mixed-artifact checkpoints exist in our world (MTP reads the index separately, `Qwen35MTP.swift:497-515`). Adopt: top-level only; index → `model*` → `weight*` → all. | M |
| `StreamOrDevice.stream(_:)` (`d737cd0`) | Ours discards its argument (`Source/MLX/Stream.swift:54-56`). Latent (no in-tree caller), but our multi-stream work makes a future call site plausible. | S (1 line) |
| GDN `Dk % 32` guard (`5f4f570`) | Cannot trigger on served configs (`linear_key_head_dim: 128`), but our dispatch is unguarded (`GatedDelta.swift:33,313`). | S (1 line) |
| VLM sanitize hardening (re: `2f95038`) | We're already safe for production artifacts via the `format == "mlx"` metadata gate (`MLXVLM/Qwen35.swift:1549-1562`); the tensor-only path can still double-shift. If hardening, **use our own `hasUnsanitizedConv1d` gate** (`MLXLLM/Qwen35.swift:1802-1810`) — our comment documents that upstream's exact gate double-shifts. Do not port verbatim. | S |
| FinalizerCaptureState leak (`9a09a03`) | Real in our fork (`MLXArray+Init.swift:34` `takeUnretainedValue`) but zero consumers anywhere in production. Fix if the file is ever touched. | S |

---

## Verified as already-ours / not applicable

- **GPT-OSS Harmony tool parsing** — we've had `HarmonyToolCallParser` since May
  (both channel orders, `<|constrain|>`), wired via `ServerToolParser` → production.
- **GDN input fusion + direct expert reduction** (`#572`/`#573`) — ours landed first;
  upstream's kernel is byte-identical to ours. Ours adds cache-invalidation and
  adapter safety upstream lacks.
- **Compiled decode segments** (`#467`/`#569`) — reverses our bc69878 deletion, whose
  premise still holds (paged gather returns fresh copies; our A/B showed eager winning
  on gpt-oss). Do not import without re-litigating.
- **TurboQuant / variance-normalized / kvScheme KV compression** (`#232`/`#329`/`#230`)
  — reverses our deliberate removal of KV quantization from CBv2 (`f5d0616`).
- **`f37305a` recurrent cache handling** — all three legs covered or dead (no
  left-padding path in CBv2; conv-tail aliasing handled at commit; plain `qwen3` not
  served).
- **Windowed prefill / M-RoPE drift fix** (`65be34c`) — bug structurally absent
  (no warm cross-turn cache; per-request `CBv2PositionState` anchor). Becomes relevant
  only as the position-anchor co-import inside item 7.
- **Global-scale / fp8 utilities** (`09051ed`/`7a8d05a`) — our MLX 0.32 base already
  has op-level global scale and mxfp4/mxfp8/nvfp4 modes; missing bits are
  NVFP4-layer-level only, and nothing served needs them.
- Prompt-cache text-only gating (`72d9fdb`) and reuse telemetry (`99c0e5f`) —
  equivalent intent already in `EngineV2Bridge.swift:638` / ChatSession-only.
- New upstream models (Mamba2, Mixtral, DeepSeek-V2, Helium, Muse Glimmer, Hunyuan,
  Nanbeige), MLXFoundationModels, LoRA/training, CI/docs/format churn.

## Open flags

1. **qwen3-vl-30b-a3b serving seam**: inferred to run through the legacy
   single-sequence path (CBv2 family switch throws for it,
   `EngineV2Factory+Production.swift:648`) — not traced end-to-end. Affects the size
   (not direction) of items 9–10.
2. Item 6: whether our E=256 expert-tile route survives the v0.32.2 rebase as a win
   needs a bench, not an assumption.
3. Item 1's real-world trigger frequency and item 11's eager-form gain are unmeasured.
4. F_RDADVISE benefit conflict (our −13% vs upstream "often negative") — settle
   empirically during item 12.

## Suggested sequencing

1. Tier 0 items 1–5 (all S; four are live bugs, one is memory-corruption class).
2. Item 6 (core v0.32.2 rebase + bench) — biggest aggregate decode win.
3. Item 7 (recurrent-state prefix persistence) — biggest TTFT win, L effort, own
   worktree + design pass.
4. Items 8–10 as a VL/MoE batch; 11–14 opportunistically with A/B gates.
