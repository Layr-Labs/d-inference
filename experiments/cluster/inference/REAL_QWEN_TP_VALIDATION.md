# Registered Qwen3.5 9B local TP — 2026-09-13

The registered 9B artifact now executes through direct partition loading and
dense CBv2 state on two local processes, tested separately on an M4 Max and
an M4 Pro. Peers produce identical logits, but both FFN-only and full TP fail
the strict comparison with matched solo controls. The wider-output policy
changes the first selected token in both partition plans.
These runs establish bounded execution and reproducible numerical failures;
they do not qualify distributed model correctness or performance.

## Admission and verification

The [bounded local correctness contract](README.md#bounded-real-model-local-correctness)
requires an explicit opt-in and expected artifact hash. It retains bounded
configuration and actual token inputs before initialization, verifies the whole
artifact, and checks both rank storage commitments before selected weight reads.
Malformed metadata, fractional/exponent token syntax, missing capture, excessive
counts and worker use fail admission. Real loopback remains rejected by default.

Python additionally validates the complete captured logit files: row count,
vocabulary width, finite values and agreement with reported local argmax. It
cannot mark a run verified when capture is missing or truncated. Native and
Python report schema stays 9; worker protocol stays 5. Every loopback report is
correctness-only with invalid throughput timing, independent of model size.

The 187-test CPU suite passes. Native admission checks reject 47 cases; storage
checks accept five and reject 18, including exact-limit descriptor fixtures and
wrong-aggregate, oversized-manifest and excessive-payload rejection before
opening a missing weight file. No selected tensors are read in those checks.
The existing worker protocol check still accepts 4,112 and rejects 97 fixtures.

## M4 Max full-partition experiment

Four logical runs use one M4 Max with 14 CPU cores, 32 GPU cores and 36 GiB
unified memory. Each policy has one solo and one two-process full-TP control.
The FFN-only plan is omitted because its planning estimate exceeds available
headroom; the full plan has a smaller replicated-weight footprint and passes
its own bound. No memory limit is silently relaxed.

The input is the same 96-token prose prefix in chunks of 32, followed by four
captured outputs with fixed teacher inputs `[4087, 13, 271]`. All runs use actual
W4/G64 weights, BF16 activations/metadata, CBv2 contiguous state, zero warmups,
one repetition and disabled MTP. `both-wide` means Float32 attention/GDN and
FFN output projections/reductions, with one cast back to incoming dtype; it
does not widen every model operation.

All 12 artifact files, 6,113,952,230 bytes, rehash to aggregate
`127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b`.
Configuration SHA-256:
`c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423`.
An independent interpretation of the actual safetensor headers reconstructs the
entire partition commitment, including selected ranges and parameter layouts.
Every rank matches: 927 canonical text tensors, 5,038,041,600 source bytes,
3,893,236,224 sharded source bytes, 3,091,423,488 selected bytes per full rank,
and largest selected host tensor 508,559,360 bytes.

Both solo controls reproduce the previous native/both-wide 9B controls exactly.
Both full-TP pairs have exact peer logits and correct teacher history. Each full
rank records 384 floating model reduction hooks across six forwards. This is
an aggregate graph-hook count, not a per-layer transport trace.

## Numerical result

The unchanged gate requires every output row to have maximum absolute error
below `0.001`, relative RMS below `0.0001`, and equal argmax. All eight matched
solo/TP rows fail. Metrics use reconstructed IEEE Float32 values from the native
JSON output.

| Output row | Native relative RMS | Both-wide relative RMS | Both-wide argmax agrees |
|---|---:|---:|---|
| 0 | 0.01396574061 | 0.01234682770 | No |
| 1 | 0.01633654258 | 0.01375166936 | Yes |
| 2 | 0.01206828963 | 0.01099840957 | Yes |
| 3 | 0.01157325911 | 0.00938585643 | Yes |

Wider outputs reduce the worst relative RMS by 15.82%, but maximum absolute
error remains `0.1875`. Row two's absolute maximum worsens from `0.140625` to
`0.1875`. This is not a numerical or model-quality pass.

Native solo/full and both-wide solo select `[4087, 13, 271, 1206]`. Both-wide
full selects `[10926, 13, 271, 1206]` on both peers. The first three executions
tie IDs 4087 and 10926 at `19.875`, choosing the lower ID. Both-wide full lowers
4087 to `19.75`, one BF16 step, while 10926 stays `19.875`. The teacher then
supplies 4087 regardless of that first output. Later agreement therefore does
not establish free-running continuation.

Wider policies also change all four rows relative to native within each fixed
partition mode. That policy departure is separate from matched-policy TP error.
Both matched controls use the same CBv2 output-narrowing schedule, so the
[earlier vocabulary-head shape result](QWEN_OUTPUT_PRECISION.md) does not
explain away these discrepancies. Their causes still require isolation.

## Memory observations and limits

| Full-TP policy | Execution peak active MLX bytes, ranks 0 / 1 | Peak sampled combined owned-process RSS |
|---|---:|---:|
| Native | 3,254,154,522 / 3,254,105,370 | 5,697,880,064 |
| Both-wide | 3,414,376,730 / 3,414,376,730 | 5,862,719,488 |

All four full ranks report the same separate startup/loading observation:
active MLX 3,091,429,648, free cached MLX 11,794, and peak active MLX since
process start 3,091,440,148 bytes. Request execution resets its own peak after
loading. MLX active memory excludes host copies, free cache and process/OS
memory; sampled RSS is a different observation and can miss short transients.
Neither measure is a hard whole-system memory bound.

Recorded system pressure is level 2. System swap grows by 408,871,240 bytes
during native full and 123,543,224 during both-wide full, below the driver's
1 GiB stop threshold. These runs are not swap-free, and system-wide changes
cannot be attributed exclusively to the probe. Saved cleanup observations
show every observed owned process exited and each launcher was reaped.

## M4 Pro FFN and full-partition experiment

Six logical runs on an M4 Pro with 14 CPU cores, 20 GPU cores and 24 GiB
unified memory use the same artifact, executable, inputs and policies. Both
partition plans pass the headroom estimate on this machine. Each policy has
a solo, FFN-only and full-TP run; both ranks of each TP run share this Mac.
These are separate local experiments, not inference between the two Macs.

The isolated staged package retains the original drivers and all 146 source
entries. A wrapper changes only filesystem and archival locations; all 164
package files match the pinned manifest before and after execution. The CPU
replay verifies all ten rank reports, 40 output rows and 9,932,800 stored
logits. Every matching solo/full capture file is byte-identical to its M4 Max
counterpart, including the numerical failures.

| Partition / policy | Worst relative RMS vs matched solo | Worst absolute error | Matching argmax rows |
|---|---:|---:|---:|
| FFN-only / native | 0.01586730664 | 0.1875 | 4 / 4 |
| Full / native | 0.01633654258 | 0.1875 | 4 / 4 |
| FFN-only / both-wide | 0.01572166050 | 0.1875 | 3 / 4 |
| Full / both-wide | 0.01375166936 | 0.1875 | 3 / 4 |

All 16 matched rows fail the strict diagnostic gate. Wider outputs reduce
the worst relative RMS by only 0.918% for FFN-only; the full-plan improvement
is the same 15.82% seen on the M4 Max. Both wider TP plans select 10926 instead
of the solo control's 4087 at row zero. Subsequent rows share the fixed teacher
history; they do not measure continuation after the differing token.

The replay reconstructs both storage commitments from actual artifact headers.
FFN-only selects 3,679,087,104 stored bytes per rank from 2,717,908,992 sharded
source bytes; full TP has the same smaller footprint recorded above. The
four FFN ranks record 192 model reduction hooks each, and the four full ranks
record 384 each, totaling 2,304 across these six logical runs.

| Partition / policy | Execution peak active MLX bytes, ranks 0 / 1 | Peak sampled combined owned-process RSS |
|---|---:|---:|
| FFN-only / native | 3,916,221,274 / 3,916,221,274 | 8,695,873,536 |
| Full / native | 3,254,105,370 / 3,254,088,986 | 7,921,172,480 |
| FFN-only / both-wide | 4,132,559,962 / 4,132,559,962 | 9,033,826,304 |
| Full / both-wide | 3,414,376,730 / 3,414,262,042 | 7,940,702,208 |

All saved samples show normal system memory pressure (level 1) and zero swap
usage. Every observed owned process exits and each launcher is reaped. These
observations establish completion within this bounded workload; sampling and
MLX accounting retain the limitations described above.

## Evidence and remaining work

Tested executable SHA-256:
`26fe9543a617d97309c581bfdf80fc929b85fb2c652d9cd560f61191d1794770`.
The private research workspace retains the source/bundle snapshots, raw rank
outputs, memory samples, cleanup receipts and independent CPU replay under
`runs/qwen9-local-tp-full-20260913`. The replay checks all 146 archived source
entries and 5,959,680 captured values, reconstructs the full storage commitment,
and confirms both solo regressions. This is integrity evidence, not a complete
reproducible-build attestation.

The complete second-machine archive and independent replay are retained under
`runs/qwen9-peer24-20260913`. The replay verifies portable package identity,
both storage plans, complete captures, cross-machine equality, memory samples
and process cleanup. Existing provider services and network configuration are
unchanged by the isolated staging and test execution.

Source review identifies a concrete next arithmetic experiment: compare the
full and selected input projections on the same evaluated input, before
convolution, recurrence or attention. At the actual 9B chunk width, pinned MLX
dispatch predicates predict different split-K counts when output rows are
partitioned. Partial results use the input dtype, so output-only widening
cannot repair earlier rounding. This is a source-derived hypothesis, not a
captured kernel trace or an established cause of the whole-model discrepancy.

Whole-layer prefill pipelining is a second architecture candidate: preserve
complete projection geometry within a stage and send a residual-stream chunk
between stages. It needs explicit stage weight ownership, ordered state commits
and bounded point-to-point transport. Its correctness and performance are
unmeasured; preserving operator widths alone does not establish a speedup.

The [distributed goal](../../../docs/design/distributed-inference-goal.md)
remains active. Causal arithmetic isolation,
representative continuation/quality checks, physical RDMA, production scheduler
integration and target M3 Ultra performance remain open. No result here measures
the registered 27B model or qualifies the 800 TPS acceptance target.
