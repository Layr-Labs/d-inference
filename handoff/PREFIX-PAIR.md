# Prompt-prefix reuse on the pair, on by default

> Last updated: 2026-10-10 (branch `work/cluster-paged-prefix`, base `1cb482bf8`)

"Mac A" is the M3 Ultra (256 GB), "Mac B" the M5 Max (128 GB). Raw logs and
reports are outside the repository in the task's evidence folder
`prefix-20261010`. Nothing here was pushed.

## Status

| Item | Status |
|---|---|
| Rank-local resident prefix reuse, dense Qwen (9B, 27B), pipeline and phase split | **Done, on by default**; measured across the cable (table below) |
| Agreement before the first forward; mismatch means a cold prefill on both ranks | **Done** (unit tests; every cable request agreed) |
| Provider: receipts, `cached_tokens`, frontiers published as resident evidence | **Done** (unit tests); not yet run through `darkbloom start` on the pair |
| SSD tier per rank | **Not built** (plan below) |
| Paged KV in the stages | **Not built**: blocked, see below |

## How it works

- **Cache.** Each rank keeps its own stage's committed state
  (`QwenStagePrefixCache`, `DarkbloomClusterRuntime/Models/Qwen/Prefix`). Both
  ranks use the same key: the agreed request scope (plan, artifact, storage,
  source configuration, arithmetic, profile, chunk size) plus the prompt tokens
  before the frontier. Least recently used goes first, by entry count (32),
  never by bytes. When the live memory check of a request or reservation would
  refuse, entries are dropped one at a time (and their buffers returned) until
  it passes; the cache never makes a request fail for memory.
- **Frames.** With the cache on, prefill starts at the reused prefix, chunks end
  on the global chunk grid (512), and the last prompt token runs in a frame of
  its own, so the state after N-1 tokens is an exact frame boundary for the
  hybrid recurrent layers. A hit always leaves at least one token to compute.
  Frontiers kept: every 512 grid end after the reused prefix, and N-1.
  Recurrent state is kept by reference (immutable confirmed arrays, as the
  product's hybrid checkpoints are); attention rows are copied once, at N-1,
  and shallower frontiers are views of that copy.
- **Agreement.** Before the first forward, two fixed 64-word exchanges over the
  collective (the same mechanism as the readiness digest). Each rank offers the
  frontiers it holds; both derive the same choice (the deepest frontier both
  hold; the split only if both caches are on). Each rank restores that frontier
  into a new session, then both confirm the choice, the key and the restore.
  Anything else and both drop what they restored and prefill from zero.
- **Lifecycle.** A rank inserts its captured frontiers only after both ranks
  retired the request cleanly. A failed request stores nothing and the rank
  sweeps its cache; shutdown sweeps before the model is released. A process
  that exits takes its cache with it, so a restarted pair starts cold.
- **Reporting.** Each worker sends `promptCache(reusedTokens, storedFrontiers)`
  just before `finished`. The owner requires rank 1's reuse to equal rank 0's,
  publishes the frontiers both hold, and the engine's terminal usage reports
  the hit (`prompt_tokens_details.cached_tokens`). The bridge mints a receipt
  per request and turns published frontiers into resident prefix evidence for
  routing.
- **Off switch (diagnosis only).** `DARKBLOOM_CLUSTER_PREFIX_CACHE=off` in a
  worker's environment. The installed owner passes it through from its own
  environment; `darkbloom-cluster-pair-check run --prefix-cache off`. One rank
  off is enough: neither rank splits or reuses.
- **Pair check.** `--follow-request FILE` (repeatable) runs further requests in
  the same loaded session; each request's report carries `reusedPromptTokens`,
  `storedPromptFrontiers` and its prompt digest.

## Measured across the cable, 2026-10-10

Rank 0 on Mac A (listener), rank 1 on Mac B, cut 16, chunk 512, 64 outputs,
greedy, serving path. "First" is a cold prompt with the cache on; "repeat" the
same prompt again; "shared" the same prompt with its last 256 tokens changed.
"Off" is a session with the switch off (no split, no reuse: the previous
behavior). Seconds to the first token; cached prompt tokens in brackets.

| Model, mode | Prompt | First | Repeat | Shared | Off |
|---|---|---|---|---|---|
| 9B pipeline | 8,192 | 5.70 | 0.030 (8,191) | 0.40 (7,680) | 5.62 |
| | 4,096 | 2.71 | 0.026 (4,095) | 0.37 (3,584) | 2.68 |
| | 1,024 | 0.67 | 0.024 (1,023) | 0.35 (512) | 0.66 |
| 9B phase split, lookahead | 8,192 | 4.10 | 0.083 (8,191) | 0.42 (7,680) | |
| | 4,096 | 2.03 | 0.045 (4,095) | 0.38 (3,584) | |
| | 1,024 | 0.59 | 0.041 (1,023) | 0.36 (512) | |
| 27B pipeline | 8,192 | 13.91 | 0.061 (8,191) | 0.98 (7,680) | 13.93 |
| | 4,096 | 6.83 | 0.054 (4,095) | 0.95 (3,584) | 7.14 |
| | 1,024 | 1.78 | 0.050 (1,023) | 0.93 (512) | 1.78 |
| 27B phase split, lookahead | 8,192 | 7.86 | 0.112 (8,191) | 1.03 (7,680) | |
| | 4,096 | 4.16 | 0.107 (4,095) | 1.04 (3,584) | |
| | 1,024 | 1.48 | 0.102 (1,023) | 1.02 (512) | |

The final build reproduced the 9B pipeline, 9B phase split and 27B pipeline
rows with identical tokens and first tokens within 2 %. The phase split rows
use the one-chunk lookahead prefill, so the pipeline's switch-off column is not
their cold baseline.

Output: in every row the repeat selected exactly the first request's tokens,
and the shared-prefix request exactly the tokens of the same prompt run cold
with the cache on. Splitting the last prompt token changes the arithmetic of
the final prefill frame: against the switch-off run some prompts diverge, at a
near tie (9B, 1,024 tokens, local socket: `divergedAtNearTie` at token 61,
1 ulp, against the staged reference, which equals the switch-off run
exactly). The split costs the 9B 13 to 82 ms on a cold first token; on the
27B the difference is inside run-to-run noise.

A fault (rank 1 ended with SIGTERM in the middle of a cache hit's decode)
failed that request; rank 0 exited by itself, no worker was left on either
Mac and wired memory returned; the next session served a cold and a repeated
request normally.

On Mac B, with about 45 GB of other applications resident, the 27B phase
split's decoding rank needs its full hand-off allowance: the first build of
the cache (no yielding) failed a request there on the live memory check after
the cache grew to 25 entries (about 3 GB on that rank). The cache now gives
entries back under that check; the rerun dropped 4 entries and completed.

## Not built

**SSD tier.** Plan, from the owner's design: per rank, a directory scoped by
plan fingerprint and rank holding each kept frontier's state (the attention
copy once per prompt, the recurrent state per frontier) and a boundary chain
per prompt; at load every rank sweeps directories of other plans; the offer
exchange gains a tier bit per frontier and a restore from disk goes ahead only
if both ranks vote for the same boundary (unanimous), with the same
confirmation as the resident tier (both restored or both cold). Needs a disk
budget, an eviction order consistent with the resident tier, and a restart
test.

**Paged KV in the stages.** The product's `PagedKVBackend` implements the same
`CBv2KVBackend` protocol and its `PagedLayerCache` owns attention dispatch, so
the model forward would not change. What blocks a bounded adoption:

1. Ownership. `CBv2OwnedRequestState` creates a contiguous backend per request
   and validates and snapshots through `CBv2LayerCache` rows and position
   offsets (about fifteen sites in `State/`). A paged pool is
   construction-fixed (slabs committed at first admission; capacity updates
   are no-ops), so it must live with the loaded stage in the resident runtime,
   and the state layer must be rewritten against `PagedSequenceKV`.
2. Admission. The resident allowance (`QwenDenseStageLoadResources`,
   `QwenResidentRequestResources`, `QwenLongPrefillTensorBudget`) and the
   phase-split allowance charge contiguous per-request KV for the maximum
   length. Paged needs the pool in the load-time footprint and page
   reservations per request, including on the decoding rank that holds every
   layer.
3. Hand-off. Snapshots of paged storage are recyclable
   (`requiresMaterializedSnapshots`), and adoption takes a
   `CBv2PrefixReusePlan`; the phase-split receiver needs a `.direct` plan.
4. Numerics. Paged decode for these models runs the paged Metal kernel, not
   the contiguous attention, so both modes on both models need requalifying
   against the single-Mac product, and the staged reference needs the same
   backend to stay an oracle.

With one request at a time on the pair (FEATURE-PARITY row 9) paged KV brings
no throughput; its value comes with batching and page-shared prefixes.
