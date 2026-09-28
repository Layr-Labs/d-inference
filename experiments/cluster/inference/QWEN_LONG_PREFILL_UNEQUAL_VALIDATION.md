# Unequal 8K Qwen stage comparison

> Last updated: 2026-09-14 · commit `e4df336bc`

The registered Qwen3.5 9B model passed an 8,192-token comparison with a 12+20
layer split, first within one process and then across two serial loopback
processes. Final state metadata and digests, the final logit digest and the
selected token matched a fresh full-model reference. Both checks used one
M4 Pro GPU; physical cluster throughput remains unmeasured.

## Workload and result

The [pair command](QWEN_LONG_PREFILL_PAIR.md) used 8,192 prepared prompt tokens,
chunks of 512, one output, no teacher tokens, one repetition and no warmups.
The full model completed all sixteen chunks and was released before either
stage loaded. Its reference carried the selected 12+20 plan identity.
The stages used the existing CBv2 full-width arithmetic, BF16 weight policy,
attention query block 128 and TF32 setting 1.

| Quantity | First stage | Second stage |
| --- | ---: | ---: |
| Global layers | 0–11 | 12–31 |
| Active text tensors | 348 | 579 |
| Active text tensor bytes | 2,032,294,848 | 3,005,746,752 |
| Inert replacement bytes | 16,384 | 8,192 |
| Final state components | 27 | 45 |
| Final logical state bytes | 119,980,044 | 199,966,740 |

The complete source inventory remained 927 tensors and 5,038,041,600 bytes.
The disjoint final state union contained all 72 components and 319,946,784
logical bytes. All sixteen residual envelope hashes and 32 stage commits
passed validation. The final BF16 logit row had shape `[1,248320]`, and the
selected token ID was 271.

The independent CPU validator reconstructed the full reference row, including
signed zeros, and checked its native-byte digest and first-index finite argmax.
The staged candidate exported logit metadata and a digest only, so this is
digest agreement rather than an independent comparison of exported candidate
bytes. State geometry, ownership, aggregate fingerprints and eight Int32 offset
components were checked independently; the other 64 state payloads and residual
payloads remained native digest commitments. No independent model forward was
performed by the auditor.

## Execution evidence

The execution host was an M4 Pro with 24 GiB memory, 14 CPU cores and 20 GPU
cores. All 45 OS memory samples reported pressure level 1 and zero swap.
Initial actual free memory was 9,416,146,944 bytes; post-hash actual free was
9,140,928,512 bytes. These observations do not establish peak process memory or
continuously available memory.

Native and SSH exits were zero, stderr was empty, the local SSH child was
reaped, and the final observation found no owned remote process. Source,
bundle, full remote artifact and raw input checks passed before and after work.
All 335 archived source files matched their retained and live bytes after
completion, including the 19-file cut extension and the subsequent solo-plan
guard. The guard closes a direct-call case before model loading; it changes
neither the pair calculation nor the default solo plan.

| Evidence | SHA-256 |
| --- | --- |
| Native executable | `705013e1e7f706c1ced164dbd37c7e6887a8caf43e8bd176a9cdf0bbee7ddb1d` |
| Registered artifact | `127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b` |
| Selected plan | `8c3fef079cc82295d70851ef9d9193954afc0d008ad09ce239baaa1a51391fed` |
| Parent receipt | `c7145a825a6e91cbf34508e93fce22e3bb4eace906d7850713dd3aea5d928b3e` |
| Complete native stdout | `e97f9e66d19ff3d45ea549b3b9465de1d585310028a1cee153af953c20990a82` |
| Independent CPU audit | `514af75212d0a9b00b328088abc4afb5dab4f1a5c41e65db8925eeaae5d001f7` |
| Source correlation | `5ef395e61443e43807cc65f74b7dd38cb505b4183ca30835f3207fc86400b240` |

The 71-test numerical validator and 23-test guarded launcher were frozen before
execution and passed unchanged. The current native build also passed all 38
adapter records. Source correlation is narrower than an independent rebuild or
complete runtime audit; remote process absence is not a remote `waitpid` proof.

## Two-process serial result

The same executable subsequently ran the two stages in separate loopback
processes with `serial_v1`, using the same 8,192-token input and 12+20 plan.
The independently frozen 90-test rank validator first replayed the complete
qualified pair checkpoint and its saved CPU result, then compared both ranks
against that reference. All sixteen frames, 32 stage commits, 204/235 scalar
actions, final state ownership and logit digest passed. The selected token was
again 271. Candidate logit and state payloads retain the same digest-only limits
described above.

Rank zero recorded 18,780,559,667 ns from the start packet through validated
first-token return, or 436.1957 prepared prompt tokens per first-token second.
This single observation includes state construction, model forwards, boundary
transfers and scalar tracing; it excludes loading and readiness. It does not
measure two-machine speedup. Both phase and owner traces subsequently passed
the unchanged independent timing validators, bound to the same stdout and
numerical result.

Both processes and SSH clients exited zero. All 23 memory samples reported
pressure level 1 and zero swap; initial actual free memory was 10,077,192,192
bytes and post-hash actual free was 9,792,913,408 bytes. Each stderr contained
only the expected loopback warning. Local SSH clients were reaped, the final
remote observation found no owned process, and source, bundle, artifact and
input checks passed. All 335 archived source files and the 20 proposal and
guard sources matched their live bytes after completion.

| Two-process evidence | SHA-256 |
| --- | --- |
| Parent receipt | `b620cfa94ea09b84222aaeaccfcb6ec8913a1b9e45bd8b1fd4385a3527ab2d8d` |
| Rank zero stdout | `d1774a707165118eab2e804fd904478510328b3f94bf9018fc0390bbbd7b8141` |
| Rank one stdout | `d068de3a99e411343158c71b6762e947df46892a7ad1f756f6bcc2630fb84206` |
| Independent CPU audit | `10b78874a22b2feb98f6c586e7258073059f51661a9dbda1f72eb34ab2523e4c` |
| Source correlation | `cba8935b123d5d7db3862c9be2d774dcf8e58312b4c22c74249031b6e963a10b` |

## Local stage timing

All four trace files were retrieved after successful process completion. The
phase records contain 204/235 events and each selected-owner record contains
eight events. The validators check event order and same-role containment; the
separate numerical result binds the selected plan, source and full request.
The archived marker code is unchanged from the earlier trace qualification.

For frame 7, covering prompt tokens 3,584–4,095, the observations were:

| Local interval | First stage, 12 layers | Second stage, 20 layers |
| --- | ---: | ---: |
| Complete stage callback | 433.405 ms | 720.546 ms |
| Graph construction | 0.616 ms | 1.049 ms |
| Root staging | 0.007 ms | 0.008 ms |
| Evaluation and existing error check | 430.924 ms | 717.993 ms |
| Validation and commit | 0.036 ms | 0.054 ms |

Across all sixteen chunks, the first stage's local preparation intervals total
7.038 seconds; the second stage's local consumption and final-selection intervals
total 11.637 seconds. These are separate local durations, not an aligned
cross-process timeline. They include existing checks and synchronization rather
than isolated GPU kernels. Unclassified gaps do not measure tracing overhead or
communication cost. Selecting a split for different machines still requires
measurements on those machines and their actual link.

| Trace evidence | SHA-256 |
| --- | --- |
| Four-file retrieval | `5c2438006cc1007b7d5effb4dc0f441542a5d337c7fcd134cd8a5704a4e410e4` |
| Phase audit | `bff3b6b182022895a2e0057f0b7225c11ee417057e1592092d24f9c3da8939cb` |
| Owner audit | `db4781b3fb415ccc61beb36d7d147d7ae060167f17476bfeff5574bf4331d007` |
| Numerical and provenance join | `db5932bce849e1b9d5afa3ea45f6bfb8eae3d4d37153da4125c95eb24745c88c` |

## Public launcher execution

The public `run_stage_checks.py long-prefill-ranks --stage-cut 12` entry also
passed a real serial run on the same 24 GiB M4 Pro. The execution Mac used the
same base commit and all five dependency commits, the copied current experimental
sources, and executable `705013e1…ddb1d`. All 109 stage tests passed on its
Python 3.9.6 installation before model execution. This run requested neither
phase nor owner traces.

The unchanged 90-test numerical validator passed against the same qualified
12+20 full-model reference. All sixteen frames, state ownership and digests,
final logit digest and token 271 agreed. Both supervisors exited zero and were
reaped; a separate post-run observation found no process carrying the owned run
path. All 336 archived sources matched their live execution-host and development
copies, including the eight runtime files of the public selection extension.

All 30 memory samples reported pressure level 1 and zero swap. Initial actual
free memory was 8,188,346,368 bytes; post-hash actual free was 7,846,494,208 bytes.
The first-token interval was 21,766,840,417 ns, or 376.3523 prompt tokens per
second. This observation is retained alongside the earlier 436.1957 result;
the runs do not establish a causal launcher or tracing overhead comparison.
A later power snapshot reported battery power at 22%, discharging, without a
recorded thermal warning. Power and thermal state were not captured throughout
the timed interval, so this is also unsuitable for throughput qualification.

| Public execution evidence | SHA-256 |
| --- | --- |
| Parent receipt | `4e8e97429fef58211fb3bbb4097782fc7de0e4301f741cfe459eb3cd97e3b5e6` |
| Rank zero stdout | `1cbfb79e10975f32e3d137515a82ab0aad4e862f65c916df12cca3345f7c5f94` |
| Rank one stdout | `82a3b3ed5447b720e1163fa0be87ec38381b10ebbb9d4e09f118c580c27e0114` |
| Independent CPU audit | `41433a19217e35667f50be4404c4dc3a3d3c01fe07a6df0cb180aa885e84c9c7` |
| Source correlation | `7c9793de543695431feb0aabc553afc286dccc41afc4d1f1c6e8f5aed6ff293f` |

These results do not qualify physical TB/RDMA, unequal lookahead execution,
other cuts, other public model-entry options, 27B numerics or M3 Ultra throughput.
Related: [short unequal checks](QWEN_UNEQUAL_STAGE_VALIDATION.md),
[candidate plans](QWEN_LAYER_STAGE_CANDIDATES.md),
[distributed goal](../../../docs/design/distributed-inference-goal.md).
