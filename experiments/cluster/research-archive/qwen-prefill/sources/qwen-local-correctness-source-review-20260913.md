# Local correctness source review and first-layer GDN diagnostic

2026-09-13; source-only review of `/Users/developer/DarkbloomDev/d-inference`. No code implementation, native build, MLX/GPU execution, or performance claim. The earlier `qwen-tp-arithmetic-and-layer-pipeline-20260913.md` is unchanged.

## Guard review

No new material accepted bypass found in `LocalCorrectness.swift`, `LocalCorrectnessCheck.swift`, `VerifiedCheckpoint.swift`, `DirectShardLoading.swift`, or `LocalCorrectnessStorage.swift`.

* Admission remains explicit real, one-shot, two-rank loopback `ffn-tp`; persistent workers and unrelated diagnostic modes cannot enter through this opt-in. Existing false/nil defaults retain their prior behavior.
* Actual prompt/teacher files are bounded before parsing; `validateWorkerJSON` rejects fraction/exponent integer syntax, and `[Int]` decoding rejects strings/booleans. Parsed arrays and bounded configuration bytes are retained and reused, rather than re-reading mutable token files after admission.
* Configuration preflight checks dense family, a valid nested object when present, nonboolean integer vocabulary/context/expert metadata, actual token ranges/counts, context and capture bounds. The original retained configuration hash is rechecked and bound to the verified config file.
* The opt-in manifest read is bounded to 4 MiB+1, with >4 MiB rejected before decoding. Expected aggregate and total payload<=8GiB are checked before payload file hashing. Full per-file SHA256 and the aggregate are still verified; descriptors remain pinned, and final modification checks remain after loading.
* Canonical dense storage is independently recomputed against the ordered commitment before selected tensor reads: source<=6GiB, each rank<=4GiB, both ranks<=8GiB, largest host tensor<=512MiB. Unsupported composed expert tensors are rejected. These are payload/copy limits, not a whole-process RSS guarantee; model metadata/initial construction and required verification happen earlier.

The CPU fixtures exercise malformed admission, changed input retention, source/rank/host limits, forged/reordered commitment counters, an oversized manifest with its payload absent, wrong expected aggregate, capped payload, actual content hash mismatch, and integer overflow. This review does not add execution evidence beyond the root's existing test results.

## Minimal next diagnostic

Add one isolated file, `experiments/cluster/inference/Sources/ClusterInference/QwenGDNInputProjectionCheck.swift`; the root can later add a separately bounded dispatch mode. Keep registered policy, MTP-off, same prompt/chunk and BF16 activation. One real first chunk (M32) is the first useful case; add M1 as a separately reported control only if authorized.

Capture the **output** of the first decoder's input normalization, which is exactly the tensor entering GDN's `projectInputs`. Find the unique actual module path `model.layers.0.input_layernorm` or `language_model.model.layers.0.input_layernorm`, validate it is `RMSNorm`, and preserve its parameter identity/eps.

Confirmed public APIs in `libs/mlx-swift/Source/MLXNN/Normalization.swift:127–152`: `open class RMSNorm`, public `weight` and `eps`, `public init(dimensions:eps:)`, and `open func callAsFunction(_ x: MLXArray) -> MLXArray`. A diagnostic subclass can initialize with the source dimensions/eps, then `try update(parameters: source.parameters(), verify: [.all])`; its override calls `super.callAsFunction(x)`, stores that exact returned array once, and returns it unchanged. Public `Module.update(modules: ModuleChildren(values: [key: .value(capture)]), verify: [.noUnusedKeys])` installs it on the containing decoder; the existing `MoENormCapture`/`captureMoENorm` in `MoEBoundarySupport.swift:22–62` already demonstrates both API shapes. Use a dedicated capture with no peer-injection facility and fail on a second unexpected call. Keep the recorded tensor in an external plain reference holder rather than a directly reflected MLXArray property on the Module, so diagnostic retention cannot enter its parameter inventory (`Module.swift:1326`). Freeze the replaced module/model before the forward.

Do **not** evaluate, cast, make a CPU copy, or run comparison inside this override. Run the normal CBv2 request chunk unchanged. Only after normal output, every recurrent evaluation root, every KV/device-offset root, error check and state commit have completed (`CBv2RequestSession.forward`), explicitly evaluate/inspect the captured array. Require exactly one capture, the expected `[1,M,H]` shape, dtype, and finite values. This avoids changing forward evaluation order or missing lazy state effects.

Leave all four GDN input projections untouched. `Qwen35.swift:377–402` requires their exact concrete type to be `QuantizedLinear`; subclassing those modules would disable the fusion being investigated. Replacing input RMSNorm does not participate in that eligibility predicate.

After the normal forward, obtain the first GDN's named qkv/z/b/a QuantizedLinear modules (fusion may already have replaced them with views into its shared allocation). Reconstruct a plain frozen QuantizedLinear by concatenating stored packed weights/scales/biases in exact `[qkv,z,b,a]` order, matching `Qwen35.swift:414–519`. Build each local projection by independently copying `QwenGDNPartition` selections from each original triplet **before** concatenation. A naive contiguous half of the fused matrix gives the wrong semantic segments.

Run full and both local projections on the SAME evaluated captured normalized tensor, without input conversion, output widening, or dequantization. Compare corresponding Q/K/V/z/b/a segments, recording input/source/selection hashes, M/K/N, dtype, exact/maximum/RMS errors and BF16-step differences. Keep these diagnostic outputs outside throughput reporting. The actual private `fusedInProj` output cannot be captured through public APIs: accurately label this as a reconstruction of the production fused operator, using an actual-forward captured input, not direct tracing of its private output.

A cheaper supplementary oracle can use public `scaledInputEmbeddings` followed by the actual first RMSNorm, since no prior layer or cache affects that input. Label it isolated input reconstruction; it is not a capture from the normal forward. Neither approach establishes the cause of whole-model divergence until the matching numerical experiment runs.
