# Resident prefix cache: serial Qwen measurements

> Last updated: 2026-09-05 · commit `5477b6e32`

The first hybrid-cache prototype reduced median first-token latency for repeated
5,523-token prompts from 6.50 to 1.75 seconds in the engine, and from 6.56 to
1.79 seconds through the provider HTTP endpoint. All 57 engine requests matched
the clean baseline's generated token IDs. These measurements use **MTP off**;
they do not establish the speed or correctness of the later MTP implementation.

## Scope and artifacts

The baseline is clean `e928d395fa4f97e736552a6de89b37876b2bc56b` with its
recursive submodules pinned, documented in the
[baseline report](2026-09-05-radix-prefix-cache-baseline.md). Both versions ran
serially on the dedicated 128 GiB M5 Max, with the same Qwen model revision
`06d517d395dfc5588090f7f534112bee331f7b4a`, greedy sampling, thinking disabled,
and the same ordered requests. The baseline's assistant messages were replayed
verbatim for second turns. Loading and an eight-token warmup precede measurement.

The prototype is parent `788ce9f067f90128af1b71424023574b9d5d21c5` and LM
`713d2cf4bfb244ac1c8eef7e6a5e8c6fc99091f0` plus the retained source patches.
It predates the MTP, deeper inherited-checkpoint, and later lifecycle fixes.
The direct harness explicitly constructs a 1 GiB bank with two entries and two
checkpoints per request; its KV budget is 16 GiB. HTTP uses the normal slot
factory with `DARKBLOOM_PREFIX_CACHE=1`, `mtp_mode="off"`, and backend auto.
Both paths resolve to contiguous KV storage.

| Artifact | SHA-256 |
|---|---|
| Prototype engine | `12eb88396333d48754839830b048e4abb53cb5e92679483771a999a923fd791a` |
| Prototype provider | `ab745567e27aedf56252d47f9df0ecdc1067fb94aa20b47a8c32e531c14e7d29` |
| Engine harness source, both builds | `b71f6fce7d43b5b291c09aaea10e02199ee2a15217acf8e195861189483a7a40` |
| Shared Metal library | `4ffbbac48a99b495916c3fa0921ce813eb554de1a09aff408d9b5a5a8053e6b0` |

The [engine artifact manifest](evidence/2026-09-05-radix-prefix-cache/candidate-serial-engine-artifact.json)
contains the complete source manifest and compile define. The
[provider manifest](evidence/2026-09-05-radix-prefix-cache/candidate-serial-provider-artifact.json)
pins the HTTP binary. The compressed
[source patches and verification manifest](evidence/2026-09-05-radix-prefix-cache/candidate-serial-patches.json)
reconstruct the compiled source against those bases; both patches passed
`git apply --check --cached` against their specified base indices.

## Latency and decode

Each row below is the median of three independently prefixed conversations.
Long branches contain 5,520 prompt tokens and second turns contain 5,611.
Every warm engine row saves exactly 4,096 prefill tokens. Prompts at the smaller
381/1,411-token cells remain cold because they do not reach a full natural
4,096-token checkpoint boundary.

| Request | Engine baseline → prototype, seconds | HTTP baseline → prototype, seconds |
|---|---:|---:|
| Cold first prompt | 6.482 → 6.439 | 6.554 → 6.470 |
| Exact repeat | 6.499 → 1.750 | 6.564 → 1.788 |
| Shared-prefix branch | 6.496 → 1.740 | 6.564 → 1.764 |
| Second turn | 6.566 → 1.821 | 6.705 → 1.850 |

The repeated-prompt reduction is 73.1% in the engine and 72.8% over HTTP.
The small difference between cold medians is not attributed to the cache.
Median terminal-event overhead after the donor's final token is 5.287 ms in
the baseline and 5.509 ms in the prototype. Capture therefore did not introduce
a large delayed terminal event in this workload.

Decode remains unchanged: the three 256-token engine controls have medians
33.713 versus 33.683 tokens/second. HTTP estimates are 33.712 versus 33.677.
These are whole-generation rates; they are not isolated kernel benchmarks.

## Correctness and limitations

The [full engine comparison](evidence/2026-09-05-radix-prefix-cache/candidate-serial-full-verdict.json)
passes all 57 ordered prompt-ID/generated-ID, token-count, and clean-finish
comparisons. Every long repeat, branch, and second turn records a real hit and
4,096 saved tokens. Re-donating the longest prompt and then requesting it under
tenant A, tenant A, and tenant B produces equal output IDs; tenant A reuses the
prefix and tenant B saves zero tokens. Cancellation emits a cancelled terminal
event; the subsequent request completes with the baseline's IDs and no cache
entry inherited from the cancelled donor.

All 57 HTTP responses match full text, reasoning, token counts and finish
reasons. HTTP does not expose generated IDs or sufficient cache usage fields;
the engine companion supplies that evidence. The HTTP disconnect/recovery
probe also completes. These are single-provider real-model tests.
[Coordinator routing validation](evidence/resident-routing-2026-09-05/manifest.json)
covers cross-machine selection and receipt scenarios in Go tests, not an actual
two-machine live-model benchmark.

The engine run entered at 30.5°C and reached 91.9°C; HTTP entered at 27.9°C and
reached 91.4°C. Thermal traces include loading and warmup. At samples with GPU
utilization at least 90%, minimum clocks were 1,458 MHz in the prototype engine
run and 1,457 MHz in HTTP, versus 1,457 MHz for both baseline runs. Entry
temperatures differ, so small timing changes should not be treated as gains.
The substantial warm improvement has direct saved-token evidence.

A later cache-disabled control used the identical prototype engine binary and
the same first/repeat long prompts. It saved zero tokens, took 5.878/6.122 seconds
to first token, and matched the baseline's generated IDs. The shorter cold
time illustrates the thermal/run-order variation; turning off reuse still
restores the multi-second prefill cost. The
[control comparison](evidence/2026-09-05-radix-prefix-cache/candidate-serial-cache-off-verdict.json),
[raw rows](evidence/2026-09-05-radix-prefix-cache/candidate-serial-cache-off-report.json.gz),
and [telemetry](evidence/2026-09-05-radix-prefix-cache/candidate-serial-cache-off-telemetry.jsonl.gz)
are retained. An initial control launch refused a 43.6°C entry temperature
before loading the model; the recorded control is the subsequent accepted run.

## Retained evidence

- [Complete engine requests, IDs, timing and usage](evidence/2026-09-05-radix-prefix-cache/candidate-serial-full-report.json.gz)
- [Engine telemetry](evidence/2026-09-05-radix-prefix-cache/candidate-serial-full-telemetry.jsonl.gz)
- [Complete HTTP requests, responses and SSE events](evidence/2026-09-05-radix-prefix-cache/candidate-serial-http-report.json.gz)
- [HTTP telemetry](evidence/2026-09-05-radix-prefix-cache/candidate-serial-http-telemetry.jsonl.gz)
- [HTTP configuration and lifecycle metadata](evidence/2026-09-05-radix-prefix-cache/candidate-serial-http-metadata.json)

The baseline report retains the corresponding cold artifacts, raw data and
reproduction commands. Later MTP and longer-prefix measurements require their
own source manifests and same-mode baseline comparisons.
