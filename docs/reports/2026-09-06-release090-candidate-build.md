# 0.9.0 correctness candidate build and focused tests

> Last updated: 2026-09-06 · commit `2eebb5412`

The combined correctness candidate builds both optimized executables and passes eight focused provider suites on M5 Max. This record establishes build and regression-test results; full-model comparisons and release acceptance remain pending at this checkpoint. The binary still carries the existing version metadata, not a published 0.9.0 release.

The candidate combines FP32 intermediate storage for two-pass contiguous SDPA, matching generated Metal sources and distinct kernel names, exact-model paged/SSD activation defaults, and serial target verification for explicitly enabled Gemma QAT MTP. Default-auto Gemma remains ordinary target-only. Paging defaults cover five artifacts; SSD defaults cover only the three Qwens.

| Suite | Framework-reported tests |
| --- | ---: |
| SDPAPartialPrecisionTests | 3 |
| EngineV2KVBackendPolicyTests | 8 |
| PrefixCachePolicyTests | 14 |
| PrefixCacheLoadHashTests | 5 |
| WeightHashCacheEligibilityTests | 5 |
| EngineV2KVBackendGateTests | 40 |
| ProviderMTPFactoryTests | 14 |
| EngineV2BenchmarkMTPVerificationTests | 4 |

All 93 reported tests pass without skips. The three SDPA tests contain 50 analytic subcases covering cancellation, overflow, FP16/BF16/FP32, supported dimensions, block counts, masks, sinks and transposed multi-query layouts. Parameterized Swift tests may expand into additional cases; the table retains the framework summary counts.

The fresh metallib inventory has 39 renamed FP32-partial two-pass SDPA functions and 18 unchanged one-pass functions, with no old two-pass aliases. Canonical SwiftPM builds produce both `radix-engine` and `darkbloom`; manual object linking is not used. Independent review matches 1,311 test-graph source files and 1,047 source files in each optimized product graph against the integrated tree. Each build uses 36 exact clean dependency checkouts and unchanged dependency locks.

| Artifact | SHA-256 |
| --- | --- |
| Declared source manifest v2 | `e7b769e2713e48c53fb62fbe74e449bb409c8fc1b7e5f036b14e808a7c3da3f5` |
| Runtime artifact manifest | `4816dd430cead8b26aaafa6a31d87c49697e3f43f025224bd96a3f7896d7685c` |
| radix-engine | `cc86a3328be98a498ea0dad077c7a6fd64add25aabe5ac7d9cba78bc93a11568` |
| darkbloom | `a98b9a83a69ab90a59010437f2a567341d7f8a98853a83cab8deea1043540433` |
| mlx.metallib | `20972c37e53fe6db3b3191a0434f6604c4ffc4f5ac62b370574f9922585b0fdb` |

Source identity is the declared Git bases plus reviewed overlays, not a clean-commit claim. Parent base is `2eebb5412`, native `f2d79145`, Swift `9561227d`, core `fab0f39f`, and C wrapper `d4328f2d`. The independent source review checks all 7,474 manifest identities, including 7,440 unchanged files against their exact Git blobs. The v2 amendment corrects one new test initializer to pass an MLXArray scalar; it changes no runtime source, shader or assertion.

Two failed attempts remain retained. The first test build found that scalar initializer compilation error. A later optimized build stopped when its external caller heartbeat expired; its process group retired cleanly. The release-only resume then built both products from the same reviewed v2 source. All final execution groups retired; collection observed no owned or foreign jobs. These attempts are not model failures or extra successful tests.

The [evidence manifest](evidence/release090-candidate-build-2026-09-06/manifest.json) and [capsule](evidence/release090-candidate-build-2026-09-06/payloads.tar.gz) contain six metadata records, including the independently reviewed runtime/source identities and a filtered SDPA inventory. They exclude executable packages, weights, cache contents and credentials. Full local build evidence is retained under `/private/tmp/darkbloom-release090-correctness-runtime2`.

Next acceptance work must use these exact binaries and colocated resources. Kernel tests do not prove Qwen whole-model token parity, SSD restore equivalence, concurrent model widths, default HTTP behavior, sustained performance or release readiness. The [Qwen operator diagnosis](2026-09-06-qwen36-sdpa-partial-precision.md) and [Gemma verifier diagnosis](2026-09-06-gemma-qat-state-fork.md) provide the preceding numerical evidence.
