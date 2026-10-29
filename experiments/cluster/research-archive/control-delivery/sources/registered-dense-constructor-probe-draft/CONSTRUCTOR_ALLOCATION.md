# Constructor allocation and dtype boundary

> Last updated: 2026-09-14 · commit `e4df336bc`

The inspected default constructors and affine quantizer build lazy parameter
graphs. They do not provide an allocation-free or CPU-only native probe. Source
hashes are retained in `source-dependencies.json`.

| Source | Relevant behavior |
|---|---|
| `Qwen35.swift` GDN init256, Attention init1124, Decoder init1472, TextModelInner init1583, TextModel init1754, wrapper init2166 | Dense constructors create projection, convolution, embedding, normalization and lazy scalar graphs. MTP is explicitly disabled. GDN fused-input cache begins nil. |
| `Qwen3Next.swift` gated norm init25 and dense MLP init127 | Float `ones` norm; three ordinary dense Linear constructors. No forward is called. |
| `MLXNN/Linear.swift:87`, `Embedding.swift:23`, `Convolution.swift:38` | Default random parameter graphs. `MLX/Random.swift:150,175,206,278` defaults to `Float.self`; full lazy floating parameters are F32. |
| `MLXNN/Normalization.swift:132`, `MLX/Factory.swift:93` | RMSNorm uses `MLXArray.ones`, whose default type is Float. GDN dt_bias and gated norm use the same default; A_log is log of Float random input. |
| `MLXNN/Quantized.swift:185,311`, `MLX/Ops.swift` quantized | Quantize stores returned lazy weight/scales/biases and freezes gradients. It does not cast source BF16 into the constructor. |
| `mlx/ops.cpp:5036–5100` affine_quantize | Constructs output arrays with dtypes `{uint32, w.dtype(), w.dtype()}` and a Quantize primitive. Thus F32 default weights yield F32 lazy scales/biases. The fallback body is not invoked just to construct these arrays. |
| `mlx/array.cpp:19–59` | Primitive array construction and `make_arrays` attach graph metadata and input references; they do not evaluate the parameter graph. |
| `mlx/array.h:538–600`, `MLX/Random.swift:150–220`, `MLX/State.swift:39–67` | Scalar/key arrays call the native allocator. Random bounds, keys and constants are real native allocations. Each probe constructor uses a local RandomState(seed7) so its graph is not kept by the global random state. |
| `QwenLayerStageInert.swift` | Small inactive placeholders have explicit BF16 metadata, independently of the F32 active defaults. Existing compact checks inspect this distinction. |
| `Qwen35.swift:442–443` | First eligible **forward** performs fused projection concatenation/eval. The constructor probe does not reach this path, so it cannot qualify fusion/workspace peaks or final runtime parameter layout. |
| `MLX/ErrorHandler.swift:367–380` | `withError` checks its box only after a successful body return. The probe checks it at native phase boundaries and on a secondary Swift throw, then preserves any cleanup failures. |

No `eval(model)`, TensorDescriptor/QwenCheckpointTensor.read, array value readback,
request state, prefill or materializer is reachable through the new entry. Final
stream synchronization drains cleanup work; it does not evaluate a discarded
parameter graph. Creating streams, devices, native scalar/key arrays and graph
objects can still allocate or fail. Framework metadata and retained header buffers
also consume memory. The root's small-native memory observation, timeout, process
ownership and cancellation fences therefore remain necessary; no shape-derived
sum or caller-supplied reserve number authorizes weight materialization.

Provider `ModelRuntimeRequirements.swift` still requires the registered27B exact
IDs to satisfy apple_m5 and mlx_nax. This metadata probe does not alter that policy
or establish M3 arithmetic eligibility. A backend fallback source branch is not
numerical qualification. After this probe, actual 27B loading still needs a
separate identity/role-bound resource admission, full loaded-inventory verification,
and device-specific same-source numerical qualification. The probe deliberately
stops before those operations.
