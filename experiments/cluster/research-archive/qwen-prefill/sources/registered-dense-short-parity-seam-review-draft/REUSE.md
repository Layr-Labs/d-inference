# Short registered Qwen parity: existing-loop reuse

Source review dated 2026-09-14. No model payload, candidate report, compiler, native process or SSH was accessed. The companion source pins identify the reviewed repository files and the current proposed owner overlay; this is not a native qualification.

The existing `recordQwenLayerStageBaseline` and `compareQwenLayerStageRecordedRequest` loops have no additional 9B, 32-layer or 16-layer-stage restriction. They can remain unchanged inside the proposed closed owners. This conclusion is conditional on actual loaded models passing their existing identity, layout, protocol, dtype and state guards. It does not establish 27B arithmetic correctness, provider eligibility, available memory or completion within a deadline.

The retained registered configuration describes 27B with 64 layers, hidden width 5120, vocabulary 248320, 24 query heads, four KV heads, head dimension 256, and full attention every fourth layer. The default Plan is 32/32, with eight full-attention and 24 recurrent layers in each half. All of these fit the source-level guards below. The corresponding 9B geometry is 32 layers, hidden width 4096 and 16/16; its vocabulary and attention interval are the same.

| Existing seam | Guard retained by reuse |
| --- | --- |
| `QwenLayerStageRecordedRequest` / `QwenLayerStageRequestSpec` | Prompt 3, chunk 2, output 2 satisfy the legacy short bounds; exactly one teacher produces steps of width 2/1/1, frontiers 2/3/4 and two complete logits rows. Vocabulary 248320 is below 262144. |
| `recordedQwenSourceIdentity` | Exact verified full-model receipt, source/configuration/Plan/layout identity, dense Qwen35, frozen model, no MTP and no partition fields. Layer count equals the supplied Plan, rather than a constant. |
| `CBv2RequestGeometry` / `CBv2RequestSession` | Actual dense Qwen35 protocols and `Qwen3NextMLP` topology; uniform actual KV dtype; full/recurrent local indices completely cover the model. Request capacity is prompt plus output = 5, within the declared and 32768 bounds. Query heads must be divisible by KV heads: 24/4 passes. Recurrent dimensions and byte products remain validated. |
| `QwenLayerStageSession` | Actual compact layer count equals the descriptor range; hidden width lies in 1...8192. Exact stage/configuration/layout identities and complete actual local KV/recurrent geometry remain required. The receiving stage consumes the owned residual, with local token positions unchanged. |
| `requireRecordedQwenStages` | Exactly two matching stages and complete baseline evidence; same artifact, source, Plan, transformation, dtype and source byte count. No replacement source cap is introduced here. |
| `QwenRecordedState` / `QwenRecordedLogits` | Global component keys are derived from the complete Plan. State metadata and digests must match exactly; both complete native logits rows must match their original bytes, including signed zero. These paths do not reduce evidence to argmax. |

The proposed `finishVerifiedQwenLayerStageBaseline` reuses the existing finishing behavior: it validates actual dense affine W4/G64 projections without requiring a tensor-parallel split, evaluates one real token embedding, verifies the loaded receipt/layout, and checks actual empty-cache metadata. It is arithmetic and has two check callbacks; a constructor-only result cannot substitute for it. Its loaded-model result remains inside the full owner. The pair receives only CPU baseline evidence after the full model and request have retired.

Callback counts are successful-path source counts with the existing optional phase observers nil. They are counts of invocations of the supplied `check` callback, not model kernels, GPU synchronizations, elapsed-time guarantees or checks performed by MLX error boxes. Let `C = 3 × attentionLayers + 2 × recurrentLayers`: 72 for 9B and 144 for 27B. Each snapshot contributes one callback per component, so the union of both half snapshots contributes the same `C` as the full snapshot.

| Existing operation | Callback calculation | 9B | 27B |
| --- | --- | ---: | ---: |
| Full baseline loop | Initial 1 + three times (forward 1 + snapshot C + final frame check 1) + two logits captures at 3 each + final 1 = `3C + 14` | 230 | 446 |
| Pair comparison loop | Three times (stage0 4 + boundary copy 2 + stage1 3 + snapshots C + final frame check 1) + two logits captures at 3 each + final 1 = `3C + 37` | 253 | 469 |

Stage0's four callbacks are session pre-forward, post-eval, post-state-validation and residual-byte capture. Stage1 omits the residual-byte callback. The boundary's two callbacks follow its owned copy and exact byte validation. Neither exact state/logit comparison nor request close introduces another supplied callback. Source frames are fixed at three; no optional observer factory is passed by these loops.

For the current proposed owner overlay, let `N` be the complete active source inventory: 927 or 1847. Every loaded tensor contributes one gate observation before read and two through the existing materializer checks. The full materializer adds one final check; the pair adds one per stage. Gate construction and finish each add one observation. The full record branch adds two wrapper checks and the two finishing checks described above. The pair adds two wrapper checks and two observations for each `completeStage` transition.

| Private gate, loading plus forward | Calculation | 9B | 27B |
| --- | --- | ---: | ---: |
| Full reference | `3N + (3C + 14) + 7` | 3018 | 5994 |
| Co-resident pair | `3N + (3C + 37) + 10` | 3044 | 6020 |

Both current gates therefore fit their existing limit of 8192 observations without widening it. These totals exclude outer initial/release resource samples that are not appended to the private gate, and assume one observation per proposed `checked()` callback. Error paths stop or poison the gate; they do not establish a successful count. Re-evaluate these equations if callbacks, optional observers, token geometry, source inventory or owner finishing change.

The live actual-free/zero-swap/allocator policy, native error preference, request cancellation, model/file release and outer hard deadline remain necessary. A finite callback count does not bound the duration of one existing eval or guarantee that later resource samples will pass. Existing legacy loader caps remain separate; the new registered owner must supply its independently bound live resource gate. No geometry or callback-bound issue found here justifies relaxing any of those checks.
