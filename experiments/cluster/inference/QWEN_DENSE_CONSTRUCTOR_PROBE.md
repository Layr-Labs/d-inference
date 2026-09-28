# Registered dense-Qwen constructor probe

> Last updated: 2026-09-14 · commit `e4df336bc`

`qwen-dense-constructor-check` inspects the actual full and compact constructors
for the exact registered 9B and 27B metadata. It verifies checkpoint files and
canonical tensor ownership without installing checkpoint tensors or executing a
forward pass. Both registered constructors and independent metadata replays
passed on a development Mac. These results establish constructor geometry and
ownership, while weight loading and numerical qualification remain separate.

The entry is isolated from the ordinary inference options. It accepts exactly
these four argument pairs, in any order:

| Flag | Accepted value |
|---|---|
| `--mode` | `qwen-dense-constructor-check` |
| `--model-dir` | Absolute path to the selected registered checkpoint directory |
| `--registered-dense-profile` | `registered_qwen35_9b` or `registered_qwen38_27b` |
| `--timeout-seconds` | Canonical decimal integer from 1 through 300 |

Cuts, prompts, traces, transport and other inference flags reject. The default
halves are 16/16 for 9B and 32/32 for 27B. This experimental entry is documented
here rather than in the legacy `Options` usage. Build the source-matched executable
and metallib as described in [the inference build instructions](README.md#build).
Place this native command inside an external process/resource guard:

```sh
env -u MLX_METAL_GPU_ARCH -u MLX_SDPA_BLOCKS \
  DARKBLOOM_CBV2_ATTN_QUERY_BLOCK=128 DARKBLOOM_BF16_WEIGHTS=1 MLX_ENABLE_TF32=1 \
  experiments/cluster/inference/.build/arm64-apple-macosx/release/cluster-inference \
  --mode qwen-dense-constructor-check \
  --model-dir /absolute/path/to/registered-model \
  --registered-dense-profile registered_qwen35_9b \
  --timeout-seconds 120
```

The [closed admission](Sources/ClusterInference/QwenDenseConstructorAdmission.swift)
requires the exact selected configuration and raw manifest before native work.
The [producer](Sources/ClusterInference/QwenDenseConstructorProbe.swift) verifies
every checkpoint file and aggregate once, then passes its verified descriptor
owner to `PreparedQwenCheckpoint`. Its new checkpoint-taking overload requires
the exact `VerifiedCheckpoint.configurationSHA256`; it does not repeat full-file
hashing. The actual sanitizer and lazy quantizer must produce the complete
[registered inventory](QWEN_DENSE_PROFILE.md). Both compact constructors then pass
the existing full-shape, quantization-remap and active/inert coverage checks.

Success emits one `qwen_dense_constructor_report` JSONL record with raw input and
artifact identities, canonical source metadata, a full constructor observation,
and two stage observations. The exact [DTO](Sources/ClusterInference/QwenDenseConstructorTypes.swift)
separates actual `constructorDType` from expected post-load source/stage dtypes.
Lazy floating constructor parameters and affine scales start as F32; installed
inactive placeholders use BF16. Stored BF16 weights have not replaced the active
defaults. Logical shape/dtype bytes are not allocation or RSS measurements.
The existing [legacy loading limits](QWEN_DENSE_LOADING.md) remain unchanged.
The separate [selected-stage entry](QWEN_DENSE_STAGE_LOADING.md) supplies live
resource admission for materialization; this constructor probe does not.

The entry owns an alarm and monotonic deadline. Native error checks, scoped random
states, weak model/file-owner release checks and final cache cleanup gate output.
Constructors and quantization create lazy graphs, but scalar/key arrays, devices
and graph metadata can allocate. Use an external process/resource guard; this
entry does not establish memory safety or turn planning reserves into permission.
No success record follows a constructor, release, native-error or deadline failure.
Provider eligibility and M3 arithmetic qualification remain separate and unchanged.
A metadata replay can check names, shapes, dtypes and mapping hashes; native release,
file hashing and source-derived execution assertions require their own provenance.

Run the separate Foundation-only fixture on macOS:

```sh
bash experiments/cluster/inference/Tests/ConstructorProbes/run.sh
```

The runner compiles 15 actual source files under Swift 6 with warnings as errors,
without linking MLX or building the inference target. It reuses the existing
`RegisteredDenseProfiles/retained-inputs.json` and shared candidate test support.
Both the standalone fixture and public runner passed 11 accepted and 41 rejected
checks covering strict mode dispatch,
selected raw identities, arithmetic-policy refusal and verified config reuse.
The actual `VerifiedCheckpoint` fixture uses a three-byte config, a three-byte
payload and their synthetic manifest in a new private temporary directory; it rejects a same-length changed configuration and
retains the old payload cap. Compiler output is removed on exit. An optional
first argument selects another reviewed production source directory. These tests
do not execute either registered model constructor or load downloaded weights.

The 9B native check verified the complete artifact and 927 canonical text tensors,
then checked the full constructor and 16/16 compact halves. An independent CPU
replay matched source identities, shape/dtype metadata, and ownership of 463/464
active tensors. The guarded process exited zero, emitted one result with empty
stderr, and released its owned process group; source and bundle pins were
unchanged. Sampled native RSS stayed below 55 MB, but full-file verification
populated the OS disk cache and reduced free memory. This is a sampled observation,
not a peak-memory guarantee. Earlier 27B attempts were refused before native
launch by the unchanged 1-GiB constructor screen. A subsequent run, after the
per-descriptor checksum cache change and with sufficient free memory, completed
with empty stderr. It verified 1,847 canonical text tensors and 32/32 compact
halves; the independent replay matched 923/924 active tensors and all observed
constructor shapes and dtypes. Its 40 resource samples recorded at most
64,143,360 bytes native RSS and at least 1,762,066,432 actual free bytes, with
unchanged reported swap. These observations do not isolate the cache change
as the cause of improvement or establish a peak-memory bound. The larger
weight-loading guard remains separate. No model forward or physical two-machine
test ran.
