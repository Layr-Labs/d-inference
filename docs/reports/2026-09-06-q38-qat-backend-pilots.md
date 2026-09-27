# Qwen 3.8 and Gemma QAT backend/cache pilots

> Last updated: 2026-09-06 · commit `384c321aa`

Seven real-model B1 runs pass their individual integrity checks. Five strict
comparisons pass, but Gemma QAT contiguous/paged output parity fails; two historical
contiguous-SSD comparisons remain unsupported. This report records one repetition
per supported arm, not full-matrix completion, stable performance or release readiness.

## Scope and identities

The dedicated M5 runs use build8 `radix-engine`, SHA-256
`8e476149db74cede08a78a39d718c01f19e2d74a5654d00e2338250ba8b0eda1`.
The archive binds its executable mode and six exact resource hashes, frozen runner
and strict validators, model manifests, assistant inventory, CPU prompt evidence,
reviewed binding, and all actual reports, logs and telemetry. No executable or
model weights are archived.

- Q38 is `EigenLabs/Qwen3.8-27B-4bit-mtp`, model aggregate
  `bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463`;
  input/prepared SHA-256
  `fc0416c745ee7f7811fe4c3b92b07d0f4eec5af9612331fd94fb9611a7f59ec3`.
- QAT is `gemma-4-26b-qat-4bit`, model aggregate
  `2468a0cb3049a871f42052f4d9f9380bf12a0792f64c7a29f768559fc7d28785`;
  input/prepared SHA-256
  `1abb54db891314531df0b6ddfbe3cc3418c29fd014133cdf3837133c9e9a3080`.
  Its normal assistant is the exact two-file local override, aggregate
  `d8c5fae1f4b7a07376c9f0b92f3ec283ba276d57ec3b675d8cf758a79d73bd34`.

All cells preserve the reviewed matrix3 input bytes: UTC prompt date 2026-09-06,
128-token cap, concurrency 1, repetition 1, normal MTP and production single-slot
KV grants. QAT uses normal reasoning with no provisional thinking override.
Q38 prompts contain 5,523 tokens; QAT prompts contain 5,418. Each invocation uses
its own fresh SSD root and the original ephemeral benchmark key mode. These are
standalone engine pilots, not connected HTTP or persistent-key restart proof.

The separate `090-q38-qat-backend-pilots1` namespace changes only owned staging,
output and cache paths. The canonical matrix3 namespace remains absent and its
216 conceptual cells, 189 supported cells, 27 unsupported cells, 162 executable
comparisons and 54 dependent missing comparisons remain unchanged.

## Strict outcomes and retained failure

| Comparison | Result |
| --- | --- |
| Q38 contiguous cache off/on | PASS |
| Q38 paged cache off/on | PASS |
| Q38 contiguous/paged, cache off | PASS |
| Q38 contiguous/paged, cache on | PASS |
| QAT paged cache off/on | PASS |
| QAT contiguous/paged, cache off | FAIL: output mismatch |
| QAT comparisons needing contiguous SSD-on | Two unsupported; unrun |

Every passing cache comparison requires identical prompt/generated IDs, finish
reasons and token counts, authenticated native SSD staging with saved work,
tenant isolation, cancellation/recovery and coherent idle/shutdown evidence.
All seven cells pass individual checks; this alone does not establish backend
parity. No measured process overlaps another, and failed comparisons remain failed.

QAT's cold backend outputs first differ at zero-based output index **7**:
contiguous token **42392**, paged token **62203**. Contiguous produces 61 tokens
and paged 38; both finish with `stop`. The same difference appears in both main
rows, all three tenant rows, the cancellation donor and recovery. All 5,418
prompt IDs, model/input/runtime and assistant identities match. Performance across
those different output trajectories is not an accepted backend comparison.

Execution stopped after the sixth cell. The original failed comparison and
six-cell freeze were reviewed before the last original paged SSD cell was
authorized solely for independent cache evidence. That cache comparison passes
with the same 38-token paged output; it does not clear the cold backend failure.
The archive preserves the stop, review sequence and unchanged final result.

## Individual timing and memory observations

These are individual rows, with no averages or performance acceptance. MLX peak
is the **cumulative process peak observed at that row's final sample**, not an
isolated row peak. RSS is the final row-boundary sample, not peak RSS. GiB means
2^30 bytes. Exact before/after coherent memory, capacity, idle, MTP and production
grant records remain beside these values in `execution/row-summary.json`.

| Model | Backend | Cache | Row | TTFT s | Decode tok/s | MLX peak GiB | RSS GiB |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: |
| QAT | contiguous | off | first | 1.097 | 111.83 | 15.490 | 15.530 |
| QAT | contiguous | off | repeat | 1.093 | 114.14 | 15.490 | 15.531 |
| QAT | paged | off | first | 1.110 | 106.64 | 15.326 | 15.579 |
| QAT | paged | off | repeat | 1.099 | 107.27 | 15.326 | 15.580 |
| QAT | paged | on | first | 1.114 | 107.54 | 15.423 | 15.730 |
| QAT | paged | on | repeat | 0.395 | 107.23 | 15.423 | 16.185 |
| Q38 | contiguous | off | first | 6.097 | 51.65 | 21.275 | 15.584 |
| Q38 | contiguous | off | repeat | 6.528 | 52.24 | 21.275 | 15.584 |
| Q38 | contiguous | on | first | 6.096 | 52.28 | 21.317 | 16.026 |
| Q38 | contiguous | on | repeat | 1.838 | 51.52 | 21.317 | 16.453 |
| Q38 | paged | off | first | 6.134 | 46.34 | 21.286 | 15.646 |
| Q38 | paged | off | repeat | 6.581 | 46.66 | 21.286 | 15.651 |
| Q38 | paged | on | first | 6.115 | 50.87 | 21.329 | 16.070 |
| Q38 | paged | on | repeat | 1.845 | 52.52 | 21.329 | 16.560 |

All cache-on repeat rows authenticate and reuse 4,096 tokens. In these single
same-backend comparisons, Q38 repeat TTFT changes from 6.528 to 1.838 seconds
with contiguous attention and 6.581 to 1.845 with paged attention; QAT paged changes
from 1.099 to 0.395 seconds. Resident prefix-bank budgets remain zero. Row-boundary
coherent samples have age zero, no commitment debt and ready idle observations;
the paged pool's retained owner must not be mistaken for leaked live request KV.

Q38 cold paged decode is about 10–11% slower than cold contiguous in this pilot.
Normal MTP policy also differs between paged cache arms. For first/repeat rows,
paged-off proposes 101/104 speculative tokens and selects depth4 23/27 times;
paged-on proposes 88/84 and selects depth4 13/11 times. Accepted-token deltas
46/47 and round deltas 27/26 match. These are per-row deltas from cumulative
counters, not generated-token totals. [INFERENCE] Extra speculative work may
contribute to the observed decode difference; these observations do not isolate
its cause. Repeated normal-policy cells and a separately controlled follow-up
remain necessary. No policy, settings or gate was changed to improve the result.

## Evidence and remaining work

The [manifest](evidence/q38-qat-backend-pilots-2026-09-06/manifest.json) and
[archive](evidence/q38-qat-backend-pilots-2026-09-06/payloads.tar.gz) preserve
129 verified payloads, 9,220,169 uncompressed bytes; the archive is 622,859 bytes.

Manifest SHA-256: `cf8142a0a60a603f47e940b8dbb332942a38d69843b0f78efab45dd2dcc57ecf`.
Archive SHA-256: `42abf4c910af4ff56b5f34a6287583dd350b3d2b4429500515c3e3cabcba436f`.

The source-only pilot checks pass 12 CPU tests and the unchanged original matrix
checks pass 18. The final seven-cell raw collection was independently rechecked
both locally and by the root reviewer. Payload/runtime bytes and modes were
verified on M5. Final postflight finds no remaining model/helper/telemetry jobs,
353,395,228,672 free bytes and 5,896,409,343 retained SSD payload bytes. M5 was
handed to the next approved diagnostic owner; all pilot roots remain preserved.

QAT backend parity, existing Qwen3.5/Qwen3.6 failures, the full ordered B1/B2/B4
repeated matrix, native numerical/storage proof and persistent-key fresh-process
SSD restart remain open. No readiness-refusal probe is counted as a success.
Cache correctness in these pilots does not authorize a release/default change.

Related: [initial supported backend groups](2026-09-05-supported-backend-groups.md),
[initial QAT SSD pairs](2026-09-05-gemma-qat4-initial-pairs.md), and
[Qwen3.6 actual logits](2026-09-05-qwen36-actual-logits.md).
