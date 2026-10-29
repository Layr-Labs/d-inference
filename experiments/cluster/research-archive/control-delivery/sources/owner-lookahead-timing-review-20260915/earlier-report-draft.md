# Qwen9B lookahead correctness and internal timing

> Last updated: 2026-09-15 · commit `605651bb9`

One-chunk prefill lookahead completed a two-Mac Qwen3.5 9B 4-bit request and
matched the full-model reference for 128 selected tokens, the final BF16
vocabulary row and all final-state entry metadata/digests. A separate small
timing comparison reduced the median internal first-token interval from
19.270498 to 16.597917291 seconds. External provider HTTP TTFT remains unmeasured.

## Workload and scheduling

The same 24 GB and 48 GB M4 Pro Macs use JACCL over Thunderbolt RDMA, with
authenticated owner control. The request has 8,192 prompt tokens, B1,
512-token chunks, 128 greedy output tokens, no stop tokens and MTP off.
The 24 GB member owns layers 0–3 and the embedding; the 48 GB member owns
layers 4–31 and the final norm/output projection. The input is the retained
repeated-prose diagnostic prompt used in the
[serial continuation correctness check](2026-09-15-cluster-resident-generation-correctness.md).

Lookahead lets rank 0 prepare one subsequent prompt boundary after the prior
payload send completes and before its consumed acknowledgment arrives.
The shared commit uses the prior frame's captured frontier. Both ranks retain
the existing token/decision and retirement barriers. The recorded agreement
selects `oneChunkLookahead`; rank 0 reports 15 ahead preparations and at most
one prepared boundary, while rank 1 reports zero. Both report zero pending
consumed acknowledgments at completion and zero decode prefetches.

## Independent correctness check

The prospective lookahead comparator passed for the matched reference request:

- All 128 selected token IDs match; both ranks agree on the reported token chain.
- The independently reconstructed final BF16 vocabulary row matches byte-for-byte
  across all 496,640 bytes; final CPU argmax is token 33303 with one maximum.
- The ordered 72 final-state entries match metadata/digests, partitioned 9/63.
  Eight position offsets are reconstructed; the other 64 entries remain digest
  comparisons rather than independently reconstructed state bytes.
- Both ranks report 143 completed frames and committed frontier 8319.

Both workers completed native cleanup and authenticated owner-lease release.
Postflight observations found empty ownership journals and no retained workers;
the temporary network alias was restored. A separate CPU replay reproduced the
saved comparator result exactly. Intermediate candidate frontiers, per-token
logit rows, loaded weights and runtime provenance were not independently proven.

## Matched timing with the earlier control pump

Each mode loads once, performs one excluded warmup and then three measured
requests with fresh UUIDs and fresh request state. Serial runs first, then
lookahead; the order is not randomized. Both use the same native worker build,
prompt, chunk size, cut, output limit and recording-enabled diagnostic path.

The interval starts immediately before the controller calls `request.start`
and ends at its first committed-token callback. Both timestamps use that
controller's `DispatchTime` uptime. Loading and reservation are outside the
interval; owner transport, control and token delivery are included.
Effective prompt rate is `8192 / interval_seconds`, with the median over the
three measured requests. It is not a kernel-only rate or external HTTP TTFT.

| Earlier-pump cohort | Median internal first token | Effective prompt tokens/s | Median subsequent-token delivery rate |
|---|---:|---:|---:|
| Serial | 19.270498 s | 425.106 | 11.052 tokens/s |
| One-chunk lookahead | 16.597917291 s | 493.556 | 11.013 tokens/s |

The first-token interval falls 13.869%; effective prompt rate rises 16.102%.
The subsequent-token rate uses the 127 additional tokens between the first and
final callbacks and includes control overhead. Both cohorts retain the earlier
control pump with its 50 ms idle poll. This single diagnostic input and three
samples per mode establish neither sustained performance nor representative
workload performance, and they do not meet the 800-token/s target.

Every timed request's selected sequence matches the declared reference sequence.
Both rank sidecars match the request, model/Plan/build identities, final schedule
and intended prefill policy. These fresh-UUID timing runs did not receive a new
full-logit/state numerical comparison. Their sequence guard is separate from the
matched-request correctness result above.

## Resources and cleanup

All retained timing samples report AC power, zero reported swap, pressure level 1
and at least 6 GiB actual free memory. Independent replay checks the raw free-page
arithmetic. These are sampled observations, not a continuous peak-memory proof.

| Cohort | 24 GB member: samples / minimum free | 48 GB member: samples / minimum free |
|---|---:|---:|
| Serial | 451 / 6.783508 GiB | 460 / 11.203583 GiB |
| Lookahead | 413 / 7.025818 GiB | 421 / 11.259613 GiB |

All eight requests retire before their next reservation, with zero charged bytes
after release. Both cohorts finish with both native-cleanup and owner-lease ACKs,
zero-byte journals, no retained workers and restored aliases.

## Control-pump follow-up — pending before publication

Root is collecting matched cohorts with the corrected control pump. Add that
separate comparison and its exact scope here before freezing this draft. Do not
replace or pool the earlier-pump observations.

## Evidence and remaining milestone

The retained lookahead comparison is `owner-native-lookahead128-20260915/physical-1/comparison.json`,
SHA `fd79fcfd83615bec1fd8214940a885390d22f79e2ecf728aa2fff44d5c9b2a7f`.
The earlier-pump timing comparison is `owner-timing-comparison-20260915/comparison.json`,
SHA `692a619be389e32c9cf9695d6aa6f6b1e2527883d8e859a73dc9550ed507728f`.
Both use native worker SHA
`009a671d4e355131b6f38166536d00eee0fb5798000407808d716bc3ea31a08b`.
Independent source/raw-record review is pinned by
`d4f4943ccf832c9a4bfddad801e876da9565e520fe5247526ab4a73e3c4de7e9`.

The [execution plan](../design/distributed-cluster-execution-plan.md) now has
serial and lookahead continuation correctness for this registered 9B path.
Milestone 1 still needs end-to-end provider HTTP streaming/TTFT and the required
peer-failure/recovery qualification. This is no general-model serving release.
