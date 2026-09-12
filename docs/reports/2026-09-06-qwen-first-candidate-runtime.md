# Qwen-first candidate builds and preserves rollback and capacity

> Last updated: 2026-09-06 · commit `56fa39501`

The Qwen-first candidate builds both release products and passes 20 focused provider/CLI suites on M5: **221 functions, 266 expanded cases, no skips or failures**. Independent source/artifact review passes nine audit groups. These are implementation and synthetic validation results, not real-model release acceptance; Qwen 3.5/3.6 backend differences and the wider execution gates remain open.

## Candidate behavior

`EngineV2KVBackendPolicy.preferredBackend` selects paged automatically only for `qwen3.5-35b-a3b`, `qwen3.6-35b-a3b-vl-mtp-mxfp8` and `EigenLabs/Qwen3.8-27B-4bit-mtp`. Other or missing IDs remain contiguous. Automatic selection stays distinct from explicit paged intent: the kill switch, version-scoped crash guard, capability vetoes, automatic failure fallback and its telemetry remain active. Benchmark call sites now propagate model identity rather than measuring a different automatic backend from serving.

SSD-on and resident-off defaults are unchanged. Review exposed an opt-in memory-accounting defect: a paged preparation could deduct a hybrid-bank budget it never installed. `EngineV2Factory.prepareProductionBackend` now validates and deducts that budget only when constructing the actual contiguous backend, including fallback. Radix resident reproduction supplies both optional configurations and leaves selection to the resolved backend. Tests cover the retained paged grant, installed contiguous bank, fallback charging and an oversized unused bank.

## Exact build and review

| Property | Evidence |
| --- | --- |
| Parent source | `56fa3950160bb9e58d6702e9b751f2b0747ae3de` |
| Native source | `f2d79145e040bbc28c6e0e355a19bc8923a70434`, unchanged |
| Swift / core / C | `9561227d55a07db29f70a78aadc5d6b5aaeb10bf` / `fab0f39f69140393b454c32d6f4bf7a9b32f9dcc` / `d4328f2d8d54d711d5419e07ab9fa2f07b512a48` |
| Native benchmark SHA-256 | `c9776abd1789294c8d4d31ce2d5ba5a0bd206af9b832071723adcebf73361255` |
| Provider SHA-256 | `b6357a04e7f293bf389bdc68e66f2a2f43a581dd62529d0d48a7c44c7a8fc62e` |
| Fresh tests | 20 suites; 221 functions / 266 cases |
| Inherited native/compiler evidence | 27 functions / 29 cases, independently verified against the exact unchanged native source; not fresh tests |
| Owned commands | All 31 exit zero and complete group cleanup |
| Independent audit | 7,392 tracked files, 13 symlink references, signed commits, actual product closures, exact dependency locks and all eight runtime files |
| Signing scope | Ad-hoc linker signatures and static verification only; no Developer ID or notarization claim |

The tests exercise actual tiny-model backend construction, dtype gates, shared owners, cache policy and usage, production wiring, reslicing/unwind, segmented grants, fallback heartbeats, CLI posture and rollback, and benchmark environment handling. Full provider/CLI test compilation also succeeds. The audit checks terminal test records rather than treating the word “failed” in a passing negative-test name as a runtime failure.

Two staging refusals are retained. A prerequisite bundle could not apply to the shallow predecessor checkout. Exact shallow captures then preserved the selected commits, but a mode check detected four documentation files with checkout permissions 0644 instead of the local recorded 0600. Every source hash matched. A bounded recovery restored only those four permissions and reverified all source bytes, modes and revisions before the build; neither failed receipt was rewritten as success.

The [evidence manifest](evidence/qwen-first-runtime-2026-09-06/manifest.json) binds the unchanged build/test metadata capsule, source and runtime reviews, raw test summary, inherited-evidence records and staging failures/recovery. Executables, binary shaders, weights, cache bodies and private keys are excluded. The prior [forward-width runtime report](2026-09-06-forward-width-runtime.md) retains the inherited native test capsule.

## Remaining release boundary

This build does not establish real-model B1/B2/B4 comparisons, numerical acceptance, long-context/co-resident admission, production-default HTTP behavior, two-host cache routing or persistent-key restart. The [Qwen-first decision](../design/qwen-first-paged-ssd-rollout.md) records the initial cohort and rollback contract. No production configuration, deployment, release registration or traffic changed.
