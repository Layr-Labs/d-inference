# Paged KV in the stages and continuous batching on the pair

> Branch `work/paged-batching` from `fa41f769d`. "Mac A" is the M3 Ultra
> (256 GB), "Mac B" the M5 Ultra (256 GB) that replaced the M5 Max on
> 2026-10-11. Raw logs and reports are outside the repository in the task's
> evidence folder `paged-20261011`. Nothing here was pushed.

## Status

| Item | Status |
|---|---|
| Paged KV (the product's `PagedKVBackend`) in every Qwen 3.5 stage, on by default | Built; ran on the M3 Ultra + M5 Ultra pair (9B, 27B): lossless under the pass rule; one-request decode 3 % (27B) / 10 % (9B) slower than contiguous after a partial fix (finding below) |
| Continuous batching on the pair (`DARKBLOOM_CLUSTER_BATCH_LANES=2...8`, pipeline mode) | Built; ran on the pair: 9B 201 tok/s and 27B 64.5 tok/s aggregate at 8 concurrent, rows near-tie lossless |
| Owner side (`ClusterWorkerPair(lanes:)`, event routing by request) | Built; model-free checks pass |
| Provider (`DistributedCBv2Engine` serves as many requests as the pair's lanes; installed owner passes the lanes) | Built; engine unit test |
| Prefix-cache reuse inside the batch loop (a joining lane's prefix agreed in its join step) | Built |
| Batch lanes with MTP, lookahead prefill | Not built (one request at a time keeps them) |

## Paged KV in the stages

- One `CBv2StageKVHost` per loaded Qwen 3.5 stage (`State/CBv2StageKVHost.swift`):
  the product's segmented paged pool (64 MB segments, native KV dtype,
  committed at first admission), its `PagedLayerCache`s mapped to the model's
  compact attention order exactly as `EngineV2Factory+BackendPreparation` maps
  them, and one `CBv2LayerCacheBank` for every request of the stage.
- `CBv2OwnedRequestState` takes its rows from the host's backend and binds
  them through the host's bank. Validation binds its own rows first;
  retirement proves its own rows are unbound everywhere (other lanes may still
  hold pages). Adoption (phase-split hand-off, prefix restore) goes through the
  backend's own direct prefix plan: paged writes the arrays into fresh pages.
- The pool's capacity is a ceiling for `lanes` requests of the admitted
  context (page-rounded) plus one segment; pages are reserved per request at
  its own maximum length. The resident allowance is unchanged: it charges the
  full model's F32 KV at the request length, which bounds one stage's bf16
  page-rounded pages plus a segment.
- `DARKBLOOM_CLUSTER_KV_BACKEND=contiguous` is the diagnosis switch (the same
  shared host over the contiguous backend). The kind and the lanes are bound
  into the load agreement; contiguous with one lane keeps the old bytes.
- Hosts are installed at resident load (and for a phase-split rank 1's
  producer stage), in the staged reference (two lanes: its phase split adopts
  into stage 0 while the producer is open) and in the staged service, and
  removed before the stage is released. A shutdown that finds a pool still
  holding pages is a failed release.
- Gemma 4, Nemotron, MiMo and GPT-OSS keep their per-request contiguous storage.
- Deployment: the paged backend compiles its kernel from `pagedattention.metal`,
  which MLXLMCommon looks for at a bundle's root or beside the executable. The
  native worker build writes macOS-layout bundles (`Contents/Resources`), so
  `scripts/build-native-worker.sh` now places the source beside the worker and
  refuses a missing or conflicting copy. Every installed worker directory needs
  it: a paged stage refuses to load by name without it (no silent fallback).

## Continuous batching on the pair

- Lockstep loop on both ranks (`Models/Qwen/Resident/QwenResidentRuntime+Batch.swift`,
  `Models/Qwen/Batch/`). Rank 0 decides each step and sends a fixed header
  (`QwenBatchWire.Header`): joins (with the first 16 bytes of the request
  fingerprint), one batched decode of every decoding lane, at most one prefill
  frame of the earliest-joined prefilling lane, and leaves with their finish
  reasons. Rank 1 follows and answers with the tokens it selected
  (`QwenBatchWire.Reply`). Residuals cross with their SHA-256 and are verified
  as the one-request boundary is. The opening exchange checks lanes, KV
  storage and geometry, and agrees the final-token split (split exactly when
  both prefix caches are on, as the one-request path does).
- Lossless under the pass rule, not bit for bit. Prefill frames end on each
  request's own chunk grid (one frame per step) and keep the request's own
  arithmetic; decode rows attend only their own KV (both backends dispatch
  attention per row). But two or more decode rows share every affine
  quantized projection, which MLX (`fdae3174`) runs as `qmv_wide` (8 lanes
  reduce K per output) where one row runs `qmv_fast` (32 lanes): a batched
  row rounds differently from the same request alone, identically for every
  batch size from two up (wave 2 == wave 4 for every request on the local
  socket). The shipped MTP verify window (2-4 rows) has the same property.
  A batched request's tokens therefore equal its solo run exactly or first
  diverge at a near tie (top-2 gap <= 4 bf16 ulp); the hardware waves record
  every request's solo run and the near-tie verdicts. Exact rows need a
  row-exact multi-row kernel (per-row `qmv_fast` arithmetic, including the
  fused GDN input projection) or one-row projections per lane (exact but no
  weight reuse, so no throughput gain). The synthetic suite (unquantized)
  checks batched rows bit for bit.
- Requests reach both ranks through their owners exactly as for one request
  (reserve, start, decisions on rank 0). `ClusterWorkerLaneSession` keeps each
  request's order identical to `ClusterWorkerSession`; the worker applies
  control between steps; the owner-side pair files each worker's events by
  request (`ClusterWorkerEventRouter`).
- Lane admission: the newest lane's whole allowance plus every other lane's
  named state (lanes share the stage's one-time fusion and run one prefill
  frame at a time).
- A cancelled lane, a deadline or any failure ends the loop and the worker,
  as a failed request ends the one-request worker.

## Pair check

`darkbloom-cluster-pair-check run ... --batch-lanes N --batch-request FILE
(up to 8) --batch-wave N (repeatable) [--batch-solo yes|no] [--kv-backend
paged|contiguous]` runs each batch request alone, then each wave of the first
N requests started together, and reports per-request first token and decode,
aggregate throughput and whether every request's tokens equal its solo run
(`timing.batch`).

## Results

Filled in from the evidence folder as runs complete. Local-socket runs (both
ranks on Mac A) check correctness only; they are not hardware figures.

| Run (9B, local socket, both ranks on Mac A) | Result |
|---|---|
| Model-free: protocol lane checks (9 groups), 14 check runners, qualification XCTests | Pass |
| Synthetic suite: batched rows == each request alone (paged and contiguous), paged tokens == contiguous; allowance bound (3 tests) | Pass |
| One request, contiguous vs paged, pipeline | Both 192 tokens; paged first diverges from contiguous at index 32 (a near-tie flip; phase-split MTP and the batched rows pick the same token as contiguous) |
| One request paged: phase split == pipeline exactly; phase-split MTP | Pass (MTP: same index-32 flip) |
| 4 lanes paged: each request alone == the one-request worker (p0, exact); waves of 2 and 4 | Completed; wave 2 == wave 4 for every request; vs alone first difference at 32 / 78 / 79 / 144 (qmv_wide rounding, above); aggregate 93 tok/s (2 requests), 147 tok/s (4) vs ~58 tok/s one request (socket) |
| Provider: `DistributedCBv2Engine` batch-lanes unit test | Pass |

Near-tie judge: Mac A single-Mac references of the same eight requests with
per-step top logits (staged reference, paged default; a recorded pair run has
no step records). Socket waves vs those references: every row exact or a
near tie (0-2 bf16 ulp).

### Cable: Mac A (M3 Ultra) + M5 Ultra, Thunderbolt 5 RDMA, 2026-10-12 01:20-01:28 PDT

Eight requests per model (prompts 512-2048 tokens, 192 generated, greedy,
prefix cache off), pipeline mode, paged KV by default. 9B cut 4, 27B cut 16
(rank 0 on Mac A). Timing is the driver's clock per request.

| | 9B | 27B |
|---|---|---|
| One-request worker, paged (default): first token / decode | 0.19-0.69 s / 72.1-76.4 tok/s | 0.72-2.75 s / 32.0-34.3 tok/s |
| One-request worker, contiguous (`--kv-backend contiguous`) | 0.19-0.68 s / 82.5-84.4 tok/s | 0.72-2.73 s / 35.4-35.8 tok/s |
| Batch loop (8 lanes, paged), each request alone | 0.19-0.69 s / 83.3-87.1 tok/s | 0.71-2.73 s / 35.7-36.5 tok/s |
| Aggregate, concurrency 1 / 2 / 4 / 8 | 79.7 / 118.1 / 167.5 / 200.9 tok/s | 32.2 / 47.8 / 56.9 / 64.5 tok/s |
| Stage KV pool ceiling, 1 lane (A / B) | 192 MiB / 960 MiB | 576 MiB / 1600 MiB |
| Stage KV pool ceiling, 8 lanes (A / B; committed per 64 MB segment as used) | 1.06 GiB / 7.06 GiB | 4.06 GiB / 12.06 GiB |
| Peak worker footprint, paged 1 lane / contiguous 1 lane / paged 8 lanes (A; B) | 2.01 / 1.96 / 1.96 GiB; 5.33 / 4.77 / 5.98 GiB | 5.72 / 5.19 / 5.73 GiB; 12 / 12 / 14 GiB (top rounds to whole GiB) |

Correctness (pass rule: exact, or first divergence at a near tie <= 4 bf16
ulp of the reference's top-1):

- Every row of every run (one-request paged, one-request contiguous, batch
  loop alone, waves 1/2/4/8; 8 requests x 2 models) against the Mac A
  references: exact or a near tie, gaps 0-2 ulp (most 0 ulp: exact bf16
  ties). Every pair row diverges from the M3 Ultra reference somewhere in
  192 tokens: rank 1 runs on the M5 Ultra (a different numerics class).
- A recorded paged pair run vs the established Mac A reference of the
  integration branch (comparator, schedule difference allowed):
  `divergedAtNearTie` (9B at index 47, 0 ulp; 27B at 117, 1 ulp).
- The batch loop's solo runs equal the one-request paged worker's tokens
  exactly for all 8 requests of both models. Waves differ from solo at near
  ties (qmv_wide, above); 27B waves of 1 and 2 equal solo.
- Batch-invariance probe (synthetic weights, the 9B's shapes): norm, rope,
  depthwise conv and the gated delta step are batch-invariant; only the
  quantized projections change between one row and a batch.

FINDING: the one-request worker with paged KV decoded 6-12 % slower than
contiguous (9B 72-76 vs 83-84 tok/s, 27B 32-34 vs 35-36), while the batch
loop's paged decode of the same request alone is as fast as contiguous. First
token is unchanged. Suspect: the one-request state validation after every
step snapshots each attention row, which on the paged backend builds a page
gather per layer per token; the batch loop's row validation does not.

Partial fix, measured on the pair (`bddd83f46`: one-token paged decode steps
check each row's frontier and binding only; views still checked at adoption,
after prefill frames and speculative windows). Same eight requests, same
pair, prefix cache off; tokens equal the earlier paged run exactly for all
16 rows (validation-only change, so the near-tie verdicts above carry over):

| Decode, mean of 8 (range per request) | 9B | 27B |
|---|---|---|
| Paged, before | 74.7 tok/s | 33.4 tok/s |
| Paged, with the fix | 75.4 tok/s (+0.9 %, -1.1..+3.0 %) | 34.5 tok/s (+3.2 %, +1.4..+7.0 %; largest at 2048 prompt) |
| Contiguous | 83.8 tok/s | 35.5 tok/s |
| Paged with the fix vs contiguous | -10.1 % (-11.5..-8.5 %) | -3.0 % (-3.4..-2.6 %) |

So the page-gather snapshot was part of the 27B gap and almost none of the
9B gap. The remaining gap is elsewhere in the one-request path (the batch
loop alone is as fast as contiguous). Not measured yet; next suspects by
source read: the per-layer `positionOffsets.asArray` frontier read (one
host sync per attention layer per token) and the per-step row rebind
(`bank.layerCaches(rowStates:)`) before the check.

## Not built

- Batch lanes with MTP (the owner's oMLX capped MTP at one lane as well);
  lookahead prefill and
  mixed prefill quanta smaller than the request's chunk (they change a frame's
  arithmetic); two decode groups in flight to fill the pipeline bubble.
