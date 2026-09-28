# Distributed inference progress and first 27B timing

> Last updated: 2026-09-16 · commit `605651bb9`

Registered Qwen3.8 27B 4-bit completes a measured 8K request across the 24 GB
and 48 GB M4 Pro Macs at 164.90 effective prefill tokens/s. The corresponding
48 GB solo sample reaches 126.63 tokens/s. Each result contains one excluded
warmup and one measured request; repeated cohorts remain pending. This is
development evidence, not a release or representative SLA qualification.

Both cases use 8,192 input tokens, 512-token chunks, 128 greedy output tokens,
empty stop IDs, fresh request state and MTP off. The distributed case uses
16/48 whole-layer sharding and one-chunk prefill lookahead over plaintext
Thunderbolt RDMA. It does not implement tensor or expert parallelism.

| Measured case | Internal first token | Effective prefill | Continuation decode |
|---|---:|---:|---:|
| Optimized solo, 48 GB M4 Pro | 64.6948 s | 126.63 tokens/s | 12.43 tokens/s |
| Two M4 Pro Macs, 16/48 layers | 49.6797 s | 164.90 tokens/s | 10.36 tokens/s |

The observed prefill-rate ratio is approximately 1.30. Solo clocks begin before
fresh state construction and end at native token selection; distributed clocks
begin at the controller's start call and include owner control, transport and
token delivery. Both exclude model loading and reservation. These boundaries
are not identical. Prefill uses 8,192 divided by the interval to first token;
decode uses the 127 subsequent selections divided by the first-to-last interval.
Parent process duration is not used as throughput.

All 128 output IDs match the expected sequence in both requests of each case.
The distributed timing run does not repeat the separate
[full-reference logits and state comparison](2026-09-16-cluster-qwen27b-lookahead-correctness.md).
Both workers retire, both owner release acknowledgments arrive, both canonical
device journals are empty and independent postflight finds no remaining native
processes. The temporary Thunderbolt address is restored. Diagnostic EOF
completeness is not established by this older timing controller.

The distributed run contains 499 rank-0 and 505 rank-1 raw resource samples;
all pass independent replay for normal pressure, zero swap and AC power.
Minimum actual free memory is 6,551,617,536 and 18,928,107,520 bytes respectively.
The solo run contains 618 valid samples and a minimum of 13,895,909,376 bytes.
These are sampled observations, not continuous peak bounds.

A separate 32/32 attempt fails initial load admission before reading any
weights: the smaller Mac has 12,830,228,480 bytes free against a requirement of
13,165,129,827 bytes, a deficit of 334,901,347 bytes. Its workers, journals and
temporary address all clean up successfully. The six-GiB free-memory guard
remains unchanged. Adding more layers to the smaller Mac requires a new memory
analysis; the completed 16/48 timing alone does not establish that another cut
fits.

The 49.68-second internal first-token interval already exceeds the user's
18.192-second deadline for an 8,192-token request. No external HTTP measurement
was made for 27B. The earlier [9B measurements](2026-09-15-cluster-resident-solo-comparison.md)
remain 814 versus 440 effective prefill tokens/s, with slower distributed
decode; its [single external HTTP observation](2026-09-15-cluster-balanced-prefill-http.md)
is 10.503 seconds. No M3 Ultra was tested.

Two other development milestones complete on this date:

- Native mixed full/sliding-window state checks pass 21 groups, target sessions
  through tiny Qwen stages pass 15, and target verification state checks pass
  seven. All three runs retire cleanly. These 43 groups validate shared state
  machinery; they do not execute registered Gemma weights or a real assistant.
  A verified Gemma loader/full-and-stage forward implementation is drafted;
  its MoE resource owner and actual full-versus-split execution remain open.
- Native key-prelude CPU qualification passes 28 groups and 35 actual child
  processes, including independent OpenSSL vectors, bilateral key agreement,
  context substitution, replay, cancellation and single-use transport binding.
  A Swift tuple-label compile fix and a test-output filename fix are retained
  with their original failed attempts. Coordinator grant delivery, member-side
  invocation, admitted encrypted buffers and encrypted RDMA remain unqualified.

Evidence remains under `/Users/developer/DarkbloomDev/cluster-research/`:

| Evidence | Receipt SHA-256 |
|---|---|
| `qwen27b-solo-report-bound-v2-draft-20260916/physical-source/run-1/validated-sample.json` | `35445a84c946eb10f36346a640b28c34df7b116a3b0986f638f11ca824028e50` |
| `qwen27b-matched-short-cohort-draft-20260916/distributed/lookahead-1/physical-1/root-review.json` | `820578ae4acc5435a8d525fede336779cfe2525ed309c68b2576eb5442c39cca` |
| Distributed `execution.json` | `b10be7fa225afdff3751acee7f02bce78870c8a22b036c78544132debe6b13b9` |
| `cluster-native-key-prelude-validation-3-20260916/checks-1/checks.json` | `39e10340e16caee55d67c0e7b0faa3e4225833118ae69a02f1dce09189b148f4` |

Gemma state evidence is retained in
`gemma4-windowed-state-retry-draft-20260916/physical-collect-{window,session,target}-2`;
the memory refusal is retained in
`qwen27b-cut32-resource-pilot-20260916/physical-1/root-review.json`.
Automatic measured placement, tensor/expert parallelism, real MTP comparisons,
encrypted transport, sustained serving and product integration remain in the
[delivery plan](../design/distributed-cluster-delivery.md).
