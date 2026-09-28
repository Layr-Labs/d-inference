# Balanced Qwen9B prefill and installed HTTP timing

> Last updated: 2026-09-15 · commit `605651bb9`

Splitting Qwen3.5 9B evenly across the two M4 Pro Macs reduced median internal
first-token time from 16.556 to 10.059 seconds on one 8K diagnostic prompt.
A separate first-request HTTP observation reached nonempty content at 10.503
seconds, inside its 18.192-second allowance. These development results do not
establish representative SLA compliance or optimized solo speedup.

## Partition correctness

Both machines have 14 CPU and 20 GPU cores; their unified-memory capacities are
24 GB and 48 GB. The candidate assigns layers 0–15 to the 24 GB leader and
layers 16–31 to the 48 GB follower, using the same registered 4-bit artifact,
BF16 arithmetic policy, 512-token prompt chunks and Thunderbolt RDMA transport.
MTP and prefix reuse remain off.

A separate correctness request with 8,192 input tokens and 128 output tokens
matches the existing unpartitioned reference: all 128 selected IDs, the complete
496,640-byte final BF16 logit row and all 72 named state entries. Both native
cleanup acknowledgments and authenticated owner-release acknowledgments arrive;
independent postflight observes no workers and empty ownership journals.

## Internal resident timing

Each split loads its models once, then serves one excluded warmup and three
measured requests with fresh state. Both use the same prepared diagnostic prompt,
greedy selection, empty stop set and one-chunk lookahead implementation. Every
warmup and measured request returns the same pinned 128-token sequence.

| Layers on leader / follower | Measured first-token times (s) | Median first-token time (s) | Effective prompt tokens/s | Committed decode tokens/s |
|---|---|---:|---:|---:|
| 4 / 28 | 16.553463, 16.555883, 16.575706 | 16.555883 | 494.809 | 23.105 |
| 16 / 16 | 10.057397, 10.061357, 10.058654 | 10.058654 | 814.423 | 24.683 |

The effective prompt rate increases 64.59%; internal first-token latency falls
39.24%. The controller measures from its request-start call to the first
committed-token callback. This includes transport/control but excludes model
loading and reservation. Effective prompt rate is 8,192 divided by that interval;
decode rate uses 127 additional committed tokens divided by first-to-last-token
time. Rates are medians of the three measured requests.

These timing requests check all output IDs, without repeating the separate
full-logit/state comparison. Their remote per-request sidecars have not yet been
collected; controller records, source pins and cleanup observations are retained.
No independent dispatch conclusion is drawn solely from a caller-supplied policy
label. The two cohorts use native binary `009a671d…31a08b` and the fixed owner
`5aa5450c…c7c62d`; the HTTP observation below uses a different installed native
build and a different prompt.

## Installed Darkbloom HTTP observation

The installed capability already advertises the balanced partition. The real
`darkbloom cluster configure` command prepares both configurations, changing only
cluster ID and selected plan. The Provider `c4083695…f10350`, native worker
`ffcbd7de…9bba5`, model, trust, chunk size, schedule and 120-second request timeout
remain unchanged. The parent temporarily selects those configurations, then
restores the exact original Provider TOML bytes and modes on both hosts.

The installed `darkbloom start --local --distributed` endpoint serves one
authenticated request from the separate development Mac over Tailscale. The
actual Swift tokenizer matches all 8,192 prepared IDs before inference timing.
This is the first inference request in the fresh session, with no warmup request;
prior GPU/driver caches are not reset. The nonrepeated source-text prompt is the
same as the earlier [first-request observation](2026-09-15-cluster-first-request-8k.md).

| External client observation | Value |
|---|---:|
| Request send to first nonempty content | 10.503019958 s |
| First-content allowance | 18.192 s |
| First-content margin | 7.688980042 s |
| Total time through terminal stream and body EOF | 14.153499000 s |
| Requested output tokens | 128 |
| Reported output tokens / finish | 123 / stop |
| Nonempty content events | 122 |

Independent replay of the retained response bytes and arrival offsets reproduces
first-content time, terminal usage and DONE. EOS shortens generation, so this is
not a completed 128-output-token benchmark cell. It supplies no engine-only TPS
or new full-logit/state comparison for this HTTP prompt. The upstream OpenRouter
route is not exercised, and single observations are not a controlled repeated
HTTP comparison or evidence of latency percentiles.

## Resources, restoration and evidence

All retained samples pass the unchanged AC-power, zero-swap, normal-pressure and
six-GiB actual-free-memory guards. Raw replay checks 336/342 samples for the 4/28
cohort, 243/243 for 16/16 and 88/81 for HTTP. Minimum actual free memory during
HTTP is 9,015,623,680 / 29,018,521,600 bytes on the 24/48 GB members. Sampling is
not a continuous peak-memory bound. No compilation or competing remote work
overlaps any timed request.

The HTTP Provider exits zero without forced kill. Separate postflight observes
both workers absent and both journals empty; the temporary Thunderbolt address
is removed. Both saved defaults are restored exactly. Before/after live status
binds the balanced plan, observes both ranks ready and records one consumed
request admission. All frozen source, helper and client pins remain unchanged.

Raw evidence is retained under `/Users/developer/DarkbloomDev/cluster-research/`:

- `qwen9b-balanced-prefill-candidate-20260915/cases/cut16-correctness/physical-1`:
  numerical comparison and cleanup.
- `qwen9b-balanced-prefill-candidate-20260915/timing-comparison-root-review.json`:
  both internal cohorts, raw-resource replay and output-hash verification.
- `installed-product-balanced-http-qualification-20260915/root-review.json`:
  independent response replay, actual configuration transaction and restoration,
  source pins, tokenizer, live status and raw-resource replay.

The [delivery plan](../design/distributed-cluster-delivery.md) still requires an
optimized solo control, representative external workloads, 27B/Gemma execution,
active MTP, sustained serving and M3 Ultra projections. No release qualification
or 27B/M3 Ultra throughput result follows from these 9B measurements.
