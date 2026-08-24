# 060 — Exact Qwen3.5/3.6 CBv2 full-prompt boundary reuse

Date: 2026-08-24  
Status: implemented behind explicit cache injection; default off

## Decision

The first exact recurrent-cache version is deliberately narrower than E23's
eventual arbitrary-prefix/shared-cold-cohort target:

- exact **full-prompt** text hits only;
- contiguous, storage-owning full-attention rows only;
- scalar text positions only (no vision/MRoPE state);
- RAM residency with a hard byte ceiling and deterministic LRU;
- enabled only when the caller supplies `ExactPrefixCacheV2` **and** sets
  `CBv2SchedulerConfig.enablePrefixCache`;
- no model weights, routing weights, quantization metadata, or tokenizer bytes
  change.

This is enough to prove the state contract without pretending that K/V alone is
valid for Qwen. Partial-prefix lookup, SSD serialization, and simultaneous cold
leader/follower forking remain later phases.

## 1. Work backward from the required boundary

The shipping Qwen3.5/3.6 text tower has:

```text
G G G A | G G G A | ... | G G G A
0 1 2 3                         36 37 38 39
```

An exact boundary after prompt token `P - 1` is one atomic object:

1. **10 full-attention rows**
   - original model layers `3,7,11,15,19,23,27,31,35,39`;
   - K and V through exactly `P`;
   - absolute offset exactly `P`.
2. **30 request-owned GDN rows**
   - convolution tail at every non-attention model layer;
   - SSM matrix at every non-attention model layer;
   - the embedding output dtype for conv and **FP32** for SSM;
   - 61.40625 MiB for the concrete 40-layer checkpoint.
3. **Model position**
   - `modelPosition == tokenCount == P`.
4. **Frontier logits**
   - one normalized `[vocab]` vector after the final prompt token.

Frontier logits are load-bearing. Restoring state at `P` and recomputing token
`P - 1` would apply that token twice to GDN and K/V. Restoring at `P` but
discarding the logits would have no legal value to sample. The cache therefore
stores the logits and the first warm engine assignment samples them without a
model forward; ordinary decode resumes from the generated token afterward.

## 2. Why the old prefix cache is not widened

`CBv2PrefixCache` historically restores attention K/V and intentionally leaves
one token to recompute for logits. That is valid for its attention-only/replay
layouts, but not for Qwen's independent recurrent state.

The implementation adds a stronger additive protocol,
`CBv2ExactStatePrefixCache`. Qwen keeps:

```text
supportsPrefixReuse = false
supportsExactStatePrefixReuse = true
```

This makes accidental admission through a KV-only cache impossible. Engine
construction enables Qwen reuse only when the concrete cache implements the
stronger protocol.

## 3. Identity and validity

The RAM key is SHA-256 over a versioned binary encoding of:

```text
format domain
model identity
policy identity
authenticated scope (request cacheSalt, else cache scope)
token count
every UInt32 token ID in order
```

The production caller is responsible for composing verified weight, <!-- pragma: allowlist secret -->
model/tokenizer/prompt-contract identity into `modelIdentity`. `policyIdentity`
binds backend, dtype, and snapshot format. A lookup additionally validates:

- exact token count (no longest-prefix fallback in v1);
- exact recurrent state spec, including all model-layer indices/shapes/dtypes;
- exact compact attention layout and K/V geometry;
- every attention offset and `modelPosition` equal the prompt length.

Token-only keys are insufficient for multimodal prompts, so v1 refuses all
multimodal or explicit-position requests on both lookup and donation.

## 4. Immutable ownership and cancellation

Donation builds storage-owning copies with full slice updates, not arithmetic
`array + 0` copies. The detached roots ride the donor step's existing
`asyncEval`. The entry is indexed only after that step:

1. finishes evaluation;
2. receives its cancellation/discard verdict;
3. commits the donor's recurrent transaction.

A cancelled/discarded donor is never published.

Attention adoption allocates a fresh backend row and copies the immutable K/V
boundary into it. Recurrent adoption constructs a new
`CBv2RecurrentRequestState` and detaches every conv/SSM array again. Each
adopter therefore owns its wrappers and mutable future generations. Finishing,
cancelling, rolling back, or advancing one request cannot clear or mutate the
cache entry or another adopter.

MTP planning is suppressed only while a request consumes cached frontier
logits. Once that token is confirmed, the ordinary MTP lifecycle may resume
from the restored target state; no speculative generation is ever cached.

## 5. Accounting and eviction

`CBv2ExactPrefixSnapshot.byteCount` is the checked sum of:

```text
all detached K bytes
+ all detached V bytes
+ every detached conv tail
+ every detached FP32 SSM state
+ detached frontier logits
```

`ExactPrefixCacheV2` maintains resident bytes under one lock. Donation performs
a cheap exact-size gate before making copies, then evicts unpinned LRU entries
**before** publishing. If active adoption pins prevent enough eviction, the
new donation is dropped; resident bytes never cross `maxBytes`.

Stats report hits, misses, tokens saved, accepted/dropped donations, evictions,
entry count, and resident bytes. Lookup pins an entry through backend adoption;
all success, rejection, early-cancel, and shutdown paths balance that pin.

The cache budget is separate from live request admission in this library-level
version. A production constructor must carve `maxBytes` from its unified-memory <!-- pragma: allowlist secret -->
grant before opting in; silently adding this RAM on top of the serving grant is
not an acceptable rollout.

## 6. Engine lifecycle

Cold request:

```text
lookup miss
  -> ordinary chunked/packed prefill
  -> final prompt forward stages K/V + recurrent generation + frontier logits
  -> detached snapshot rides asyncEval
  -> recurrent commit
  -> atomic RAM donation
  -> sample/emit as before
```

Warm exact request:

```text
full-token-key hit + pin
  -> reserve normal per-request future capacity
  -> restore fresh attention rows and fresh recurrent request state
  -> scheduler cursor temporarily P-1 while physical state remains at P
  -> sample cached frontier logits (zero model forward)
  -> cursor reaches P; decode generated token through ordinary path
  -> unpin after adoption; normal finish/cancel cleanup
```

The temporary scheduler cursor is bookkeeping only. K/V offsets, GDN state,
and `modelPosition` never move backward.

## 7. Regression proof

The tiny hybrid fixture has one real full-attention cache and one recurrent
conv/FP32-SSM state. Its logits depend on both, so a K/V-only or
recurrent-only restore cannot pass.

The test matrix is:

| Arm | Required observation |
|---|---|
| B1 cold + repeat | one prefill row total; repeat reports full prompt saved; exact greedy tokens |
| warm B2 | one cold donor prefill total; both adopters exact; independent decode rows |
| warm B4 | one cold donor prefill total; all four adopters exact; independent decode rows |
| cancellation | cancel one adopter, then reuse the same entry; survivor remains exact |
| ownership | independently advance/release restored attention and recurrent rows |
| LRU | pinned entries survive; unpinned oldest evicts; hard budget never exceeded |
| identity | changed token, scope, model, policy, layout, or recurrent spec misses/fails cold |
| quantized embedding | packed `uint32` weights still declare the dequantized activation dtype |

These are repeated-prefix results. They do not alter or satisfy the locked cold,
prefix-cache-off throughput denominator in note 050.

### Real-model donation diagnosis

Default-off instrumentation on the 4-bit affine Qwen3.6 checkpoint reached the
donation path with all policy guards satisfied. The ten attention rows were
`[1, 2, 512, 256]` bfloat16 at offset 512, the 30 recurrent rows had
`[1, 3, 8192]` bfloat16 conv tails and `[1, 32, 128, 128]` FP32 SSM state, and
the 76,846,080-byte boundary passed the cache budget gate. Snapshot validation
then correctly rejected layer 0 because the declared conv dtype was `uint32`.

The declaration had read `embedTokens.weight.dtype`. That is the activation
dtype for an ordinary embedding, but a `QuantizedEmbedding` stores packed codes
as `uint32`; its dequantized output follows `scales.dtype`. Qwen creates every
conv tail from the embedding-derived `inputs.dtype`, so the recurrent spec now
uses the quantized embedding's scales dtype and retains the ordinary weight
dtype fallback. Shape, layer-index, SSM-FP32, identity, ownership, cancellation,
and byte-accounting checks are unchanged.

The post-fix snapshot reports 75,371,520 bytes and matches its independently
summed arrays. The 1,474,560-byte reduction from the pre-fix estimate is exactly
`30 * 1 * 3 * 8192 * (4 - 2)`: packed-`uint32` bytes that never belonged to the
bfloat16 conv state. This corrects admission and cache accounting to the real
owned arrays rather than weakening the hard budget.

## 8. Patch handoff

The agent identity can push the root repository but cannot push
`Layr-Labs/mlx-swift-lm` (GitHub returns 403). Recording its local commit as a
gitlink would therefore make fresh clones unable to fetch the object. Following
the existing artifact-eight handoff, the implementation is preserved as two
ordered root-repository patches:

```text
research/qwen36-prefill/patches/060-exact-cbv2-prefix-boundary.patch
research/qwen36-prefill/patches/061-provider-exact-prefix-wiring.patch
```

Apply `060` inside `libs/mlx-swift-lm` at local base `51ab73f` (the tree
produced by the ordered `052`–`055` patches documented in note 050).
Simultaneous prompt forking is not included. Then apply `061` at the root
repository to admit the stronger cache through `EngineV2Factory` without
admitting a legacy KV-only cache.

## 9. Follow-ons

1. Add a provider-side opt-in constructor that carves RAM from the unified
   memory grant and folds the verified weight + prompt-contract hashes into
   `modelIdentity`.
2. Measure full-prompt 2K/8K warm TTFT and decode parity on the fixed real
   checkpoint.
3. Generalize snapshots to arbitrary exact prefix boundaries.
4. Add simultaneous cold leader/follower fork-at-boundary only after a
   finalized-step ownership protocol exists.
5. Consider SSD persistence only after encrypted serialization includes every
   recurrent tensor, position, frontier logits, dtype, and format epoch.
