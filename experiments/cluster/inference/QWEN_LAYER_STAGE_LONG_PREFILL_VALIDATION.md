# Long-prefill foundation and tiny native validation

> Last updated: 2026-09-14 · commit `e4df336bc`

The explicit [long-prefill profile](QWEN_LAYER_STAGE_LONG_PREFILL.md) passed a
guarded single-process synthetic comparison at 1,025 and 8,192 prompt tokens,
both with chunk 512, in Float32 and BFloat16. Every compared native state
component and final full-vocabulary row matched its same-chunk full-model
baseline. This is a correctness result; no inference clock or throughput was
measured, and no physical or interprocess model transport was used.

## Build and pure checks

The canonical build integrated 20 source files and completed with exit 0 in
61.04 seconds. The executable SHA-256 was
`f7a221c1daed76d85e56fd4c999da27339a1524824bccad00986e0045af085eb`.
The adapter emitted 26 passing records with empty stderr, including:

| Check | Accepted | Rejected |
|---|---:|---:|
| Explicit profile/request/schedule and legacy identity fixtures | 20 | 61 |
| Fixed profiled native-check CLI admission | 1 | 41 |
| Separate Foundation-only registered budget/environment check | 10 | 58 |

The standalone budget check imported no MLX and performed no inference. It
confirmed the registered 8,192/512/BF16 estimate of 745,345,056 named bytes,
its separate 768 MiB ceiling, and rejection under the unchanged legacy 512 MiB
ceiling. This remains a partial tensor estimate, excluding model weights and
native workspaces. Arithmetic environment admission required query block 128,
BF16 conversion and TF32 to be explicitly enabled, with GPU-architecture and
SDPA-block overrides absent. It did not establish registered-model memory
safety or numerical equivalence.

## Executed native matrix

The guarded process used `qwen-layer-stage-profiled-check`: an eight-layer
dense-Qwen fixture, two full-width four-layer stages, hidden width 128,
vocabulary 512, seed 7 and context capacity 8,193. Float32 used a flat source
configuration; BFloat16 used the supported text-config wrapper. The exact
deterministic prompt was `3 + ((index * 17 + 7) % 509)`. There were no teacher
tokens, decode forwards or performance warmups.

| Native dtype | Prompt / chunk | Frames | Final logical state bytes | Selected token |
|---|---:|---:|---:|---:|
| Float32 | 1,025 / 512 | 3 | 2,940,936 | 500 |
| Float32 | 8,192 / 512 | 16 | 17,618,952 | 24 |
| BFloat16 | 1,025 / 512 | 3 | 1,863,688 | 500 |
| BFloat16 | 8,192 / 512 | 16 | 9,202,696 | 24 |

The nine records comprise one environment record and, for each dtype, a loader
proof, lifecycle check and two parity records. Loader proof completed and
removed the source files before the first transformer forward. Each of the 38
parity frames compared 18 complete components, joining stage-local ownership
by original global layer index: six convolution/SSM pairs and two attention
key/value/position-offset triples. SSM state remained Float32 in both fixtures.

Native code compared the actual logical bytes of every component and all 512
final logits. The independent CPU oracle, frozen before reading this output,
validated exact profile/configuration/history identities, all frame frontiers,
component counts and byte totals, six distinct request UUIDs, four finite full
rows, native selection and retirement records. It reproduced each exported
logit SHA-256 from the full native-representable values and derived the lowest
index attaining the maximum. Each actual maximum was unique.

State byte equality is the native comparison assertion tied to inspected
source. The CPU replay validates its complete metadata/digest evidence; it
does not rerun the model or independently reconstruct unexported state bytes.
The prospective CPU suite passed 21 tests: ten runner fakes and eleven oracle
fixtures/mutations. Those tests performed no native inference.

For each dtype, an injected error followed stage zero's first 512-token commit
while stage one remained at zero. Both requests failed and retired, both
rejected reuse, and the later parity requests succeeded on the same resident
stage models. All six request identities were fresh. See
[QwenLayerStageProfiledFixtureOwners.swift](Sources/ClusterInference/QwenLayerStageProfiledFixtureOwners.swift)
and [QwenLayerStageProfiledLifecycleCheck.swift](Sources/ClusterInference/QwenLayerStageProfiledLifecycleCheck.swift).

## Resource and process observations

The unchanged guarded runner required at least 1 GiB actual-free memory before
archiving, pressure level at most 2, no increase in reported swap, a 180-second
native deadline and a 195-second parent deadline. This policy was specific to
the tiny matrix and cannot authorize a registered 9B run.

The profiled run saved 11 memory samples. Initial actual-free memory was
1,475,641,344 bytes; the minimum observed was 495,452,160 and the final sample
was 1,119,109,120. The initial 1 GiB screen was not a continuous free-memory
floor. Pressure was 2 throughout. Reported swap stayed at 14,202,899,005.44
bytes; the evidence is no newly reported swap, not an unswapped host.

Eight RSS observations had a maximum of 311,803,904 bytes. These are sparse
samples, not a process-memory peak. No MLX peak was captured. Missing RSS
observations are not zero. The process exited 0, emitted nine records with
empty stderr, was reaped, and left the owned process group empty. No cleanup
or post-run errors were recorded. The retained source manifest contains 248
files; private paths, hostnames and credentials are omitted here.

## Legacy regression: two separate outcomes

The same executable also ran the original 65/32/4 legacy matrix. Its native
process exited 0 and emitted all 11 expected records, but the unchanged parent
runner **failed** because stderr was nonempty:

```text
[bf16] converted 124 params (0.1 MB) fp16→bf16 in 40 ms
```

The intentional FP16-metadata fixture passes 124 tensors, totaling 127,168
bytes, through the existing loader's BF16 conversion. The pinned
[Load.swift](../../../libs/mlx-swift-lm/Libraries/MLXLMCommon/Load.swift)
emits this conversion line. An independent CPU supplement extracted and ran
the existing numerical checker unchanged: all legacy numerical, lifecycle and
recording/release checks passed. It preserved the failed parent receipt and
did not change the runner's stderr contract or relabel that run as successful.
All legacy request owners retired; its process was reaped and owned group
empty, with no cleanup errors. Its 11 resource samples also reported pressure
2 and unchanged swap. The profiled matrix has no FP16-metadata fixture and
passed the original empty-stderr rule.

## Retained proof identities

| Evidence | SHA-256 |
|---|---|
| Canonical foundation build checkpoint | `2e661a1c65a05bb800df6ff325d48c2e3733d59e05474d76059ed33a2e5d6219` |
| Foundation-only budget validation | `a5148ddba3df628b5f031b670ecb7d318f396ceb7c04316342895ec725a3eb9f` |
| Profiled launcher receipt | `38273111801e3ec33f0f8acd11cd604e9ff65903e624a03f3022c39acaf91376` |
| Profiled native output | `8368ae36ea29483f8b718b57091bcb5600665d4e41cf41a5d4522627425c7020` |
| Independent profiled CPU audit | `cccfa8f632fe696ad851dc7b51a0ae85c19eb301888e9f0d4bd4e5a7af5c5d51` |
| Failed legacy launcher receipt | `bacb333546eada286d2a24eda8b376f786a70fec3e72b0e994ada4b0ba2fac32` |
| Separate passing legacy numerical audit | `7fddc6e2b224c9c39501e3f71dfc6b2f6a69a9b34143bf0503ce708166aa7412` |

This evidence does not qualify registered-9B long prompts, long-profile wire
execution, Thunderbolt/RDMA, two-machine acceleration, the target 27B model,
M3 Ultra execution or the 800+ prefill-TPS goal. Same-chunk registered-model
references, independent resource admission and transport qualification remain
required. See the [profile contract](QWEN_LAYER_STAGE_LONG_PREFILL.md) and
[distributed goal](../../../docs/design/distributed-inference-goal.md).
