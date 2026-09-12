# Qwen3.6 candidate: ordinary paged control and SSD restoration

> Last updated: 2026-09-06 · commit `2eebb5412`

The current release candidate passed two separate bounded B1 checks on the exact Qwen3.6 MXFP8 artifact. Ordinary generation with MTP and SSD disabled produced identical complete outputs with contiguous and paged attention. Normal MTP generation with paged attention and SSD enabled exactly matched the retained paged cache-off run, including actual prefix restoration, tenant isolation and cancellation recovery.

Both checks used the reviewed candidate runtime (engine SHA256 `cc86a3328be98a498ea0dad077c7a6fd64add25aabe5ac7d9cba78bc93a11568`, source manifest `e7b769e2713e48c53fb62fbe74e449bb409c8fc1b7e5f036b14e808a7c3da3f5`) and model aggregate `d932e96b00404b0575fff47e2dac8ed113056b3f22d0040c3c8d3f9ef25b09ed`. Full runtime, input, report and ownership receipt identities are in the [evidence](evidence/qwen36-candidate-controls-2026-09-06/evidence.json). No production source was changed for these checks.

The target-only pair (112) emitted 78 tokens for the long request on both backends. All eight complete trajectories matched. At zero-based output position 53, the diagnostic captured identical BF16-derived candidate scores 27.25 and 27.125, the same chosen token, width 1 and cache offset 5575, with no NaN or infinity. Diagnostic timings are excluded from performance claims.

The independent SSD arm (113) executed once against retained earlier cache-off evidence; its baseline was not rerun or relabeled. All eight complete trajectories matched exactly, including the 83-token long response, warmup, tenant checks, completed cancellation donor and recovery. The intentionally cancelled request matched the required prefix and stopped after 5 tokens. Long-repeat, same-tenant repeat, cancellation and recovery each restored 4096 tokens; the other tenant missed. The store reported 4 authenticated stage consumptions, 16,384 consumed prefix tokens and 660,564,124 bytes read, with zero corrupt drops or dropped writes. Live cache status was ready, resident caching was disabled, and normal MTP was active for 222 rounds.

One observed long-repeat TTFT was 0.420 s with SSD versus 1.285 s in the retained cache-off baseline. This is a single descriptive observation, not a performance release gate. All request and KV reservations drained, source/model/runtime audits before and after matched the retained earlier audit byte for byte, and the owned processes retired cleanly. The post-shutdown cache status reports `cache_init_failed` because the existing status function maps a closed store to that value; live requests remained ready and successfully restored. The full remote archive and ephemeral SSD payload remain intact. A large first archive transfer timed out; its partial local file was preserved, and the selected reports/receipts were then collected and verified against the full remote evidence manifest.

The 78-token target-only response and 83-token normal-MTP response used different verification geometry. Their difference alone does not demonstrate cache corruption or a quality defect. These results do not rewrite the earlier normal-MTP backend comparison. They establish this ordinary B1 backend control and this normal-MTP same-paged SSD restoration case only: no other models, B2/B4, default HTTP settings, routing winner selection, broad quality or release-wide acceptance are claimed.

This projection excludes prompts, complete generated text/IDs, model tensors, binaries, cache payloads and provider configuration.

Related: [kernel precision cases](2026-09-06-qwen36-candidate-d256.md), [normal-MTP backend observation](2026-09-06-qwen36-candidate-logits.md).
