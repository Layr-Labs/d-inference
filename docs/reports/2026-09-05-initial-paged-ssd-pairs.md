# Initial paged SSD pairs for Qwen3.8, GPT-OSS and Gemma

> Last updated: 2026-09-05 · commit `b274e0cd6`

Three exact fleet artifacts pass one strict paged B1 cache-off/SSD pair on
M5 Max with 128GiB memory. Each restores 4,096 prompt tokens and passes output,
tenant, restored-cancellation, recovery and idle/shutdown checks. This record
establishes initial correctness evidence; repeated performance and release
acceptance remain pending.

## Artifacts and execution

| Artifact | Verified target aggregate | Prompt tokens | MTP |
|---|---|---:|---|
| EigenLabs/Qwen3.8-27B-4bit-mtp | `bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463` | 5,523 | Normal inline driver |
| GPT-OSS 20B | `61bfc04e4016a7fa487eb10e29f79360047e302487229f298da3681984aec512` | 5,472 | Off |
| Gemma 4 26B, 8-bit target | `a4722b6020adb1894c700b45ddcd58bc0e0f033abe7139f86cbbbfe60cba4eb6` | 5,418 | Normal external assistant |

Both arms use 32-token output limits, production-derived single-slot KV grants,
explicit paged storage, no resident prefix bank and the same original probe
`601bce0923cfb2e12410073fe193a08a9c73830b5afd74d7f72e2facb49be21c`.
The native commit is `aafe2069bcdeadef9250530eb511c598649c0355`.
The corrected isolated-root wrapper is
`b5166c413e72f871ff8ebe17493b4628a8f0479e9eba376b0090eb65e3db29a1`.
Fresh pre/post target hashes and actual backend/MTP observations match the
requested artifacts. Ephemeral keys and fresh owned roots isolate the tests;
these runs do not establish signed-provider persistence across process restarts.

## Observations

| Single paired observation | Cache off | SSD enabled |
|---|---:|---:|
| Qwen3.8 repeat TTFT | 6.505683s | 1.839137s |
| GPT-OSS repeat TTFT | 1.587057s | 0.527104s |
| Gemma repeat TTFT | 1.181114s | 0.504605s |
| Qwen3.8 first-request terminal tail | 0.000269s | 0.119358s |
| GPT-OSS first-request terminal tail | 0.002862s | 0.089142s |
| Gemma first-request terminal tail | 0.000243s | 0.133611s |

The SSD repeats are real hits with 4,096 matched/saved tokens. The first requests
are misses; their terminal tails include checkpoint work. Those tails are total
observations, not dedicated capture timers. The ordered single pairs cannot
establish repeated latency, decode throughput, or contiguous-versus-paged gains.

Root reran the banked strict evaluator from `437bea4fe` against all six original
reports. All three pairs pass with zero errors. Checks include exact prepared
and generated token IDs, disabled-arm zero reuse, tenant isolation, a completed
donor before restored cancellation, cancellation output as the donor's prefix,
and exact recovery output. Serial idle snapshots show retired requests/pages
and released stage/write reservations; shutdown also clears native backing and
process ownership. This does not imply zero model weights, MLX allocator cache,
RSS, or logical address capacity.

## Retained setup failures

Qwen3.8's first SSD attempt failed the entry-temperature preflight before
inference. A fresh output directory records the successful retry; the refused
attempt remains in the evidence.

Gemma's first cache-off attempt failed before requests with `mtpUnavailable`.
The supplied local assistant directory contained `manifest.json` alongside its
config and weights. `provider-swift/Sources/ProviderCore/SpecDec/SpecDecStore.swift`
(`inspectLocalArtifact`) accepts only `config.json` and safetensors files in a
local override. The extra manifest deterministically fails that inspection.
A new owned directory contains only the byte-identical config and weights;
the original three-file directory and external provenance remain unchanged.
The corrected pair passes normal preparation, binding and active-driver guards.
No target substitution, MTP disablement or production guard change was made.

The [earlier connected input package](2026-09-05-connected-cache-inputs.md)
still records the original three-file assistant path. Its two Gemma inputs need
a new frozen package revision before connected execution. The original record
and package remain unchanged.

## Evidence and remaining gates

The [manifest](evidence/initial-paged-ssd-pairs-2026-09-05/manifest.json) and
[archive](evidence/initial-paged-ssd-pairs-2026-09-05/payloads.tar.gz) contain
185 payloads totaling 6,663,091 bytes: eight raw cells including both setup
failures, exact inputs/manifests, original and strict verdicts, source drivers,
Gemma fixture proofs and source audit, a matrix snapshot, and root review.
Root verified every archived payload and all 11 assistant-audit source snapshots.
Compiled binaries and checkpoint ciphertext are excluded.

Manifest SHA-256: `f24889d4d07a939920dcfcd3c10ef1a0f185f46f32426e7b39523d06d5a8d60d`.
Archive SHA-256: `0e8ed86336dd553939098ca6cac89c5f0f0a4d0a86e5af85313ded2068fdeb52`.

Qwen3.6 still needs coherent retirement observations, and normal adaptive
Qwen3.5 still has an output mismatch. Repeated B1/B2/B4 measurements, contiguous
controls, long-context capacity/co-residency, connected HTTP features, eviction,
persistent restart and default/rollback validation remain release requirements.
Production defaults and the deferred 0.9.1 work are unchanged.

Related: [strict evaluator and Qwen3.6 evidence](2026-09-05-final-cache-evidence.md),
[benchmark procedure](../developer/test.md#prefix-cache-benchmark-validation).
