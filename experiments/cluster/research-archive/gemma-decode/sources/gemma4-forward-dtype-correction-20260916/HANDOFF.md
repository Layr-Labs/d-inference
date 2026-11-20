# Gemma source/native dtype correction — 2026-09-16

The actual Foundation failure is a runtime metadata bug, not a ledger-fixture error. `LayerStageTensorLayout` retains raw safetensors dtype strings. The frozen forward and resource code instead compared several of those values with MLX dtype descriptions. Both original failed runs and the `92a7` forward / `a7d2` resource packages remain unchanged.

The diagnostic reported 1,912 named arrays / 1,658,991,464 bytes instead of 2,564 / 4,813,046,632. The entire difference is 652 omitted casts: 3,061,780,480 persistent bytes plus 92,274,688 tied-head transient bytes. The independently derived ledger and the complete original `Gemma4ShortBudgetCheck.swift` remain byte-exact.

| Raw source label | Native source name | Loaded parameter name |
| --- | --- | --- |
| U32 | uint32 | uint32 |
| F32 | float32 | float32 |
| F16 | float16 | bfloat16 |
| BF16 | bfloat16 | bfloat16 |

`Gemma4ForwardDType` supplies one explicit projection. Selection binds it once; source verification and materialization compare native source names; constructor validation distinguishes packed uint32 from supported floating parameters; the loaded-layout fingerprint uses native loaded names; the resource budget charges the projected 16-bit parameter casts. Unsupported/native-spelled raw labels are refused. These projections do not establish activation, residual, or KV dtype.

The captured artifact has 1,370 BF16 and 327 U32 descriptors, including excluded vision; selected text has 1,013 BF16 and 326 U32. The separate F16/F32 vectors exercise the parser contract without expanding the sealed artifact admission. Raw metadata/Plan/storage identities, mapping, quantization selection, actual probe/session dtype checks, ordered post-autoreleasepool completion, Qwen sources, and 6/4/2 GiB resource policies remain unchanged. The native parameter-layout fingerprint is intentionally corrected; no previous actual Gemma load receipt exists.

Apply `integration.json` after both predecessor overlays. It contains five replacements and one new Runtime file. `runtime.patch` and `tests.patch` are reviewable separately. No MAIN edits or native execution occurred.

Run read-only validation:

```sh
python3 -B /Users/developer/DarkbloomDev/cluster-research/gemma4-forward-dtype-correction-20260916/verify.py
```

After the root grants its compiler slot, run the corrected 36-source Foundation closure:

```sh
python3 -B /Users/developer/DarkbloomDev/cluster-research/gemma4-forward-dtype-correction-20260916/run.py --output /Users/developer/DarkbloomDev/cluster-research/gemma4-short-resource-root-review-20260916/foundation-corrected-1
```

The runner reuses the exact failed compile argv plus four explicit replacements and two additions, and the existing qualified unreaped-process helper. Bounds remain 60 seconds compilation / 10 seconds fixture, jobs 2, fresh output/cache, source checks before and after. It retains all old metadata/Qwen controls, all 29 cut mappings, all independent named-array vectors, per-array rounding checks and ordered-load failures. New cases check raw/native labels, constructor-class refusals, all captured descriptors, all 652 casts, and preservation of raw source identity.

Foundation execution validates metadata arithmetic only. Actual MLX descriptor/materializer/constructor type checks and real Gemma probe/forward remain pending the corrected native build and root-owned guarded runs. No MoE whole-process peak or serving qualification is claimed.
