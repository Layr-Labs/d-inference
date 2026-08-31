# Qwen3.5-9B (dense `qwen3_5`) validation + native inline-MTP head

**Date:** 2026-08-28 (revised 2026-08-30 after review) · **Worktree:** branch `qwen35-9b-dense` @ `origin/master` (`0e63aed`, provider v0.8.15) · **Hardware:** Apple M4 Max (128 GB, 40 GPU cores, 546 GB/s)

## Summary

- `mlx-community/Qwen3.5-9B-MLX-4bit` (dense `qwen3_5`, natively multimodal, hybrid GDN/full-attention) is **supported end-to-end by master with zero code changes**. The dense-`qwen3_5` integration shipped in #700 (Qwen3.8-27B is itself `model_type: qwen3_5`); the 9B rides the same paths:
  - advertise gate: `provider-swift/Sources/ProviderCore/Inference/EngineV2SupportedModels.swift:44-49` (`qwen3_5` in the supported set),
  - dense VLM extraction: `provider-swift/Sources/ProviderCore/Inference/EngineV2VLMTextExtraction.swift:116-165` (dense branch builds `Qwen35Model`),
  - vision prefill/tower dense branches: `provider-swift/Sources/ProviderCore/Inference/EngineV2VisionPrefill.swift:406,486`,
  - MTP funnel family predicate: `provider-swift/Sources/ProviderCore/SpecDec/SpecDecArtifactFunnel.swift:363-368`.
- No MLX-format MTP artifact existed for the 9B. The original `Qwen/Qwen3.5-9B` bf16 checkpoint ships the native one-layer head (15 `mtp.*` tensors); we built a combined inline artifact from it and measured **1.51× decode** through the production engine. An embedded 27B artifact was later built the same way from the published pair's bytes; both are published (see Follow-up).

## Verification matrix (all live, real weights from HF cache)

| Check | Result |
|---|---|
| Scan/advertise | `qwen3_5`, `is_vision: true`, `template_render_ok: true`, 6.6 GB |
| `darkbloom benchmark --sweep` (production CBv2 engine, contiguous KV, VLM extraction + parity gate) | Prefill 566 / 738 / 731 tok/s @ 128/512/2048 · Decode B=1 **45.9** → B=6 **183.6 tok/s aggregate** (30.6/seq) |
| Baseline: same sweep on `EigenLabs/Qwen3.5-35B-A3B-MLX-VL-4bit-g64` (fleet MoE) | B=1 24.5 tok/s, B=4 78.8 agg — the 9B is 1.9× faster at B=1, dense-style batch scaling |
| Standalone server (`darkbloom start --local`) | chat completions coherent; **vision correct** (red-square/blue-circle description, 2.0 s); streaming SSE TTFT 0.10 s warm; zero WARN/ERROR |
| Unit tests | `QwenVLMTargetExtractionTests` **17/17** (dense extraction, long-context solo stripe, factory acceptance); `EngineV2SupportedSetGateTests` all pass |

*(Correction: an earlier revision reported "15/15" for the extraction suite — an artifact of a truncated log pipe, not of skipped tests. The suite has 17 unconditional `@Test` cases and all 17 pass.)*

## MTP for the 9B

The 4-bit community checkpoint carries no MTP tensors (0 `mtp.*` keys), so the funnel records a fallback reason and serves target-only. To try MTP we built a combined artifact:

**Recipe** (from `Qwen/Qwen3.5-9B` bf16 + `mlx-community/Qwen3.5-9B-MLX-4bit`):

1. Extract the 15 `mtp.*` tensors from the original checkpoint (they span shards 2/3/4).
2. Convert norms: HF Qwen3.5-family RMSNorm stores `x·(1+w)`; MLX computes `x·w` — **add 1 to every norm weight** (the same conversion the target sanitizer applies at `libs/mlx-swift-lm/Libraries/MLXVLM/Models/Qwen35.swift:1605-1610`). Raw-HF norms produce garbage drafts (~0 % acceptance → 4× SLOWER than target-only).
3. Quantize the 8 linear modules to 4-bit g64 affine; keep `.weight`/`.scales`/`.biases` triplet keys. **Scales/biases MUST be bfloat16** — with float16 scales the assistant load fails and the slot serves target-only.
4. Write a `mtp-00001.safetensors` shard next to the base's shards, add the keys to `model.safetensors.index.json`, and declare in `config.json`:
   - `"mtplx_mtp": {"included": true, "prefix": "mtp.", "model_type": "qwen3_5_mtp", "block_size": 3, "shares_target_embeddings": true, "shares_target_lm_head": true}` (contract: `libs/mlx-swift-lm/Libraries/MLXLLM/Models/Qwen35MTP.swift:507-573`)
   - `"mtplx_mtp_quantization": {"group_size": 64, "bits": 4, "mode": "affine"}`
5. Serve with `[backend] mtp_mode = "on"` (at this commit `.auto` covered only the pinned Qwen3.8 id, `ProviderConfig.swift:82-93`; PR #777 later changed the policy — see Follow-up).

**Results** (identical request, 256 tokens, temperature 0, standalone server):

| Configuration | tok/s | Note |
|---|---|---|
| Target only (MTP kill switch) | 47.9–48.5 | baseline |
| MTP on, raw-HF bf16 head (norms not +1'd) | 12.4 | engaged but drafts garbage → 0 % acceptance, 4× slower |
| MTP on, 4-bit head, fp16 scales | 47.6 | assistant load fails; slot serves target-only (see below) |
| MTP on, 4-bit g64 head, bf16 scales, +1'd norms | **73.1–73.4** | **1.51× vs baseline**, stable across runs |
| MTP on, bf16 head (raw linears), +1'd norms | **78.6–79.8** | **1.63× vs baseline** — draft precision buys ~8 % back |

**fp16-scales failure attribution** *(corrected after review)*: the funnel only structurally validates the artifact; the failure occurs in the assistant **loader**, whose catch path records the fallback reason and logs `mtp: model=… fallback reason=…` at warning level (`provider-swift/Sources/ProviderCore/Inference/EngineV2SlotFactory+MTP.swift:161-168`). It is observable there and in the slot's configured/active/reason posture — the original claim of a "silent funnel fallback" misattributed both the stage and the observability (the warning was in the server's logs; we grepped the wrong server instance).

**Draft precision tradeoff:** 4-bit quantizing the head costs ~8 % of the MTP speedup in exchange for 3.5× smaller resident bytes (137 MB vs 486 MB). 4-bit matches the published EigenLabs convention and the resident budget slot sizing charges (`SpecDecLimits.residentEstimate`).

## OPEN VALIDATION ITEM — greedy token parity

The engine's MTP contract requires target-authoritative greedy acceptance: "A drafter token is emitted only when it equals that target result" — top-k and relaxed acceptance are explicitly out of scope (`docs/architecture/gemma4-cbv2-mtp.md:183-199,344-352`), and the Qwen3.6 production canary asserts exact emitted-token-ID equality between target-only and MTP bundles (`provider-swift/Tests/ProviderCoreTests/Qwen36ProductionCanaryTests.swift:248-259`).

Our validation compared MTP-on and MTP-off outputs across **two separately started server processes** and observed one divergence at ~char 335 of a 256-token greedy request (both continuations coherent; `DARKBLOOM_MTP_MAX_RECTANGULAR_TOKENS=0` did not change the MTP output). An earlier revision of this report explained this away as "top-two acceptance semantics" — that explanation was wrong: the contract admits no such relaxation. The divergence is an **unresolved finding**: candidate causes are cross-process/batch-shape numeric differences in the target forward (which the same-process canary methodology is designed to exclude) or a real acceptance defect for this artifact.

**Gate:** before fleet/registry rollout of the 9B (or 27B) embedded artifacts, run a same-process token-parity check in the `Qwen36ProductionCanary` style (`run.tokens == targetTokens`, acceptance > 0, rejection exercised) against the embedded checkpoints. HF publication of the artifacts is a model release and is not gated on this; darkbloom fleet MTP is.

## Fleet notes *(corrected after review)*

- Serving the 9B on the network requires no coordinator/provider code changes: publish + register. There is **no per-model provider-version floor** in the registry (`coordinator/store/interface.go:610` `ModelRegistryEntry` has no such field; `register-model.yml` exposes none). None is required for routing correctness: providers advertise only models their `EngineV2SupportedModels` set accepts, and the coordinator routes by advertised models, so pre-#700 providers simply never advertise dense `qwen3_5` (`provider-swift/Sources/ProviderCore/ProviderLoop.swift:512-521`). The only enforced version knob is the global `EIGENINFERENCE_MIN_PROVIDER_VERSION` (`deploy/environments/prod.env:23`, currently `0.7.5`); raising it is a human-approved prod config change and is fleet hygiene, not a correctness requirement.

## Worktree build gotchas

- `git submodule update --init` is not enough: `libs/mlx-swift` has **nested** submodules (`Source/Cmlx/mlx`, `Source/Cmlx/mlx-c`) that must be initialized or the build fails on `no_jaccl.cpp`.
- `scripts/fetch-metallib.sh` once per worktree. For `swift test`, MLX-touching suites self-heal via `LiveInferenceFixtures.ensureMetallibColocated()` (`provider-swift/Tests/ProviderCoreTests/LiveInferenceFixtures.swift:89`); at this commit `QwenVLMTargetExtractionTests` did not call it and needed the metallib manually colocated with the test runner (fixed by adding the fixture call in PR #777).
- The standalone server takes a machine-wide media-serving lock — one `darkbloom start --local` per box; a second instance displaces the first.

## Follow-up

PR #777 reoriented the MTP policy after this report: `.auto` now activates exactly the Qwen-family checkpoints that **declare an embedded head** (`mtplx_mtp`), the external Qwen3.8 head resolver was deleted, and embedded artifacts were published to HF as `EigenLabs/Qwen3.5-9B-MLX-4bit-mtp` and `EigenLabs/Qwen3.8-27B-4bit-mtp` (the 27B built byte-identically from the pinned pair `Qwen3.8-27B-4bit@301e9e27` + head `@329261c5`).
