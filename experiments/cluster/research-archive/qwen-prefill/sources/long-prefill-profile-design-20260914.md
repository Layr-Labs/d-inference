# Explicit long-prefill qualification profile

Source-only design, 2026-09-14. No source changes, native execution, build, SSH, or model-payload reads were performed. This describes the next admission contract; it does not qualify an 8K run.

Use a new named `long_prefill_8k_v1` profile and a new v4 prefill protocol path. Keep the existing bare v1 boundary header, v2 lookahead envelope, v3 measurement flow, fingerprints, default admission, and golden byte vectors unchanged. A larger request accepted through an existing v3 decoder would change its semantics even if the emitted JSON fields looked unchanged.

## Smallest explicit scope

- Add a separately admitted qualification request/profile. Its local constructor requires batch one, prompt 1...8192, chunk 1...512, output exactly one, no teacher/decode, and `ceil(prompt/chunk) <= 128`. Hidden width remains <=8192, vocabulary <=262144, with the existing floating dtypes. The pinned first execution is stricter: registered 9B, BF16, 8192/512/1, exactly 16 frames, fixed natural token IDs, and the existing 16+16 layer plan.
- Reuse schedule/forward/state machinery through an internal admitted request geometry, with distinct legacy and long-profile entry points. Preserve the current `RequestSpec` initializer, custom decoder, four-field encoding and v1 fingerprint. Do not add an unchecked initializer or make an omitted profile select larger bounds. New request/recorded-request fingerprints bind the profile under a new domain; a small request under the new profile still has a different identity from a legacy request.
- Add a separate profiled inner boundary-header type (`version: 2` in the boundary-header namespace), used only inside the new outer `version: 4`, `flow: "profiled_prefill_measurement_v1"` path. Bind the profile identifier/fingerprint in the start agreement and inner header. The inner header validates exact locally admitted frame membership, sequence <128, offset <8192, count <=512, prefill-only phase, checked end/byte arithmetic, and native `[1,M,H]` geometry. Preserve the old header type and all old decoders.
- Give v4 start, boundary ACK, token return and post-stop release distinct hash domains. Continue binding exact outer bytes, source, cohort, schedule, policy and final boundary. Derive receive allocation from the local admitted profile/request, never a received cap. Keep the current ready/received/consumed, token-before-stop, post-stop-before-diagnostics and error-retirement order.

The generic profile is an interoperability bound, not permission to execute every model that fits those dimensions. A separate registered execution admission binds the model/configuration, dtype, actual input bytes, environment, tensor estimate and OS resource policy. General prompt/chunk bounds do not imply support for 8192/chunk32: that would produce 256 frames and is rejected by this profile.

## Gate map

All paths below are relative to `experiments/cluster/inference/Sources/ClusterInference/` unless noted.

| Current gate | Required scoped treatment |
| --- | --- |
| `QwenLayerStagePrefillRankAdmission.swift:12` → `RankAdmission.swift:12` → `ComparisonAdmission.swift:25` | New named mode/profile admission; do not route larger counts through legacy option conversion. |
| `QwenLayerStageSchedule.swift:12`; custom request decoder delegates to this initializer | Keep legacy P<=128/M<=32/output<=4. Add the separately admitted request and reuse exact schedule arithmetic. |
| `QwenLayerStageRecordedRequest.swift:42`, `PrefillComputeContext.swift:29`, `PrefillStartAgreement.swift:61`, `PrefillComparisonValidation.swift:11` | New profiled counterparts/admitted core must all agree on bounds and fingerprint. A same-chunk full-model baseline is required too. |
| `QwenLayerStageBoundaryWireHeader.swift:133` | Legacy sequence/offset <132 and count<=32 are independent blockers. New outer envelope alone is insufficient: v3 delegates to this v1 header. |
| `QwenLayerStagePrefillRankTrace.swift:9,18`; recorded evidence frame bounds | Keep the 128-frame trace cap; the 16-frame target fits. Preserve one prepared native boundary and one pending CPU ticket. |
| `CollectivePointToPointShape.swift:8` | Keep 16 MiB: `512*8192*4 = 16,777,216` already fits. 9B BF16 boundary is 4,194,304 bytes. |
| Start/header/token controls | Keep 8/16/4 KiB encoded limits and strict raw nested integer/duplicate-key scanning. Larger tokens are represented by hashes on wire. |
| `BoundedProbeInput.swift:18` | Keep 65,536-byte input limit. Compact JSON for 8192 vocabulary-bounded IDs fits; excess whitespace still fails. |
| `CBv2RequestGeometry.swift:35`, `CBv2OwnedRequestState.swift:20` | Existing context<=32768 and checked KV capacity already fit 8193 reserved tokens. Keep full state-root evaluation, frontier checks and retirement. |

## Registered 9B resource estimate

The existing `ComparisonAdmission.swift:64–78` formula uses four-byte KV/activation elements, three recurrent generations, one largest CPU state component and two boundaries. Recomputed for maximumTokens=8193 and chunk=512:

| Named component | Bytes |
| --- | ---: |
| Three recurrent generations: `3*24*(98,304+2,097,152)` | 158,072,832 |
| Eight attention KV capacities plus Int32 offsets | 536,936,480 |
| Largest one-component CPU snapshot | 33,558,528 |
| Two conservative F32 boundaries | 16,777,216 |
| Total | **745,345,056 (710.816 MiB)** |

This exceeds the old 512 MiB gate. Add a separately named, pinned-9B estimate gate; e.g. a 768 MiB ceiling for these named tensors, with the exact expected estimate checked. Do not raise the old limit or use this ceiling as the generic profile's memory guarantee. Native BF16 per-stage KV capacity is 134,234,112 bytes; final full logical state is 319,946,784 bytes across 72 components. Neither number is whole-process peak memory.

Weights, loader/fusion transients, allocator overhead, attention/GDN workspaces, Metal/driver allocations and other processes are outside that estimate. The general model/depth maxima can cost much more. OS admission, zero-new-swap monitoring, cohort deadlines and cleanup remain separate prospective gates; the current 65-token timing study supplies no 8K memory guarantee.

## Qualification before any 8K performance claim

1. Pure CPU/Swift fixtures: preserve all legacy accepted/rejected inputs and exact byte vectors; explicitly reject long requests in v1/v2/v3. Verify the v4 16-frame timeline (offsets 0...7680, count512, final only sequence15), a ragged final chunk, the 128-frame ceiling, overflow/malformed integers, unknown/missing profile, cross-profile/version/phase replays, source/token disagreement and locally derived allocation limits. Independently reproduce the resource formula.
2. Root-owned native tiny fixture: same full model versus split stages under the new profile and same chunk schedule, both policies; use 1025/512/1 to cover offsets beyond132, chunk sizes beyond32, lookahead and a one-token tail. Then exercise the full 8192/512 timeline on tiny geometry and maximum admitted wire payload separately. Preserve exact final state/logit comparison, token selection, cancellation with pending consumption and clean retirement.
3. Root-owned registered9B correctness gate: prepare and freeze the actual natural 8192-token input. Run a fresh full-model **8192/512** baseline, then separately admitted serial/lookahead candidates. Check all 72 final state identities/shapes/dtypes/digests and full native final logits where privately available; exported digest-only reports remain digest evidence. Derive the first token from the new baseline, never reuse token2526 from the 65-token run.
4. Only after those gates, freeze a paired timing plan with a comparable solo control and explicit interval/warmth policy. Keep correctness evidence and resource observations for every retained or failed trial.

Chunk512 changes arithmetic dispatch: pinned `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/AttentionV1.swift:35,369,578` defaults to query blocks128, so it issues four blocks and explicitly disclaims bit identity with the unblocked path. Pin `DARKBLOOM_CBV2_ATTN_QUERY_BLOCK` and other arithmetic environment. Pinned Cmlx Metal SDPA (`scaled_dot_product_attention.cpp:749–764`) uses the composed path for head_dim256 with 128 queries; its score/workspace allocations are outside the table. Do not use a chunk32 baseline or interpret a numerical difference from it as a distribution error.
