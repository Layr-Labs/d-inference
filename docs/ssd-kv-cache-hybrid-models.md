# SSD KV Cache for Hybrid (Sliding-Window) Models — Design Note

**Goal:** make the encrypted SSD KV cache actually benefit **Gemma-4** and
**GPT-OSS-20B** (and pure-attention models), correctly, without changing
behavior for any model the cache currently serves or for models it can't
serve. Carefully verified, with a numeric-equivalence gate.

Status: design — not yet implemented. Supersedes the "engine block tier
only" limitation documented in [ssd-kv-cache.md](ssd-kv-cache.md) §2.

---

## 1. Why the engine block tier can't serve these models

The wired engine tier (`MLXLMCommon.PrefixCache`) stores prompt KV in
fixed 256-token blocks, content-addressed by a chain hash, and is gated to
**all-`KVCacheSimple`** layers (`Scheduler.swift:711` `allSatisfy { $0 is
KVCacheSimple }`). Gemma-4 and GPT-OSS produce **mixed** caches:

| Model | `newCache()` (verified in source) |
|---|---|
| Gemma-4 (`Gemma4Text.swift:1083`) | `StandardKVCache`(=`KVCacheSimple`) on `full_attention` layers + `RotatingKVCache(maxSize: slidingWindow=512)` on `sliding_attention` (4 of every 5 layers) |
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
This is what the already-built (but unwired) **`PrefixCacheManager`** tier
does, and its `KVCacheSerializer` already round-trips both `KVCacheSimple`
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

## 3. The window ≥ checkpoint constraint (critical for GPT-OSS)

A sliding layer physically retains only `maxSize` tokens. Capturing at
checkpoint L is only *useful* (covers the whole prefix) when **L ≤
maxSize** for every sliding layer — otherwise the snapshot has already
forgotten tokens `[0, L-maxSize)` and a restore wouldn't reproduce
full-attention layers' view of those tokens. Concretely:

| Model | min sliding window | usable checkpoints |
|---|---|---|
| Gemma-4 | 512 | 256, 512 |
| GPT-OSS | **128** | **only < 128 → none of the default boundaries (smallest 256)** |

So with the default boundaries GPT-OSS would get **zero** usable
checkpoints. Resolution: **derive the checkpoint boundaries from the
model's sliding window** — only emit boundaries `≤ minSlidingWindow`. For
GPT-OSS (window 128) add a 64/96-class boundary; for Gemma-4 keep
256/512. `PrefixCacheManager` already takes `boundaries:` as an init
parameter (`PrefixCacheManager.swift:146`) and `PrefixDigest` honors it —
no engine change needed.

> Honest tradeoff: a 128-token window means at most ~128 tokens of prefill
> saved per hit for GPT-OSS's sliding layers — modest, but its full layers
> still benefit, and TTFT on a shared system prompt still drops. We will
> **measure** the actual saving and not over-claim.

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
