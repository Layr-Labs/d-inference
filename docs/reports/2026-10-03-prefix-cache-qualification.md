# Prefix-cache candidate qualification

> Last updated: 2026-10-03

## Scope

These are local candidate measurements and regression results, separate from
the [nine-model production baseline](2026-10-03-openrouter-cache-throughput.md).
Parent baseline is `48d2be458b3ce511a2a9006238b923295c9c6718`.
SDK baseline is `1ee8675a035d0d842d5df663938d66cfedf88a8e`; broader upstream
model changes are kept outside the tested dependency cut.
Host: Apple M4 Max, 16 CPU cores, 128 GiB RAM, macOS; Rust 1.88 release and
Swift 6.3.3. No production deployment or configuration change is included.

All native timing fixtures use authenticated encrypted segments and an ephemeral
test key with `strictFsync=false`. Write completion and store/engine restarts do
not establish fsync durability or a cold physical-disk restore. Physical storage
versus the OS file cache is not separately measured.

## Retaining the demanded recurrent fork

The native opt-in `Qwen35AdjacentCheckpointLiveTests.adjacentDemandedForkBeforeAfter`
uses cached `EigenLabs/Qwen3.5-9B-MLX-4bit-mtp` weights, production paged serving,
embedded MTP, an isolated encrypted SSD store and a 1,024-token test stripe.
Weight SHA-256 is
`127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b`.

A 7,136-token donor publishes complete checkpoints at 1,024, 5,120 and 6,144.
The 5,776-token fork shares 5,145 tokens with the donor. The test removes the
5,120 file to reproduce the old publication outcome, restarts the store/engine,
then restores that same file and repeats the fork after another restart. This
isolates checkpoint availability; it is not a separate old-binary benchmark.
A cache-disabled run uses the same fork.

| Condition | Restored tokens | TTFT, seconds | Checkpoint bytes read |
|---|---:|---:|---:|
| Old publication outcome | 1,024 | 7.0151 | 93,492,672 |
| Retained demanded fork | 5,120 | 1.1652 | 261,324,896 |
| Cache disabled | 0 | 9.2193 | 0 |

All three return exactly `BRONZE-913`. The candidate saves 4,096 additional
prefill tokens and reduces TTFT by 83.4% in this one controlled sample.
The extra checkpoint has 261,246,972 tensor bytes and a 261,287,014-byte encrypted
file: about 63,790 stored bytes per additional saved token on the first reuse.
Its value therefore depends on reuse frequency and restore cost; this is not
a fleet-wide cache or economic estimate. The donor's TTFT is 9.7573s and its
finish-to-DONE publication tail is 0.3517s. A second run after the modular test
refactor restores the same 1,024 / 5,120 tokens with TTFT 6.6999 / 1.0846s and
identical output; its donor tail is 0.7347s. These tails include the whole
donation and do not isolate the added file's cost.

The capture already existed before publication dropped it. Retaining the
distinct target extends its lifetime through donation; the three-position
limit and existing tensor-byte bound remain. Donation still obeys the total
write budget, free-space floor and cross-donor queue bound. Sequential
publication does not guarantee that every endpoint survives concurrent writes.
Historical-attention and recurrent native engine regressions independently
reproduce the lost fork and verify the retained target.

The encrypted fleet-write regression exhausts the novel share, then offers
6,144 / 5,120 / 1,024 with an authenticated 5,120-token demand hint. The deeper
novel extension is refused; covered boundaries use reserved repeat capacity
and remain available after reopening the store. Total-budget exhaustion still
refuses repeated writes. This corrects write classification without making
a common preamble exempt an arbitrarily deep novel suffix.

## Capturing a demanded short dense prefix

`Qwen35DemandedShortCheckpointLiveTests` uses the same native dense model and
embedded MTP, with the production 4,096-token stripe. A 2,559-token donor has
authenticated repeat demand for 2,048 tokens. The candidate inserts one range
end at 2,048, then processes the remaining 511 tokens. It publishes exactly
one checkpoint. A novel control with hint zero publishes none and retains the
ordinary partition.

Three sequential local runs use fresh isolated stores. The table gives median
TTFT across those runs; all measurements are retained.

| Condition | Median TTFT, seconds | Restored tokens |
|---|---:|---:|
| Cache-disabled donor | 3.2710 | 0 |
| Novel donor, no extra boundary | 3.3589 | 0 |
| Demanded donor, one boundary | 3.4730 | 0 |
| Warm divergent fork | 0.9930 | 2,048 |
| Cache-disabled fork | 3.8717 | 0 |

The 2,708-token fork shares 2,077 tokens with the donor. Warm/cold fork output
is exact in all three runs, as is demanded/novel/cache-disabled donor output.
The median per-run warm TTFT reduction is 74.35%; the demanded donor's median
paired overhead is 0.1582s / 4.78% versus the novel control. Its median
finish-to-DONE tail is 0.1777s. Effective prompt tokens / TTFT decreases from
761.86 to 736.83 tokens/s using the median donor times; this is a prefill/first
decode/scheduling proxy, not isolated kernel throughput or generation TPS.
The checkpoint uses 135,405,564 tensor
bytes and a 135,428,194-byte encrypted file. This benefit/cost balance applies
to measured repeat demand and does not justify capturing every short request.

The generic SDK knob defaults off. Provider qualification requires dense
`Qwen35Model`, excludes `Qwen35MoEModel`, requires paged serving and an actual
SSD store, and uses that store's unchanged minimum. The clamp also requires a
cache scope, enabled request participation, no imported prefix, text-only input
without out-of-band position state, positive covered demand and
a prompt below the armed stripe. Preempted or geometrically disarmed donors
retain their ordinary remaining range. It never raises token, byte or state-count
bounds. Scheduler and deadline projection call the same pure clamp. Focused
cases cover both enabled geometry and unchanged exclusions; a native
64-token continuation regression verifies exact continuation and checkpoint
state. Text equality in the full-model run is not a claim that every floating
point logit is bit-identical.

Independent review reproduced unnecessary two-step prefill for requests with
explicitly disabled cache participation, and for inputs with
position state that the dense checkpoint codec refuses. Matching scheduler and
projection qualification to capture eligibility preserves their ordinary
remaining prefill range. The regression exercises actual scheduling and projection,
including requests that have already entered the running queue.

Further review reproduced a useless split after actual capacity requeue and
after packed prefill permanently disarmed capture. The candidate mirrors that
monotonic veto, including an already-launched packed graph before finalization.
Only a range introduced by the new clamp stays outside its step's packed
group; ordinary cohorts keep packing. Tiny native SDK fixtures verify publication at
the protected boundary, unchanged ordinary packing, and exact generated token
IDs against the disabled-knob control. A suspension during packed execution
verifies admission charges the launched work once and preserves the observed
veto. Future ordinary packing is outside the pure projection model and can
conservatively overprice a later boundary; this is not universal future-state
parity. Protecting an
introduced boundary can replace one packed forward with singleton forwards
for that step; the measurement below does not isolate that packing cost.

## Mixed capture cost and matching reuse

A separate verification fixture uses the production factory's benchmark
construction with width three, a 16 GiB KV budget, one partial prefill and
512 / 2,048 / 4,096-token plain/base/solo limits. These are explicit fixture
settings, not a claim to use every production default. The same real artifact
loads its MTP head, but runtime MTP is disabled for this experiment. Synthetic
pre-tokenized prompts have exactly 1 / 2,049 / 2,800 input tokens and forced
3 / 1 / 128-token output lengths. Three counterbalanced pairs follow two
excluded priming cells. All six measured cells import zero tokens; paired
generated token IDs match.

Hint-zero controls write nothing. Positive 2,048 / 2,311-token demand creates
four encrypted files totaling 415,840,833 bytes per cohort. In each candidate,
the introduced 512-token range shares an actual step with a same-sized nonfinal
neighbor and executes separately. Neither control nor candidate actually packs
the donor. This measures total cold capture-creation cost, including checkpoint
publication, rather than isolated packed-kernel overhead.

| Measure | Control median | Candidate median | Median paired change |
|---|---:|---:|---:|
| Whole cohort, seconds | 8.453 | 8.698 | +3.99% |
| Aggregate output tokens/s | 15.62 | 15.18 | −3.83% |
| 2,049-token donor TTFT, seconds | 3.141 | 3.806 | +21.66% |
| 2,800-token request TTFT, seconds | 5.944 | 5.996 | +2.51% |

Percentages are calculated within pairs before taking their median; they can
differ from ratios of the absolute medians. Aggregate output TPS divides the
132 actual output tokens by whole-cohort elapsed time, including prefill.
The one-token donor output makes its TTFT cost particularly visible. Setup and
post-request write completion are retained separately. Candidate-first controls
can see prior files in the census but still import zero and write zero files.

A separately seeded, single cold-then-warm fork uses the same MTP-off factory
settings, one active 2,300-token request and 128 forced output tokens. Actual
SSD staging and native import restore 2,048 tokens and read 118,662,460 bytes,
without blocker hooks or restore overrides. TTFT falls from 2.589s to 0.382s
(85.25%), including 42.90ms staging; whole-request elapsed falls from 5.075s to
2.866s. Output IDs are exact. Decode-tail TPS is 51.14 / 51.17; end-to-end
output TPS is 25.22 / 44.66. This is one functional pair, kept separate from
the three cold cohorts and earlier MTP-on aggregates. It demonstrates matching
reuse, not general fleet payback, burst endurance or peak RSS qualification.

## Bounded planner reuse

The ignored `planner_performance` test compares independently built baseline
and candidate executables using identical local Gemma QAT, Qwen 3.5 and
GPT-OSS templates/tokenizers. Two counterbalanced rounds measure 250 plans per
short/tool/~6.7k-token cell, 50 per ~53k-token cell, and 128 mixed batches of
16. One planner runs per process; allocation instrumentation is disabled
during bursts. No model inference or network request occurs.

| Template | Short allocation calls, before → after | Mean of two short p50s, µs, before → after | Mean of two tool p50s, µs, before → after |
|---|---:|---:|---:|
| Gemma | 2,367 → 534 | 247 → 40.5 | 780.5 → 421 |
| Qwen | 1,853 → 929 | 113.5 → 47.5 | 857.5 → 699 |
| GPT-OSS | 3,225 → 1,718 | 243.5 → 67.5 | 726 → 507.5 |

All 12 complete `PlanResponse` fingerprints match across both versions and
rounds. Allocation counts include allocation/reallocation calls; cumulative
requested bytes are not peak live memory or RSS. Short counts fall 46.7–77.4%.
Timing has visible scheduler variance. Long plans remain dominated by
tokenization: Qwen's ~53k-token median worsens from 30.900ms to 32.575ms in
the two-round mean. Some mixed-burst p95s and process RSS are worse. There is
no established general burst, RSS, production TPS or planning-failure-rate win.

Compiled variants belong to the existing bounded contract LRU, with at most
two programs per contract and a 64 KiB UTF-8 source retention cap. Larger
sources compile ephemerally under the unchanged eligibility/limits. Active
owners can finish after eviction, so this is not a hard RSS quota. All checked
fleet templates fit; the largest locally measured template is 17,466 bytes.
Concurrent dates, self-imported macros, plain/tool variants, model filters,
fresh fuel/output budgets, oversized fallback, eviction and fixture/production
proof parity have regression coverage.

## Correct first-content deadline accounting

The isolated HTTP/WebSocket regression reproduces a false `deadline_unreachable`
429: a forecast uses 5,779 exact tokens while the SLA duration still uses a
3,606-token heuristic. The baseline duration is 12.606s; the corrected duration
is 14.779s, both measured from the same original ingress. The candidate returns
200 with unchanged physical token reservation and output limit. The four
consumer endpoint families are exercised in stream/nonstream modes.

The alias regression uses a qualified 11.32s forecast and a fallback policy
of 14s versus the original model's 500ms policy. Baseline incorrectly refuses
the candidate; current code applies the candidate cutoff. Tests preserve an
earlier caller deadline, planning time already spent, account exemptions,
public alias policy and stale/malformed/calibrated fallback. This fixes SLA
accounting; granting the correct token term is not a measured TTFT reduction.

## Existing SDK paging failures

The complete SDK run on the candidate based on the original pin exposed five
existing work-reservation cases with seven assertions, outside the new
scheduling/capture paths. Two small fixes
are already merged upstream: [#209](https://github.com/Layr-Labs/mlx-swift-lm/pull/209)
lets expected native refusals reach their test callers instead of recording a
failure inside `XCTUnwrap`; [#210](https://github.com/Layr-Labs/mlx-swift-lm/pull/210)
materializes broadcast direct KV as a full contiguous destination, preserving
raw bit values, ownership validation and reservation bounds.

The same full run exposes 36 absent-native-lane failures and three stale MiMo
expectations, addressed by upstream [#192](https://github.com/Layr-Labs/mlx-swift-lm/pull/192)
and [#211](https://github.com/Layr-Labs/mlx-swift-lm/pull/211): unchanged opt-in
conditions report skips, and assertions match contracts already present on the
original pin. Required selected native suites still run with actual fixtures.
Thirty-nine untouched DiffusionGemma FP32 issues are frozen-reference low-bit
differences on this GPU/compiler. Upstream
[#174](https://github.com/Layr-Labs/mlx-swift-lm/pull/174) separates the reference
comparisons from hardware-independent ownership/cache/shape checks. References
and tolerances remain unchanged; reference-hardware comparisons are explicitly
unrun on this host. New cache/native/Qwen comparisons remain ungated.

The later full run reproduced upstream [#175](https://github.com/Layr-Labs/mlx-swift-lm/pull/175):
the historical-window cap test undersizes its request by subtracting physical
pool overhead that a request's target KV can replace. Reused allocator buffers
can leave enough slack for the supposedly oversized uncapped request. Its
precise test-only backport sizes the request with real reserve/release probes;
all cap and refusal assertions remain. The failed run used 1,043,808 tokens.
The corrected required no-skip case used 1,044,512, with three capped windows
admitted and nine uncapped windows refused. The complete SDK run also passes
with allocator history present and an actual-probed 1,045,472-token request;
these different accepted sizes confirm why the probe must use the ledger.
Production quota code is unchanged.

These six isolated backports do not upgrade the newer model inventory. The
compatible dependency cut is `58d538c8a9668f72a2702d5bb348e0e53a8cdf61`;
the [SDK integration PR](https://github.com/Layr-Labs/mlx-swift-lm/pull/289)
keeps that cut as an ancestor while merging the feature into current upstream.
The final cut passes the full SDK (1,595 XCTest cases with 334 expected
opt-in/reference skips; 1,422 Swift Testing cases) and provider suites
(553 XCTest cases with 125 expected skips; 3,696 Swift Testing cases plus seven
required isolated runs), as well as all required selected native/ownership/cache
suites with zero skips. Frozen FP32 reference comparisons remain unrun on this
host. All six staged metallib copies match the compiled nested MLX source.
[Validation evidence](evidence/prefix-qualification-2026-10-03/validation.json)
records commands, toolchains, skips and exact dependency provenance.

The earlier adjacent-fork and solo short-prefix timing aggregates were
collected before the backports; they measure capture changes. The mixed cold
cohorts and separate MTP-off warm fork use the final dependency cut. Separate
final-cut MTP-enabled functional verification repeats the
adjacent experiment (1,024 → 5,120 restored tokens, 6.309 → 1.017s TTFT) and
short capture (2,048 restored tokens, 0.968s warm versus 3.741s cold), preserving
exact text with MTP enabled. These two cells are retained in validation evidence
and do not change the earlier timing aggregates.

## Evidence and reproduction

[Planner CSV](evidence/prefix-qualification-2026-10-03/planner.csv) retains every
final-round cell and burst. [Planner JSON](evidence/prefix-qualification-2026-10-03/planner.json)
also retains process peaks. [Native measurement](evidence/prefix-qualification-2026-10-03/qwen-adjacent.json)
records both measurements of the paired archive experiment.
The [short-prefix measurement](evidence/prefix-qualification-2026-10-03/qwen-short.json)
retains all three native donor/fork comparisons and their declared aggregates.
The [mixed measurement](evidence/prefix-qualification-2026-10-03/qwen-mixed.json)
retains all six cold cells, three paired comparisons and the separate warm pair.
Its [verification-only source](evidence/prefix-qualification-2026-10-03/qwen-mixed-benchmark.swift)
can be temporarily admitted to the native test target for reproduction; it is
not part of the default test suite.
These contain public model identifiers,
synthetic measurements and fingerprints, with no credentials or private request
content. Run instructions are in [developer testing](../developer/test.md);
native tests require cached weights and their explicit opt-in environment flags.
Required component checks and remote review results are reported in the PR.
