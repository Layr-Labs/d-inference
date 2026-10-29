# Qwen9B lookahead correctness and internal timing

> Last updated: 2026-09-15 · commit `605651bb9`

One-chunk prefill lookahead completed a two-Mac Qwen3.5 9B 4-bit request and
matched the full-model reference for 128 selected tokens, the final BF16
vocabulary row and final-state metadata/digests. With the corrected control
pump, median internal first-token time was 19.231474125 seconds for serial and
16.583442167 seconds for lookahead. External provider HTTP TTFT remains unmeasured.

## Workload and scheduling

The 24 GB and 48 GB M4 Pro Macs use JACCL over Thunderbolt RDMA with
authenticated owner control. The request has 8,192 prompt tokens, B1,
512-token chunks, 128 greedy output tokens, no stop tokens and MTP off.
The 24 GB member owns layers 0–3 and the embedding; the 48 GB member owns
layers 4–31 and the final norm/output projection. The repeated-prose diagnostic
prompt is the one used in the
[serial continuation check](2026-09-15-cluster-resident-generation-correctness.md).

Rank 0 can prepare one subsequent prompt boundary after sending the prior
payload and before receiving its consumed acknowledgment. The shared commit
uses the prior frame's captured frontier; token/decision and retirement barriers
remain. The recorded agreement selects `oneChunkLookahead`: rank 0 reports 15
ahead preparations and at most one prepared boundary; rank 1 reports zero.
Both report zero pending consumed acknowledgments and zero decode prefetches.

## Independent correctness check

The prospective comparator passed for the matched full-reference request:

- All 128 selected token IDs match; both ranks agree on the reported token chain.
- The independently reconstructed final BF16 vocabulary row matches all 496,640
  bytes. Final CPU argmax is token 33303 with one maximum.
- The 72 ordered final-state entries match metadata/digests, partitioned 9/63.
  Eight position offsets are reconstructed; the other 64 entries are digest
  comparisons, without independent reconstruction of their state bytes.
- Both ranks report 143 completed frames and committed frontier 8319.

Both workers completed native cleanup and authenticated owner-lease release.
Postflight found empty ownership journals and no retained workers; the temporary
network alias was restored. CPU replay reproduced the comparator result exactly.
Intermediate candidate frontiers, per-token logit rows, loaded weights and
cryptographic runtime provenance were not independently proven.

## Matched internal timing

Each mode loads once, performs one excluded warmup and three measured requests
with fresh UUIDs/state. Serial runs first, then lookahead; order is not randomized.
All cohorts use the same native worker, prompt, cut, chunk size, output limit and
recording-enabled path. The follow-up retains the controller source/executable
and updates its Protocol/Process modules, including outgoing-pipe wakeup.

The interval begins immediately before `request.start` and ends at the first
committed-token callback, on the same controller's `DispatchTime` uptime.
Load and reservation are excluded; owner transport/control/delivery are included.
Effective prompt rate is `8192 / interval_seconds`, taking the median of three
requests. Subsequent-token rate is `127 / (final_callback - first_callback)`.
Neither rate is kernel-only throughput or external HTTP TTFT.

| Control pump / mode | Median internal first token | Effective prompt tokens/s | Median subsequent tokens/s |
|---|---:|---:|---:|
| Earlier / serial | 19.270498 s | 425.106 | 11.052 |
| Earlier / lookahead | 16.597917291 s | 493.556 | 11.013 |
| Wakeup / serial | 19.231474125 s | 425.968 | 22.887 |
| Wakeup / lookahead | 16.583442167 s | 493.987 | 22.903 |

Within the wakeup pair, first-token time falls 13.769% and effective prompt rate
rises 15.968%. Earlier-pump observations remain separate. The wakeup cohorts
retain a 50 ms watchdog interval; the change removes the outgoing-data wait.
One diagnostic input and three samples per mode establish neither sustained
nor representative performance, and these rates remain below the 800-token/s target.

Every timed request matches the declared 128-token sequence. Both sidecars join
to request/model/Plan/build identities, final schedule and intended policy.
These fresh-UUID runs did not receive a new full-logit/state comparison; their
sequence guard is separate from the matched-request correctness result above.

## Resources and cleanup

All retained timing samples report AC power, zero reported swap, pressure level 1
and at least 6 GiB actual free memory. Replay checks raw free-page arithmetic;
these are sampled observations, not continuous peak-memory proof.

| Cohort | 24 GB: samples / minimum free | 48 GB: samples / minimum free |
|---|---:|---:|
| Earlier serial | 451 / 6.783508 GiB | 460 / 11.203583 GiB |
| Earlier lookahead | 413 / 7.025818 GiB | 421 / 11.259613 GiB |
| Wakeup serial | 375 / 7.043030 GiB | 382 / 10.507797 GiB |
| Wakeup lookahead | 331 / 7.026535 GiB | 338 / 10.499466 GiB |

All requests retire before the next reservation, with zero charged bytes after
release. All four cohorts finish with both native-cleanup and owner-lease ACKs,
zero-byte journals, no retained workers and restored aliases.

## Evidence and remaining milestone

Retained comparison files and SHA-256 pins:

- `owner-native-lookahead128-20260915/physical-1/comparison.json`:
  `fd79fcfd83615bec1fd8214940a885390d22f79e2ecf728aa2fff44d5c9b2a7f`.
- `owner-timing-comparison-20260915/comparison.json`:
  `692a619be389e32c9cf9695d6aa6f6b1e2527883d8e859a73dc9550ed507728f`.
- `owner-timing-wakeup-comparison-20260915/comparison.json`:
  `524f022febed24e2bc334c5545f6c7a2ffe2bd64151db5e33320c0cb74ee2834`.

All use native worker SHA
`009a671d4e355131b6f38166536d00eee0fb5798000407808d716bc3ea31a08b`.
Independent raw-record and arithmetic checks accompany the private report handoff.
The [execution plan](../design/distributed-cluster-execution-plan.md) now has
serial/lookahead continuation correctness for this registered 9B path. Milestone 1
still needs end-to-end provider HTTP streaming/TTFT and peer-failure/recovery
qualification. This does not establish a general-model serving release.
