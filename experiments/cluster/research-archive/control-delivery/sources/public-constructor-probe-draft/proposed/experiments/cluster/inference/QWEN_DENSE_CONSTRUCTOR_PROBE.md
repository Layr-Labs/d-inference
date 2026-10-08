# Registered dense-Qwen constructor probe

> Last updated: 2026-09-14 · commit `e4df336bc`

`qwen-dense-constructor-check` inspects the actual full and compact constructors
for the exact registered 9B and 27B metadata. It verifies checkpoint files and
canonical tensor ownership without installing checkpoint tensors or executing a
forward pass. Actual native probe results are pending; source integration and
Foundation tests do not establish model loading or numerical qualification.

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
For an independently guarded run from the repository root:

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
The existing [legacy loading limits](QWEN_DENSE_LOADING.md) remain unchanged, and
registered 27B materialization remains unwired.

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
The standalone fixture passed 11 accepted and 41 rejected checks covering strict mode dispatch,
selected raw identities, arithmetic-policy refusal and verified config reuse.
The actual `VerifiedCheckpoint` fixture uses a three-byte config, a three-byte
payload and their synthetic manifest in a new private temporary directory; it rejects a same-length changed configuration and
retains the old payload cap. Compiler output is removed on exit. An optional
first argument selects another reviewed production source directory. These tests
do not execute either registered model constructor or load downloaded weights.
The public runner itself has not yet been executed; native constructor results
remain pending.
