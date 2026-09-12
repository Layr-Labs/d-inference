# Qwen3.6 attention geometry coverage

> Last updated: 2026-09-05 · commit `b5884778b`

Thirteen new synthetic attention cases pass for Qwen3.6's head geometry and
long-context boundaries with unchanged numerical limits. The tests exercise
storage, segmented placement and independent-reference fault detection. They
change no production kernels and do not waive the observed model backend failures.

## Source and exercised geometry

Native commit `5cb848dfdaae04118ecfa901f53fc21a4aa86a06`, on diagnostic commit
`0103f249`, changes only `Tests/MLXLMTests/CBv2PagedKernelTests.swift`. Existing
fixture helpers gain defaulted dtype and segment-size arguments; their previous
FP16 defaults and the numerical oracle remain unchanged.

The validation package uses native `a932d38` plus that exact test file and the
established absolute MLX dependency overlay. All 481 owned inputs were checked
against that canonical base. Diagnostics are absent from this validation package;
the production kernel files match the later integration parent. The local test
build passed in 57.69 seconds, and root independently verified 750 compiler
source paths. No model weights or real-model inference were used.

| New function | Cases | Coverage |
|---|---:|---|
| `qwen36LongDecodeUsesIdenticalStoredValues` | 6 | BF16/FP32, 16 query heads, 2 KV heads, head dimension 256; histories 4,094 /5,523 /5,585 followed by three decode steps |
| `qwen36LongOracleRejectsBoundaryAndHeadFaults` | 6 | Salient entries at positions 4,095 /5,522 /5,523; reject missing entries, swapped GQA groups and shared 5% output drift |
| `qwen36WiderQueryDiagnosticKeepsBothReferences` | 1 | Conditional FP32 query with BF16 storage; retain both original-query and narrowed-query references |

Each backend receives identical already-rounded K/V values. The FP32 oracle
widens those values independently of backend storage. Fixed and segmented paged
outputs match bit for bit, and final snapshots retain the input bytes and native
dtypes. Four physical pages per segment force binding crossings; this fixture
does not represent a production segment-size or performance setting.

## Numerical observations and limits

The new cases retain 61 named numerical observations. Relative L2 error against
the independent FP32 reference spans these ranges for same-dtype queries and KV:

| Storage/query dtype | Paged | Contiguous |
|---|---:|---:|
| BF16 | 0.0016175–0.0016959 | 0.0023163–0.0023979 |
| FP32 | 4.76e-7–5.61e-7 | 4.59e-7–5.51e-7 |

In the conditional FP32-query/BF16-storage case, paged error against the original
query reference is 0.002369574; against the narrowed-query reference it is
0.0016781915. The two references differ by 0.001616033, while contiguous error
against the original reference is 5.2632925e-7. This demonstrates the tested
query-narrowing behavior; it does not establish the actual model query dtype or
attribute a real token divergence.

The existing limits are unchanged: cross-backend `allClose` uses `rtol=1e-2` and
`atol=2e-3`; contiguous relative L2 error must be at most `1e-2`; paged error must
be at most `max(3 * contiguousError, 1e-2)`. Planted faults exceed that bar and
100 times honest paged error. Passing these limits does not imply identical
greedy model outputs.

## Test accounting and evidence

| Complete filter | Functions | Expanded cases |
|---|---:|---:|
| `CBv2PagedKernelTests` | 15 | 49 |
| `CBv2PagedSegmentTests` | 6 | 19 |
| `CBv2PagedNativeDTypeTests` | 5 | 5 |
| Distinct total | 26 | 73 |

All pass with no skips. The targeted new-case filter also ran its three functions
and 13 cases before the full suites, making 29 function executions and 86 expanded
executions. The initial summary counted only 24 distinct functions because it
matched identifier substrings and missed two probe functions selected through
the native-dtype source filename. Raw logs already recorded all five functions
in that filter. Both frozen summaries are preserved; correcting the count changed
no source, assertion, test execution or numerical limit.

The [manifest](evidence/qwen36-attention-geometry-2026-09-05/manifest.json) and
[archive](evidence/qwen36-attention-geometry-2026-09-05/payloads.tar.gz) retain
95 payloads (4,623,408 bytes): all 14 source-freeze payloads, both validation
freezes, their manifests, both root reviews and the native commit binding.
Every archived member was rehashed. Compiled binaries, metallib, weights and
private keys are excluded; their applicable identities remain in the records.
Manifest SHA-256: `eeccaaf5744d43b9c336774557938714695c0f9a15f5a283816ceaaabe31a44a`.
Archive SHA-256: `4363d9e481c92ce0a161ddd40f30626de83a535e5e05424c74bdb508657ab3f3`.

These fixtures isolate attention and storage. They do not reproduce model
prefill, rotary state, recurrence or normal MTP verification geometry. The
[Qwen3.6 regression](2026-09-05-qwen36-backend-parity-regression.md) and
[Qwen3.5 backend failure](2026-09-05-supported-backend-groups.md) remain open.
Actual-logit diagnosis, repeated model comparisons and release/default-promotion
gates remain separate requirements.
