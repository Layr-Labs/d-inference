# Synthetic generation and MoE validation

The 2026-09-13 development checks establish bounded synthetic correctness on a
local M4 Max. They do not qualify an actual model artifact, two-machine RDMA,
M3 Ultra throughput, or production distributed inference.

The validation executable SHA-256 is
`73b3a63b7e7984b749d27b09d9b07db87ae490ade43df4cae311f1f040106e9c`.
All six launcher runs used runtime bundle manifest SHA-256
`c6b0e9640036fe6c78db283db901414783415ab109452aece830a4a7a489f091`.
These hashes identify the tested build; later builds need their own evidence.

## Complete dense fixture

The seeded Qwen fixture has four layers, hidden width 128, FFN width 256,
vocabulary 512, four query heads, two KV heads and attention head width 64.
Its GDN layers use two key and two value heads, each of width 128. This is a
small hybrid model, not the full head geometry or depth of the 9B/27B artifacts.

Each workload used seed 7, 65 input tokens, chunks of 32, eight output tokens,
one warmup and two measured repetitions with fresh state. The full two-rank
plan split FFN, attention and recurrent heads. A separate solo execution used
the same dtype, configuration and inputs. Loopback transport is correctness-only.

The BF16 fixture converts all floating parameters, including quantization
scales/offsets and A_log, to BF16; packed weights remain U32. The loader audits
every parameter and the embedding activation dtype. The model implementation
keeps recurrent state in FP32, separately exercised by the GDN operator checks.

The following values are the largest per-row errors across both ranks' saved
logits, each compared with the matching solo result:

| Workload | Maximum absolute logit error | Maximum relative RMS error | Argmax agreement |
|---|---:|---:|---|
| F32, autoregressive | 0.00000160 | 0.000000813 | 8/8 on both ranks |
| BF16, teacher-forced | 0.0234375 | 0.0134747 | 8/8 on both ranks |
| BF16, autoregressive | 0.0234375 | 0.0138524 | 8/8 on both ranks |

F32 passed the existing absolute-error <0.001 and relative-RMS <0.0001 gate,
with required greedy agreement. The BF16 figures are recorded observations;
this experiment does not establish a whole-model BF16 quality tolerance.
Matching eight greedy choices does not certify long-context or natural-language
quality. [GDN numerical controls](GDN_NUMERICS.md) describe separate operator
budgets and dispatch effects; they do not attribute every whole-model error.

Both repetitions produced matching selected tokens and consumed identical
histories. The reports also recorded zero rank-local argmax disagreements.
Only the last repetition's complete 8-by-512 logit matrix is saved; first-run
evidence consists of token/input traces and execution reports. Comparisons
after a divergent autoregressive history would not compare equivalent inputs.

## Coordination and model boundaries

The forced-divergence check supplied local choices `[3, 1, 6]` on rank zero and
`[5, 7, 2]` on rank one. Both selected `[3, 1, 6]` and consumed `[3, 1]` as
continuation inputs. Sequence reset, fourteen malformed-frame checks and an
invalid rank-zero token were exercised. A separate pair with F32/BF16 fixture
disagreement exited on both ranks before inference and emitted no run reports.

The native operator suite passed four attention cases, six GDN cases, six
expert-primitive cases, four Qwen MoE block cases and two Gemma decoder cases.
See [MoE partition boundaries](MOE_PARTITIONING.md) for the exact policies and
the distinction between captured router logits and CPU-derived routing oracles.
These MoE checks use local partial sums or replay, not distributed MoE execution.

## Storage regression

The expert check exposed two separate storage issues in the initial synthetic
copy helper. In the pinned MLX implementation, `copy` shares storage, and an
interior-axis `take` can return a transposed gather layout. Also, GPU completion
handlers can retain buffer references after an output event has completed.

[`copySelectedTensor`](Sources/ClusterInference/TensorSelection.swift) now gathers
fresh storage even for whole-tensor selections, materializes row-major layout,
and synchronizes the GPU before checking unique ownership, zero offset, exact
data extent and the allocator footprint bound. This is a fixture/loading path;
the synchronization is not added to model forward execution.

The reader and in-memory oracle passed 24 selections each, including the
previously failing rank-three U32 geometry, and rejected 45 invalid selections.
Ownership and values remained valid after source files were overwritten and
deleted. Both Qwen loader plans passed with F32 metadata and with FP16 layer
metadata converted to BF16, including corruption rejection on both ranks.
The full-plan loader checks storage/tensors; its complete-model comparison comes
from the separate two-process executions above.

The Python suite passed 80 tests covering launcher contracts, process cleanup,
report/selection validation, logit comparison and transport supervision. No
target-hardware performance or release milestone is closed by these checks.
