# SSD KV Cache for Hybrid (Sliding-Window) Models — Design Note

**Goal:** make the encrypted SSD KV cache actually benefit **Gemma-4** and
**GPT-OSS-20B** (and pure-attention models), correctly, without changing
behavior for any model the cache currently serves or for models it can't
serve. Carefully verified, with a numeric-equivalence gate.

Status: **IMPLEMENTED** (Steps 1–5 complete; see §7.4) behind the default-off
`DARKBLOOM_PREFIX_CACHE` flag. Supersedes the "engine block tier only"
limitation documented in [ssd-kv-cache.md](ssd-kv-cache.md) §2. Remaining
items are process gates, not code: the submodule PR merge, the TB-007
sign-off, and a run of the live logit-equivalence gate on real weights.

---

## 1. Why the engine block tier can't serve these models

The wired engine tier (`MLXLMCommon.PrefixCache`) stores prompt KV in
fixed 256-token blocks, content-addressed by a chain hash, and is gated to
**all-`KVCacheSimple`** layers (`Scheduler.swift:711` `allSatisfy { $0 is
KVCacheSimple }`). Gemma-4 and GPT-OSS produce **mixed** caches:

| Model | `newCache()` (verified in source) |
|---|---|
| Gemma-4 (`Gemma4Text.swift:1083`) | `StandardKVCache`(=`KVCacheSimple`) on `full_attention` layers + `RotatingKVCache(maxSize: slidingWindow=1024)` on `sliding_attention` (4 of every 5 layers) |
| GPT-OSS (`GPTOSS.swift:522`) | `KVCacheSimple` on full layers + `RotatingKVCache(maxSize: slidingWindow=128)` on sliding layers |
| Qwen3.5 / Qwen3-Next | `KVCacheSimple` + `MambaCache` (recurrent) |

Block decomposition by **token position** is **unsound** for
`RotatingKVCache` (verified by reading the class):

- It deliberately **discards** old KV: after generation, a sliding layer
  physically holds only the last `maxSize` (+ `keep`) tokens. The prompt
  prefix (tokens 0..256) is **gone** by request completion.
- Physical index ≠ token position: `updateInPlace` **rotates** writes
  (`idx` wraps to `keep` at `maxCacheSize`), and `temporalOrder()` must
  un-rotate before the buffer means anything in time order.
- Rotation bookkeeping (`keep`, `maxCacheSize`, `step`, `offset`, `idx`)
  lives in `metaState`; a token-position slice ignores it.

So `storePrefix`'s `state[0][..., start..<start+bs, ...]` slice would grab
the wrong tokens (or absent tokens). The `allSatisfy` gate is a
**correctness guard**, not laziness — we must not relax it.

Mamba layers (Qwen) carry recurrent state that is not a per-token prefix at
all → not block-cacheable and not snapshot-restorable via the public API.
Qwen stays uncached. (Out of scope; explicitly preserved as-is.)

## 2. The correct architecture: exact-checkpoint whole-cache snapshot

Instead of per-layer token-position blocks, snapshot **the entire
multi-layer cache** at an exact prefix length and restore it wholesale.
This is what the **`PrefixCacheManager`** tier does (wired into
`BatchScheduler` for hybrid models when the flag is on), and its
`KVCacheSerializer` already round-trips both `KVCacheSimple`
and `RotatingKVCache` (state + `metaState`), with restore correctness
partially covered by `RotatingKVCacheRestoreTests`.

```
CAPTURE  (end of prefill of an L-token prompt, BEFORE any decode step):
  if L hits an exact checkpoint boundary (256, 512, 1024, …):
    snapshot ALL layers (full + rotating) -> serialize -> AES-GCM -> SSD
    index[(weightBinding, digest(tokens[0..L]))] = file

HIT  (new request whose prompt shares a checkpoint-length prefix):
  restore ALL layers from the file (state + metaState, exact)
  seed the engine with the restored cache; prefill ONLY tokens[L..]
```

Why this is sound where blocks aren't:

- **Capture is at end-of-prefill, before decode** (`advancePendingPrefill`,
  `maxRemaining == 0` → `ppBatch.generate(...)`). At that instant a
  sliding layer's window still covers the *most recent* `maxSize` prompt
  tokens — exactly the tokens that matter for continuing from position L.
  (We do NOT capture at request completion, where decode has slid the
  window past the prompt.)
- **Whole-cache, exact-length**: we never slice a rotating buffer by
  position. We serialize its `state` + `metaState` verbatim and restore
  them verbatim — the cache resumes in precisely the configuration the
  model itself produced after prefilling L tokens. Equivalent to "prefill
  L tokens, then continue."

## 3. The window does NOT cap reusable prefix length (it bounds per-layer retention)

> **Correction (2026-06).** An earlier draft claimed a checkpoint at length
> L is only sound when **L ≤ window** for every sliding layer — i.e. that the
> window is a hard ceiling on the reusable prefix. **That is wrong**, and the
> current implementation's conservatism is a *design choice*, not a
> correctness requirement. The accurate picture:
>
> A correct hybrid prefix only needs, **per layer**:
> - **full-attention layers** (`KVCacheSimple`): the KV for *all* L tokens —
>   they retain everything, so they are never the limiting factor;
> - **sliding layers** (`RotatingKVCache`): only the **last `window`** KV
>   entries — which is *exactly* what the layer physically holds and *all it
>   needs* for correct future decoding from position L.
>
> So a snapshot at **any** L faithfully represents the prefix: full layers
> carry all L tokens, sliding layers carry their (valid) window. The window
> bounds *how much KV a sliding layer must retain*, **not** the maximum
> prefix that can be cached and reused. This is the same per-layer
> intersection SGLang HiCache and the SSD-KV literature use.

**Our serializer already does the per-layer-correct thing.**
`KVCacheSerializer` snapshots each layer's `.state`: a full layer returns all
L tokens; a `RotatingKVCache` returns its wrapped ring buffer (≈ last
`window`) plus the `offset`/`idx` in `metaState`. `BatchRotatingKVCache.from
SingleRow` restores that wrapped state with the absolute offset intact.

**Empirically verified past the window.**
`HybridCheckpointLiveTests.gemma4RestoreMatchesColdPastWindow` restores at
**L = 2048 and 4096** — both > Gemma-4's **1024** window, so the sliding
layers' ring buffer has wrapped — and asserts the continued greedy output is
**bit-identical to a cold full run**. It passes. The wrapped-ring-buffer
restore is exact, so reuse past the window is correct in this pipeline today.

### What the window *does* still control

`PrefixDigest.checkpoints(forSlidingWindow:maxContext:pastWindowProven:)`
**extends past the window** for PROVEN families, via a coarse tail ladder
`[2048, 4096, 8192, 16384, 32768]` up to a 32k ceiling (or the model's
`maxContextLength` if smaller). **Both Gemma-4 and GPT-OSS are now proven**
(see `PrefixCachePastWindow.provenSubstrings = ["gemma", "gpt-oss", "gptoss"]`),
so both get the extended ladder. A family that is NOT proven keeps the
within-window-only ladder (safe default):

| Model | min sliding window | PROVEN? | checkpoint boundaries (as-built) |
|---|---|---|---|
| Gemma-4 | **1024** | YES (`gemma4RestoreMatchesColdPastWindow`, L=2048/4096 > 1024) | 256, 512, 1024, **2048, 4096, 8192, 16384, 32768** (up to maxContext) |
| GPT-OSS | **128** | YES (`gptOssRestoreMatchesColdPastWindow`, L=256/512 > 128) | 64, 128, **2048, 4096, 8192, 16384, 32768** (up to maxContext) |

**How it's wired (`PrefixDigest.swift`, `PrefixCachePastWindow.swift`):**
`PrefixCachePastWindow.isProven(arch:)` returns `true` for any architecture
string containing `"gemma"`, `"gpt-oss"`, or `"gptoss"` (case-insensitive).
When `pastWindowProven == true` AND `maxContext > inWindow.last`, the ladder is
extended with the tail `[2048, 4096, 8192, 16384, 32768]`, filtered to
`(inWindow.last, maxContext]`. A not-yet-proven family keeps the within-window
ladder unchanged (safe default).

The cost of a long checkpoint is storage/IO (full-layer KV for the whole
prefix on disk) and restore latency (decrypt + rebuild grows with prefix
size), not correctness — proven by `gemma4RestoreMatchesColdPastWindow`
(L=2048/4096 > 1024 window) and `gptOssRestoreMatchesColdPastWindow`
(L=256/512 > 128 window). Both families use the same `RotatingKVCache`
mechanism (full-attention layers retain all tokens; sliding layers keep their
wrapped window), so the wrapped-ring-buffer restore is identical and verified
for both. The 32k ceiling is a human decision balancing reuse vs write
amplification.

> GPT-OSS past-window lift (now enabled): its 128-token sliding window means a
> within-window checkpoint would save at most ~128 tokens of prefill on its
> sliding layers. With past-window restore proven, long shared prefixes are now
> reused on its full-attention layers too (the coarse tail ladder), so a long
> shared system prompt is restored rather than re-prefilled. Its TTFT benefit on
> a shared prefix was already measured at 2.60× at a 96-token prefix; the lift
> extends reuse to longer prefixes.

## 4. Isolation — how we guarantee other models are unaffected

1. **The engine block path is not touched.** No change to
   `PrefixCache.swift` or the `allSatisfy` gate. Pure-attention models keep
   using the engine block tier exactly as today.
2. **The checkpoint tier is opt-in and capability-gated.** It activates
   only when `DARKBLOOM_PREFIX_CACHE` is on AND the model's cache types are
   all in {`KVCacheSimple`, `RotatingKVCache`} (a model with any
   `MambaCache`/other → tier returns nil, exactly today's no-op). Qwen is
   thus explicitly excluded and unchanged.
3. **Two tiers never run for the same model.** A model is served by EITHER
   the engine block tier (all-`KVCacheSimple`) OR the checkpoint tier
   (mixed simple+rotating) — never both. Selection is a single
   capability check at engine build. Pure-attention models stay on the
   engine tier (lower overhead, finer-grained block reuse).
4. **Fail-closed everywhere.** Any capture/restore/serialize/decrypt error
   → drop and cold-prefill (the load-path ladder from ssd-kv-cache.md §8
   already enforces this; reused verbatim).

## 5. Verification gate (must pass before merge)

The non-negotiable correctness test, on **real** Gemma-4 and GPT-OSS
weights (env-gated live test, like `LivePrefixCacheModelTests`):

```
logits_cold  = prefill(prompt[0..N]) then forward(next token)   // no cache
logits_warm  = restore(checkpoint L) ; prefill(prompt[L..N]) ; forward(next)
assert logits_warm ≈ logits_cold      // bit-exact for greedy; tight atol/rtol
assert generated_tokens_warm == generated_tokens_cold  (temp 0, K tokens)
```

Plus, for isolation:

- A pure-attention model: cache ON vs OFF produce identical tokens, and it
  still uses the **engine** tier (assert the checkpoint tier was not
  constructed for it).
- A Qwen (Mamba) model: checkpoint tier returns nil; behavior identical to
  cache-off; no files written.
- Unit: capability gate classifies each model's `newCache()` output
  correctly (simple-only → engine; simple+rotating → checkpoint;
  any-mamba → none).
- Round-trip: a Gemma-style mixed `[KVCacheSimple, RotatingKVCache, …]`
  serializes → encrypts → decrypts → deserializes → restores, and a
  subsequent multi-token prefill matches a reference fresh cache
  (extends `RotatingKVCacheRestoreTests`).

No claim of "works for Gemma-4/GPT-OSS" is made until the live
logit-equivalence test passes on both.

## 6. Implementation steps (each behind a quality gate)

> **STATUS: all steps below are DONE and wired** (see the per-step DONE markers
> in §8). This section is the original roadmap, kept for design context; it is
> not a list of pending work. In particular step 5 (`PrefixCacheManager` →
> `BatchScheduler`) is complete.

1. **Capability classifier** (pure, unit-tested): `[any KVCache] → {engine,
   checkpoint, none}`. No behavior change yet.
2. **Boundary derivation** from sliding window (pure, unit-tested).
3. **Capture hook** at end-of-prefill in the scheduler/engine: expose the
   prompt cache at the prefill→decode transition for checkpoint capture.
   Snapshot must **deep-copy** (the live cache keeps mutating during
   decode) — verify via `copy()` / serialize-immediately.
4. **Restore + seed** path: on a checkpoint hit, build `existingCache` from
   the restored layers and prefill only the suffix (reuse the warm-prefill
   path).
5. **Wire `PrefixCacheManager`** into `BatchScheduler` for checkpoint-tier
   models only; reuse the KEK/dir/budget logic already built.
6. **Live verification** (§5) on both models + isolation tests.

Steps 1–2 and the round-trip test land first (zero runtime effect), so the
risky wiring (3–5) is built on a verified base.

---

## 7. Verified integration map (from a source audit of the submodule)

A close read of `libs/mlx-swift-lm/.../ContinuousBatching/` (Scheduler,
PromptProcessingBatch, GenerationBatch, BatchKVCache, Request, EngineCore)
confirmed the approach and pinned three submodule changes that the
"PrefixCacheManager is already built" framing understates. **The restore
path does not exist yet** — it must be built, carefully.

### 7.1 Confirmed facts (file:line)

- **Capture point** = `Scheduler.advancePendingPrefill`, immediately before
  each `pp.ppBatch.generate(...)` (Scheduler.swift:294 and :313, the
  `maxRemaining == 0` transition). At that instant
  `pp.ppBatch.promptCache: [any BatchedCache]` holds the full prefill KV.
- **Capture must precede `generate()`**: `GenerationBatch.init` runs
  `_ = step()` unconditionally (GenerationBatch.swift:109), i.e. one decode
  step *before* `generate()` returns — which slides every rotating window by
  one token. Capturing after would silently drop the L-th token's KV.
- **Single-row extraction is sound and owns its storage**:
  `BatchedCache.extractBatched(_ idx:) -> any KVCache` is public
  (BatchKVCache.swift:25); `BatchKVCache.extract` → `KVCacheSimple`
  (line 343, `eval`'d slice), `BatchRotatingKVCache.extract` →
  `RotatingKVCache` with full `metaState` (line 726). Proven row-isolated by
  `batchRotatingExtractIsolatesRow`.
- **Restore is blocked on two KVCacheSimple-only assumptions**:
  `doExternalPrefill` `precondition`s all-`KVCacheSimple` (Scheduler.swift:625,
  :649) and the warm merge uses `BatchKVCache.merge([KVCacheSimple])`
  (Scheduler.swift:541, BatchKVCache.swift:358). A mixed restored cache
  crashes both. **A separate restore path is required** — do NOT relax the
  existing guard (keep the engine tier's isolation intact).
- **The restore scaffold already exists**: `cacheFactories`
  (Scheduler.swift:597-615) is a per-layer type switch
  (Mamba/Arrays/Rotating/Simple → matching `BatchedCache`). The inverse of
  `extract` (seed a B=1 batched cache from a single-row cache) mirrors
  `BatchKVCache.merge([c])`; the rotating analogue must be added.
- **`GenerationBatch.init` already accepts `[any BatchedCache]`** and calls
  the model via `promptCache.map { $0 as any KVCache }` (GenerationBatch.swift:335)
  — mixed-tolerant. The suffix-prefill forward (`model(input, cache:)`,
  Scheduler.swift:644) is also type-agnostic.
- **Async/sync boundary**: `PrefixCacheManager` is an `actor`; the step loop
  is a synchronous `engineQueue` (EngineCore.swift). Capture stores via
  `Task { await manager.store(...) }`; restore `lookup` runs in the already
  -async `BatchScheduler.submit` before `addRequest`. No await on the queue.
- **Sliding window size** is NOT in `ModelArchitecture` (only the pattern +
  layer_types). Read it from the live caches:
  `PrefixCacheStrategy.minSlidingWindow(model.newCache())` =
  `min RotatingKVCache.maxSize`. (Implemented in step 1.)

### 7.2 Decisions taken (architect-recommended defaults)

- **batchSize == 1 capture & restore first.** `extract` slices off
  `leftPadding[idx]`, but extract-then-remerge at a *different* batch
  position with non-zero left padding is untested → restrict to B=1 (left
  padding always 0). Covers the dominant shared-system-prompt TTFT win;
  multi-row is a separately-gated follow-up.
- **Plumb via `Request.restoredCheckpoint: ([any KVCache], Int)?`** — least
  invasive; `Request` already carries `promptCache` and flows through
  `addRequest` unmodified.
- **Debounce `flushToSSD()`** — `store()` updates RAM synchronously (cheap);
  disk writes happen opportunistically, off the hot path.
- **Reuse `DARKBLOOM_PREFIX_CACHE`** — same TB-007 sign-off, KEK, dir, budget;
  the classifier guarantees one tier per model.

### 7.3 Residual risks → the test that catches each

| Risk | Catching test |
|---|---|
| Capture one token late (window already slid) | §5 live logit-equivalence; hook test capturing before `generate()` vs a never-decoded reference |
| Rotating restored without `metaState` (scrambled order) | `RotatingKVCacheRestoreTests.omittingMetaStateOnRestoreCorruptsOrder` (already proves corruption); assert restored `metaState` == captured |
| Left-padded extract / re-merge misalign mask | new ragged-batch test (`leftPadding=[2,0]`, extract row 1, restore, resume vs single-stream ref); mitigated by B==1 constraint |
| Boundary > window → discarded tokens | `checkpoints(forSlidingWindow:)` unit test + GPT-OSS live test; `minSlidingWindow` read from real `RotatingKVCache.maxSize` |
| Wrong-model / stale-weight served | `PrefixCacheManager` MB-1 guard + `validateLayout` (existing) |
| Capture/restore data race vs step loop | extract materializes owned storage + actor-serialized `store`; TSan run of concurrent-submit test |

### 7.4 Status

- **Step 1 (DONE, zero-runtime):** `PrefixCacheStrategy.classify` +
  `.minSlidingWindow`, `PrefixDigest.checkpoints(forSlidingWindow:)`, and the
  mixed-layer encrypted round-trip proof. 16 unit tests.
- **Restore primitive (DONE):** `BatchRotatingKVCache.fromSingleRow` —
  inverse of `extract`; resume matches an independent single-stream
  reference (wrapped + pre-wrap). Submodule `f00c1a7`.
- **Step 2 — capture hook (DONE, default-off/isolated):**
  `CheckpointPrefillPlanner` (boundary-aligned chunking) +
  `Scheduler.onCheckpointCapture`/`checkpointBoundaries`. Captures per-layer
  single-row caches at exact boundaries, before `generate()` slides the
  window; B==1 only. Adversarially reviewed for isolation. Submodule
  `62bf9f2`. Nothing restores yet ⇒ no model output can change.
- **Step 3 — restore-admit (DONE):** `admitRestoredCheckpoint` rebuilds a
  B==1 batched cache (`merge([simple])` + `fromSingleRow(rotating)`) from a
  `Request.restoredCheckpoint` and decodes only the suffix; per-position
  layer-type validation + cold fallback. Numeric-equivalence gated
  (restore==cold, with a negative control). Submodule `8c2e2ce`.
- **Step 4 — BatchScheduler wiring (DONE):** `makeBatchedEngine` classifies
  the model and builds the matching tier; `.checkpoint` models get a
  `PrefixCacheManager` + capture closure (store→flushToSSD via Task) +
  `submit`-time `lookup`. Shared KEK/dir/binding; RAM tier respects
  `MAX_GB`; manager cleared on teardown/epoch-race. Reviewed for isolation.
  Provider `22fc60c2`.
- **Step 5 — live verification (DONE, env-gated):**
  `HybridCheckpointLiveTests` proves restore@L greedy == cold greedy on REAL
  Gemma-4 / GPT-OSS weights (real bf16 KV, head dims, windows, layer counts)
  through the actual serialize→deserialize→rebuild pipeline. Gated on
  `DARKBLOOM_LIVE_MLX_TESTS` + `_GEMMA`/`_GPTOSS`; skips cleanly in CI.

**Feature complete**, gated by `DARKBLOOM_PREFIX_CACHE` (default ON; opt out
with `=0`). Pending: the submodule PR merge and a run of the live gate on real
weights. Default-on reflects the operator's accepted TB-007 tradeoff — untrusted
multi-tenant deployments must opt out.
