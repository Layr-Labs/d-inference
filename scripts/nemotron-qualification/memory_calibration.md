# Nemotron Super memory calibration

`memory_calibration.py` drives the [qualification runner](super-runner.md)
through admission, near-limit refusal, cancellation at each phase, concurrency
and drain/restart while sampling memory, and writes a receipt comparing measured
peaks with the reservations held. These are runtime memory-budget measurements;
they never touch producer NVFP4/FP8 calibration scales. The receipt is evidence
for a reviewed change to reserves or floors; the script changes neither.

## Procedure

1. Build a release runner and stage the metallib ([super-runner.md](super-runner.md#build)).
2. Record machine state: no other GPU job (exclusive lane), memory pressure,
   thermal state. The receipt also captures them.
3. Run through the GPU lane with a fine sampling interval:

   ```sh
   python3 -I memory_calibration.py --out calibration.json --launch-runner "$RUNNER" \
     --runner-arg=--checkpoint --runner-arg="$MODEL" \
     --runner-arg=--sample-interval-ms --runner-arg=5 \
     --source provider="$PROVIDER" --source sdk="$SDK" --source mlx="$MLX" --model-dir "$MODEL"
   ```

4. Read the printed invariant counts, then the receipt's `invariants`. Repeat
   at least three times and after any material kernel, cache, batching or
   speculative-path change.

With `--runner-state DIR` the script uses an already running runner and skips
drain/restart.

## Scenarios

| Receipt key | What it does | Compared |
|---|---|---|
| `load` | reads `load.begin`, `load.quote`, `load.end` events | pending LOAD claim (quote + minimum KV) vs kernel max footprint growth and MLX peak during load |
| `geometry[]` | each context and image size at concurrency 1, peaks reset first | max over samples of the request's `media_ingress`+`media` rows (`incremental_request_reserved_bytes`) and of the whole ledger charge, engine-owned KV pages included (`incremental_ledger_charged_bytes`), above the idle owner vs MLX peak growth and footprint growth; margins with and without the global activation reserve; return to the idle ledger |
| `near_limit` | ballast leaves the remainder `margin` below, then above, the reference request's reservation rows (an image's media; text holds none) | refused below, admitted above; status, error, MLX peak growth on refusal |
| `cancellation[]` | client RST when the phase is observed: `ingress`, `media`, `prefill` (the bridge holds the request, no token yet), `decode` (after the first delta) | reservation rows retire only after the bridge reports the request inactive; ledger returns to idle |
| `concurrency[]` | 2/4/8 simultaneous text requests with 20 ms ledger polling | polled max charge within the cap; statuses; return to idle |
| `drain_restart` | SIGTERM during decode, then a fresh runner and one request | exit 0 and clean retirement, both times |

`native_completion_failure` is recorded as `not_exercised`: an HTTP client
cannot inject a native completion fault. The bridge's fault seams are exercised
by the provider fixture tests, not by this script.

## Reading the results

| Result | Meaning |
|---|---|
| `pass` | the invariant held with the recorded evidence |
| `fail` | it did not; the evidence shows the numbers |
| `inconsistent` | near-limit outcome did not match the boundary (live usage or other processes moved the remainder; see `remaining_after_ballast`) |
| `review` | every request charge retired, but the ledger total differs from the idle baseline only in unattributed (engine-owner) charge |
| `not_observed` | the phase or charge finished between samples; use a finer `--sample-interval-ms` or a larger workload |
| `not_exercised` | the scenario needs a seam or mode this run did not have |

Charges are sampled, so a reservation shorter than the interval can be missed;
the kernel interval footprint and MLX peak are tracked continuously. The
ledger's remainder subtracts live MLX active and cache memory and is clamped by
system-available memory, so other processes change near-limit outcomes. Request
rows are classified by reservation-ID suffix; the runner counts any other
request ID as `kv`.

Super serves paged attention KV only, and its bridge reserves no request
bytes: the engine's process-memory owner charges a request's KV pages and
recurrent rows to the ledger as they materialize, outside the rows
(`unattributed_bytes`). A text request therefore holds no reservation row,
and an image request only its `media_ingress` and `media` rows. The script
detects `prefill` from the bridge's active requests, times refunds only for
reservation rows (`early_refund` is `null` when the request held none), and
judges the engine's charge at settlement against the idle ledger (`review`
when only it differs). The near-limit probe needs a reservation row, so
without an image workload it is `not_exercised`.

Managed owners retain their prefill lane, decode rows, MTP round workspace and
prefix bank after requests finish. The idle snapshot records those reservation
IDs; request settlement excludes only those existing IDs, while new or unknown
reservations remain visible as leaks. Geometry reports both incremental request
capacity and the total owner-plus-request capacity that covers transient
allocations and newly retained cache entries. Geometry and the near-limit
probe subtract the already-held lane, decode rows and round work; otherwise a
text request would appear to reserve them, and the probe would leave their
worth of extra headroom and miss the actual request boundary.

Report, per phase and geometry: reservation, observed peak, margin, limits and
concurrency, next to the throughput receipt from `bench_super.py`. Keep the
conservative unmeasured vision reserve until repeated worst-case receipts
support a reviewed replacement, and coordinate capacity units with the platform
owner.
