# Qwen-first paged attention and SSD prefix rollout

> Last updated: 2026-09-06 · commit `615d96328`

Status: **In progress** — 2026-09-06 — the initial activation cohort is the three Qwen fleet artifacts; validation and release approval remain incomplete.

The user selected Qwen 3.5, 3.6 and 3.8 for initial paged-attention activation. GPT-OSS and Gemma remain outside this first rollout, without discarding their retained failures or the broader migration work. This record separates implemented cache functionality from the evidence still needed to ship it.

## Initial cohort and retained evidence

| Fleet model ID | Proven initial behavior | Open evidence |
| --- | --- | --- |
| `qwen3.5-35b-a3b` | Contiguous and paged each pass their own B1 cache-off/SSD pair; paged restores 4,096 tokens with no resident prefix bank | Strict cross-backend output equality fails; connected HTTP and broader concurrency/capacity remain open |
| `qwen3.6-35b-a3b-vl-mtp-mxfp8` | Both backend-local SSD pairs pass, including restored cancellation, isolation and retirement | Strict cross-backend output equality fails with and without MTP; connected HTTP and broader execution remain open |
| `EigenLabs/Qwen3.8-27B-4bit-mtp` | Four B1 backend/cache comparisons and ten cache-off plus ten SSD HTTP cases pass | Final-runtime rerun, actual B2/B4, repeated performance, shared admission and persistent restart remain open |

The corresponding frozen reports are [Qwen 3.5 useful-tail pairs](../reports/2026-09-05-qwen35-useful-tail-pairs.md), [supported backend groups](../reports/2026-09-05-supported-backend-groups.md), [Qwen 3.6 backend regression](../reports/2026-09-05-qwen36-backend-parity-regression.md), [Qwen 3.8 backend/cache pilot](../reports/2026-09-06-q38-qat-backend-pilots.md), and [connected HTTP cancellation/recovery](../reports/2026-09-06-connected-http6-canceled-prefix.md). These results use their own pinned source/runtime tuples, not an unbuilt release candidate.

## Activation contract

The candidate changes automatic backend selection only for the exact cohort IDs. It must not turn an automatic choice into an explicit paged request: automatic preflight failures and the version-bound crash guard retain contiguous fallback and truthful telemetry. Explicit contiguous configuration, the paging kill switch, capability/span-mask vetoes, and explicit-paged failure semantics remain intact. Unlisted, unknown, GPT-OSS and Gemma IDs retain contiguous automatic selection.

`PrefixCachePolicy.isEnabled` already defaults SSD reuse on; `PrefixCachePolicy.isMemoryEnabled` defaults resident retention off. Neither policy needs a new resident bank or a smaller serving KV grant. Loaded model identity, tenant salt, prompt contract, authenticated checkpoint bytes and lifecycle receipts remain the cache-isolation boundaries.

Provider backend activation and coordinator checkpoint routing are separate. The latter retains its existing mode, percentage, QPS and exact-artifact allowlist gates until separately approved. A populated routing allowlist must use the reviewed model aggregate and prompt-contract tuple, not family-name matching. No production environment, key, traffic, release registration or deployment change is authorized by this source record.

## Remaining validation

1. Preserve the Qwen 3.5/3.6 strict backend failures while diagnosing and validating the differences. The Qwen 3.6 same-input replay isolates one arithmetic difference and verifies its KV placement; it does not establish whole-model quality or close serving equality. An upstream operator tolerance is not a replacement for a failed local trajectory gate.
2. Run the three-Qwen projection of the existing six-artifact plan: B1/B2/B4, retained and sustained workloads, ordered repeats, normal MTP and production-derived grants. Actual completed target forward width must be observed; queued requests or speculative lookahead do not certify B2/B4. Preserve the full-fleet plan separately.
3. Exercise real co-resident loading/draining, memory pressure and overlapping restore/export/cancel. Compare usable context/admission capacity to contiguous; verify correct reservation retirement rather than expecting allocator cache or RSS to become zero.
4. Complete Qwen 3.5/3.6 supported HTTP cases, eviction/reconnect/stale-receipt handling, the physical two-host pair, and signed persistent-key restoration after a fresh process. Existing same-host ephemeral B1 passes do not establish these properties.
5. Review and test the final source/runtime, complete signing and release checks, then enable the cohort with observable fallback and a documented rollback. No percentage estimate or prepared test plan constitutes acceptance.

## Rollback and deferred scope

`EIGENINFERENCE_CACHE_ROUTING_MODE=off` stops cache-aware routing. `DARKBLOOM_CBV2_PAGED_KV=0` selects the contiguous fallback. `DARKBLOOM_PREFIX_CACHE=0` disables local prefix reuse. These are independent: paging rollback alone can leave Qwen contiguous SSD reuse enabled. Their production use requires the specific approved operation.

GPT-OSS B2 cache divergence and Gemma verifier divergence remain retained, not waived. The Gemma same-state diagnostic is not required for Qwen activation and stays out of this initial integration. KV quantization remains outside 0.9.0.

## Worktree and handoff

The implementation worktree is `/Users/gaj/Documents/DarkbloomDev/wt/optimizations-integrated`. The earlier master handoff is `/private/tmp/darkbloom-release-090/status-2026-09-06-review6.json`; the complete earlier plan is its sibling `plan.md`. Those files describe the pre-Qwen-first scope and must be read alongside this decision.

The release preparation is PR #851, and isolated signing validation is PR #853. At this review, #851 is at `f91fe843b0cb22e2d1b2a85c0652982f3a8ff146`; #853 is at `f9423f94ef41ced998009f4d503919e038c35175`. Normal CI success does not establish the missing model matrix or persistent restart. The earlier signing run failed; the identity fix requires its own execution evidence.

Related: [prefix-cache architecture](../architecture/prefix-cache.md), [provider build procedures](../developer/build.md), and [validation procedures](../developer/test.md).
