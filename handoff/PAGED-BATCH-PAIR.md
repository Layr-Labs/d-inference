# Paged KV in the stages and continuous batching on the pair

> Branch `work/paged-batching` from `fa41f769d`. "Mac A" is the M3 Ultra
> (256 GB), "Mac B" the M5 Max (128 GB). Raw logs and reports are outside the
> repository in the task's evidence folder `paged-20261011`. Nothing here was
> pushed.

## Status

| Item | Status |
|---|---|
| Paged KV (the product's `PagedKVBackend`) in every Qwen 3.5 stage, on by default | Built; see the results section for what ran on hardware |
| Continuous batching on the pair (`DARKBLOOM_CLUSTER_BATCH_LANES=2...8`, pipeline mode) | Built; see the results section |
| Owner side (`ClusterWorkerPair(lanes:)`, event routing by request) | Built; model-free checks pass |
| Provider (`DistributedCBv2Engine` serves as many requests as the pair's lanes; installed owner passes the lanes) | Built; engine unit test |
| Batch lanes with MTP, prefix-cache reuse inside the loop, lookahead prefill | Not built (one request at a time keeps them) |

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
- Lossless by construction: prefill frames end on each request's own chunk
  grid (one frame per step, the request's own arithmetic); decode rows attend
  only their own KV (both backends dispatch attention per row); quantized
  projections at up to 8 rows stay on MLX's vector kernel on both chips
  (`get_qmv_batch_limit` is at least 12), so a row's arithmetic is the
  one-row arithmetic. The synthetic suite checks this bit for bit; the
  hardware waves compare every request's tokens with the same request run alone.
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

Filled in from the evidence folder as runs complete.

## Not built

- Batch lanes with MTP (the owner's oMLX capped MTP at one lane as well);
  prefix-cache restore and store inside the batch loop; lookahead prefill and
  mixed prefill quanta smaller than the request's chunk (they change a frame's
  arithmetic); two decode groups in flight to fill the pipeline bubble.
