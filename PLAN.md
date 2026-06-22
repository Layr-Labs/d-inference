# Inference Reliability — Fix Plan

> Branch: `worktree-fix-inference-reliability` · 2026-06-21 · from RCA of prod OpenRouter-facing uptime.
> **Strategy gate:** OpenRouter is ~99% of traffic and does NOT count HTTP 429 as downtime. Convert anything unservable into a **pre-dispatch 429 / one-shot 400/413** — never a served 5xx, never a dispatch-storm. No load-spreading; warm-pool config untouched. Coordinator deploy + any prod change is **human-only**.
> Companion: `PLAN-specs.md` (build-ready per-fix detail: files, code sketches, protocol diffs, tests).

# PLAN.md — Production Inference Reliability: Sequenced Implementation

**Tech-lead plan for 7 build-ready fixes.** Operating strategy (operator-confirmed, overrides any "spread load to serve peak" framing): the uptime lever is **converting anything we cannot cleanly serve into a pre-dispatch 429 (uptime-neutral; OpenRouter does NOT count 429 as downtime) or a one-shot 400/413/415 — never a served 5xx, never a dispatch-storm.** Warm-pool stays `OBSERVE_ONLY`, untouched. No prod-config flips are part of the core. No load-spreading fix exists in this plan.

Every uptime win below is framed as **"served-5xx/storm converted to uptime-neutral 429/400"**, not "more requests served."

---

## 0. Verification done before planning

Confirmed against the live tree (line refs in specs are accurate):
- `classifyRejection` (`api/inference_failure_class.go`) uses the stale-`ActiveTokenBudgetMax` heuristic; comment lines 117–200 confirm `rejectionDeterministicUnservable` vs `rejectionTransientCapacity` split and the `"not loaded"` capacity marker.
- `shouldStopFailover` / `latchDeterministicLoser` (`dispatch.go:896–945`) classify on the error **string only**, never `StatusCode`. `maxCapacityClassRetries` cap and `d.unservable` latch confirmed.
- Provider `mapInferenceErrorToStatus` (`ProviderLoop+ErrorMapping.swift:30–82`): `400`=invalidRole/invalidToolPayload/mediaUnsupportedByModel + all client `MediaError`; `422`=invalidResponseFormatOutput; `404`=modelNotLoaded/noModelLoadedForTokenization/responseNotFound; `429`=queueFull; `503`=tokenBudgetExhausted/requestRejected; `501`=embeddingsNotConfigured. **413/415 are NOT emitted today** (C1's defensive inclusion is harmless). `501` correctly excluded from C1's stop set.
- Provider session id `providerID := uuid.New()` (`provider.go:124`); `registry.Disconnect` (`registry.go:3512–3529`) deletes `providerOutcomes`/`providerBreakerOpenUntil`/`providerBreakerTrips` — confirms P2-zombie's "health state never accumulates across churn."
- `InferenceError` Swift struct + `error_reason` field already exist (`Messages.swift:162`); `InferenceErrorMessage.ErrorReason`/`StatusCode` already on the Go wire — so C1 reads a field already crossing the boundary, and P1 only adds 3 numeric fields.
- Servability `PredictServable` tier-2 fleet-budget gate + `sawUnknown` fail-open (`servability.go`), `projectedPerRequestDecodeTPS` falling to static `snap.decodeTPS` when no live rate (`scheduler.go:1483`), `snap.fleetMedianTPS` already populated from `tpsRegistry.Median` (`scheduler.go:942`) — all confirmed for C3/C5.
- Coordinator validates media **presence** + vision capability but never URL **shape**; VLM contract is `data:`-only (`VLMRequestInference.swift` `MediaError.invalidURL`) — confirms C4 root cause.
- Harmony rejects N parallel tool_calls at `GPTOSSHarmonyTemplateFixes.swift:49` → `invalidToolPayload`; toolschema cheap byte-needle gate pattern (`toolschema.go:62–96`) exists for P2-Harmony to mirror.

---

## 1. Phasing (dependency-ordered, fastest-uptime-first)

Fix-ID legend (some specs share short names): 
- **C1** = `P1-deterministic-client-4xx-stop` (stop the retry storm)
- **C3** = `P2-coordinator-oversized-predispatch-429` (oversized → pre-dispatch 429)
- **C2** = `P2-zombie-stable-identity-ejection` (eject zombies)
- **C4** = `C5-gemma-vision-remote-url-400`
- **C5** = `gemma-decode-quality-floor`
- **P1** = `provider-structured-admission-reason` (provider-side, needs release)
- **P2** = `harmony-parallel-toolcall-split` (provider-side, needs release)

| Phase | Fixes | Type | Ship gate |
|------|-------|------|-----------|
| **0** | **C1** | Coordinator-only | **Ships now.** No deps satisfied-by-code (C1 lists P2 as a dep but is explicitly the *backstop*, not blocked — it handles residual 400s regardless). |
| **1** | **C4** | Coordinator-only | Ships now; logically after C1 (C1 bounds C4's storm; C4 then makes it a *clean* 400). |
| **2** | **C3** | Coordinator-only | Ships now using its **own estimate**; consumes P1's reason when present. Not blocked on P1. |
| **3** | **C2** | Coordinator-only | Ships now; reads same error vocabulary as C1/C3. Land after C1/C3 so shed-vs-fault classification is stable. |
| **4** | **C5** | Coordinator-only | Ships any time (independent); grouped last among coordinator-only because it's quality/revenue, not uptime. |
| **5** | **P1** | **Protocol (Swift+Go) + provider release** | Needs Swift release + mixed-fleet auto-update. Sharpens C3/C2 classification once fleet updates. |
| **6** | **P2** | **Provider release** (no protocol) | Needs Swift release. Quality/revenue (recovers gpt-oss parallel-tool histories). |

**Why this order:** Phases 0–3 are the uptime core and are *all coordinator-only quick wins shippable now* (subject only to the standing human-only EigenCloud deploy). They convert the three biggest served-5xx/storm sources into uptime-neutral 429/400 without waiting on any provider release. P1 (phase 5) is the provider-side truth-source that *upgrades* the coordinator's guessing into deterministic classification, but the coordinator is correct without it via the legacy fallback. P2 (phase 6) is pure revenue recovery. C5 (phase 4) is a soft routing-quality nudge with no uptime stake, so it's deprioritized but is cheap (S) and can be slipped in opportunistically.

---

## 2. Per-phase detail: fixes, order rationale, production impact

### Phase 0 — C1: StatusCode-driven non-retryable stop (the retry storm)
**Fix:** In `shouldStopFailover`, BEFORE `classifyRejection`, add a `StatusCode`-driven stop on a **client-shape set `{400, 413, 422, 415}`** that deliberately **excludes 404/408/429** (404 = "model not loaded" cold-miss MUST keep failing over and also matches the `"not loaded"` capacity marker; 429/408 transient). Mirror the same latch in `latchDeterministicLoser` so a speculative loser can't restart the storm. Thread the real 4xx through the exhausted ladder **once** (skip the capacity probe / 5xx→429 reclassification; `terminalClientError` checked **before** `d.unservable` and before `statusCode==0`). Add a `client_error` routing-outcome class so these stay out of the `AdmittedButFailed` admission-mismatch gauge. String-blind by design.
**Why first:** Highest-leverage, lowest-risk, zero deps. It is the single choke point that ends the **29× retry storm** (avg 29, max 63 attempts on deterministic `invalidToolPayload`/`invalidRole`/`mediaUnsupportedByModel`/`invalidResponseFormatOutput`/VLM-400s). Every later coordinator fix (C4 especially) relies on C1 to bound any residual dispatch.
**Production impact:** A deterministic provider client-4xx now stops after **1 dispatch** instead of up to 64. **Served-5xx/storm → one clean terminal 400/422 at the consumer.** Soundness guard: the only coordinator-emitted 4xx is `402` (PaymentRequired, `dispatch.go:769`), which is NOT in the stop set, so a coordinator fault can never be mistaken for a provider client error — every code in `{400,413,422,415}` can only originate from a provider `InferenceErrorMessage`.

### Phase 1 — C4: pre-dispatch media-URL-shape validation
**Fix:** Add a `validateMediaParts` gate in the coordinator (mirrors the provider's `data:`-only contract) that walks every `image_url`/`input_image`/`image`/`video_url`/`input_video`/`video` part across `messages[]` and Responses `input[]`, returning **one terminal 400 `invalid_request_error`** when any media URL is not an inline `data:` URI. **Fail-OPEN on unrecognized shapes** (unknown part → today's behavior, bounded by C1). Scope to remote-URL rejection (Anthropic raw-base64 normalizer is a documented follow-up, Option B fetch-and-inline gated behind `DARKBLOOM_VISION_FETCH_REMOTE=0`).
**Why after C1:** C4 depends on C1 — without C1, a remote-URL vision request still storms (the `ErrorCh` handler returns `outcomeRetry` unconditionally). C1 makes the residual a clean stop; C4 moves the rejection **pre-dispatch** so the caller gets an actionable error before any provider hop.
**Production impact:** The verified **~537/hr remote-URL vision storm** becomes **one pre-dispatch 400** with an actionable message ("media must be an inline base64 `data:` URI"). **Served capacity-failure → uptime-neutral one-shot 400.**

### Phase 2 — C3: oversized requests → pre-dispatch 429/413
**Fix:** (1) Subtract committed+queued from each provider's budget in `PredictServable` tier-2 so the fleet-budget tier reflects **live** headroom (keep the RAW/uncalibrated estimate — under-counts prompt tokens, the safe direction). (2) Route-time clamp/reject in `buildCandidateWithReason` against the **selected** provider's live remaining budget; reject pre-dispatch when even `prompt+256` won't fit anywhere. (3) Clamp explicit `max_tokens` to `min(modelContext-prompt, fleet headroom)` in `ensureMaxTokensBound` — **only DOWN, never up; log it**. (4) Convert predictable-oversized `first_chunk_timeout` to **429** instead of bare 504. (5) Emit **413 only** when nothing (not even `prompt+floor`) fits ANY provider's live budget; otherwise 429. All behind `EIGENINFERENCE_SERVABILITY_GATE` / `EIGENINFERENCE_OVERSIZED_CLAMP`, fail-open, **ship dark**.
**Why here:** Independent of P1 (uses its own estimate; consumes P1's `errorReason` when present). Lands after C1/C4 so the dispatch path's terminal/clean-stop semantics are already in place. Reuse `committedTokenBudget()` / the same `coordinatorExtra` clamp as `freeMemoryAdmits` (`scheduler.go:993`) so predict and route can't disagree and bounce a request.
**Production impact:** The ~18k-prompt + 32k-max-tokens (~50k) class that today slips past fail-open gates (idle box advertising full 131072 context makes 50k always "servable") and then **503 (token_budget_exhausted)** or **504 (first_chunk_timeout)** now becomes a **pre-dispatch 429** (or a clamped, strictly-better response). **gpt-oss 5xx/504 → uptime-neutral 429.** Primary risk is over-shed off a stale ~5s heartbeat — mitigated by fail-open-on-`sawUnknown`, raw estimate (under-count), dark ship, and watching `routing.oversized_request_rejected{stage:preflight}` vs `{stage:dispatch}`.

### Phase 3 — C2: stable-identity zombie ejection
**Fix:** New `registry/health_ejection.go` gate keyed by **stable identity** (`SerialNumber`, else `"sekey:"+SEPublicKey`, else `"acct:"+AccountID`) that survives reconnect within a coordinator lifetime, with a rolling success-rate window independent of session UUID/challenge/reputation. Ejects only after a meaningful sample shows near-total success collapse; **half-opens** to re-probe; **fails OPEN** (never ejects the last provider for a model); does **NOT** delete state on `Disconnect`. **v1 SAFE interaction with P1/classifyRejection:** treat `rejectionTransientCapacity` AND `rejectionDeterministicUnservable` as **capacity sheds → never count** (only genuine served faults: 500/502/504, fault-503, real provider `InferenceErrorMessage`). **OOM-disconnect-flush 502 + synthetic GatewayTimeout → neutral/not recorded** (the box was busy, not broken). Live kill-switch via `os.Getenv` at evaluation time (`EIGENINFERENCE_HEALTH_EJECTION`, default on).
**Why after C1/C3:** This gate reads the same provider error vocabulary as C1/C3; its shed-vs-fault split must stay aligned with their classification strings. Landing it after they're stable prevents drift. It also depends on C3's `request_too_large`/classifyRejection split being settled so deterministic-unservable is correctly excluded from counting.
**Production impact:** The **~7,880-disconnect/48h zombie boxes** (0 successes, ~100% served-fault, currently stay routable because per-session-UUID breaker state is deleted on every reconnect) get **ejected from routing on the stable identity** after a real fault collapse. **Served-5xx from broken nodes → those nodes removed from the candidate set** (requests route to healthy boxes instead of 5xx-ing). Fail-open guarantees a fleet-wide bad rollout never zeroes routing (double-scan via `ignoreProviderBreaker` rescan, same pattern as the session breaker).

### Phase 4 — C5: decode-quality floor uses tps_registry median (quality/revenue)
**Fix:** Feed `snap.fleetMedianTPS` (durable per-`(model,chip)` `tpsRegistry.Median`, already populated) into `projectedPerRequestDecodeTPS` as the **solo-rate signal when no live per-slot rate exists** (`NumRunning==0`), instead of jumping to the static benchmark (`snap.decodeTPS ~23` for gemma). **Deprioritize, never reject; never fail closed; no zero-out.** Cold-start (no samples, `fleetMedianTPS==0`) → static, identical to today.
**Why last among coordinator fixes:** No uptime stake — it's a soft preference at `scheduler.go:577`. Cheap (S) but lower urgency.
**Production impact:** The ~9 tok/s **idle-but-historically-slow gemma boxes** (p90 112s, **client_gone**) are deprioritized even while idle. Reduces `client_gone`/slow-stream incidents without removing capacity (full pool survives when every gemma box is below floor — verified non-zero-out).

### Phase 5 — P1: provider structured admission reason (protocol + release)
**Fix:** Provider compares the request against a memory-pressure-BLIND node ceiling (`UnifiedMemoryCap.kvBudgetBytes / kvBytesPerToken`) and the model context, then ships `error_reason` ∈ `{request_exceeds_context, request_exceeds_node, capacity_busy, invalid_request}` plus `reserved_tokens`/`node_max_budget_tokens`/`model_context` on **both** the batched submit path and the non-batched VLM `reserveVisionRequest` path. Protocol: add 3 numeric fields to Swift `InferenceError` + Go `InferenceErrorMessage` (mirrored, `encodeIfPresent`/`decodeIfPresent`, JSON forward+backward compatible). Coordinator `classifyRejection` trusts the explicit reason (explicit-reason switch fires ONLY on exact new strings) and **keeps the existing string heuristic as the `reason==''` fallback**.
**Why after the coordinator core:** P1 is the *truth source* that retires the coordinator's stale-snapshot guessing, but the coordinator is already correct via fallback. Landing it later avoids blocking the uptime wins on a human-gated release + mixed-fleet rollout.
**Production impact:** Once the fleet updates, C3/C2 classification stops guessing from a stale heartbeat. `request_exceeds_context` (truly fleet-identical) → deterministic stop; `request_exceeds_node` (node-specific) → fail over to a bigger box (bounded by `maxCapacityClassRetries`), since a request that exceeds a 64GB box may fit a 128GB box. **Status stays 429** at the coordinator dispatch outcome to preserve OpenRouter semantics for the legacy fleet; flipping 429→413 for the consumer is a **separate explicitly-gated change** — call out in the PR, do not change the legacy string path.

### Phase 6 — P2: Harmony parallel-tool-call split (release, no protocol)
**Fix:** Replace the `invalidToolPayload` 400 with a Harmony-only, behavior-preserving rewrite: split an assistant message with N parallel `tool_calls` into N sequential single-call assistant turns, each followed by its paired `role:"tool"` result (matched by `tool_call_id`, NOT position). content carried on first split turn; `thinking`/`reasoning_content` moved to a standalone assistant turn before the tool turns. Keep a **clean 400 only** for genuinely-unnormalizable histories (a tool result pairing with no emitted `tool_call_id`). Cheap byte-gate on `"tool_calls"` before the JSON round-trip (mirror `toolschema.go` size cap + needle gate). Optional coordinator mirror gated on the **resolved** gpt-oss build id.
**Why last:** Pure revenue recovery (legitimate OpenAI/OpenRouter parallel-tool histories that can NEVER succeed on gpt-oss today). No uptime stake, no protocol change, but needs a release.
**Production impact:** Parallel-tool gpt-oss requests that currently hard-400 now **succeed**. Idempotent with any coordinator-side split (count==1 turns pass through).

---

## 3. Mixed-fleet correctness note

The fleet is heterogeneous (~11 on 0.4.7 + a 0.5.16 majority + newer). The coordinator MUST stay correct against providers that have **neither** P1's new fields **nor** P2's normalization:

- **C1 (phase 0):** reads `StatusCode`, which **already crosses the wire on every provider version** (populated by `mapInferenceErrorToStatus` since well before 0.4.7). No fleet dependency. Old providers still emit `400`/`422` for client faults → C1 stops correctly today.
- **C3/C2 (phases 2–3):** classify on the existing error **string + StatusCode**. They consume P1's `errorReason` **only when present**; `reason==''` (every old provider) falls through to the **UNCHANGED DAR-347 string+budget heuristic**. No regression for old providers; new providers (post-P1) get sharper classification. A `reason==''` regression test guards this fallthrough.
- **P1 (phase 5):** old providers omit the 3 new numeric fields → Go zero-values, Swift `decodeIfPresent` → nil. Old coordinators ignore unknown JSON keys. Backward+forward compatible by construction. The `classifyRejection` explicit-reason switch fires ONLY for the exact new reason strings, so old providers degrade to today's behavior exactly.
- **P2 (phase 6):** operates on the already-decoded message dict before `applyChatTemplate`; uses only existing fields. A lagging provider that receives a coordinator-normalized (already-Harmony-legal) history renders it natively. No wire change. Idempotent.
- **Rollout latency is real:** P1's structured reason and P2's recovery are observed *broadly* only after the ~90% fleet auto-updates. Until then the coordinator runs the legacy fallback (P1) / receives native rejections (P2). This is acceptable because phases 0–4 already capture the uptime wins on the existing wire.

---

## 4. Test / verification gate per phase (live-isolated, per CLAUDE.md)

All tests are **live-isolated** (real `httptest.NewServer(srv.Handler())`, in-memory or ephemeral store, fake fixtures — never prod, no mocked dependency-under-test). Every bug fix gets a regression test that fails without the fix.

| Phase | Live-isolated test gate | Prod telemetry to confirm the win |
|------|------------------------|-----------------------------------|
| **0 / C1** | Drive the real HTTP path; a provider stub returns `InferenceErrorMessage{StatusCode:400}` → assert **1 dispatch**, body status==400, `inference.dispatches{status:retry}` does **not** fire 29×. Speculative-loser variant: assert `latchDeterministicLoser` stops the storm. Exhausted-ladder ordering test: `terminalClientError` checked before `d.unservable`/`statusCode==0`. `reason==''` legacy 503 still 429s. | `inference.dispatches{status:retry}` per-request count drops (was avg 29); new `routing_outcome:client_error` class appears; `AdmittedButFailed` gauge no longer inflated by deterministic 4xx. |
| **1 / C4** | `validateMediaParts` unit + HTTP test across all enumerated shapes (`image_url` obj/string, `input_image`, Anthropic `image` url/base64, `video_url`, `input_video`, `video`): remote `https://` → one 400 `invalid_request_error`, `data:` → passes, unknown shape → fail-open (dispatches). | `inference_routes` for vision: remote-URL **pre-dispatch 400 rate** rises, **dispatched-then-400 storm** (~537/hr) falls to ~0; vision dispatch attempts/req drops. |
| **2 / C3** | Live coordinator + provider stub: 18k-prompt + 32k-max-tokens → assert **pre-dispatch 429** with gate on; assert 413 ONLY when nothing fits any budget; `max_tokens` clamp logs and only shrinks; fail-open on `sawUnknown`; predict/route agreement test (reuse `committedTokenBudget`/`coordinatorExtra`). Pin the P1 reason-string vocabulary in a shared test. | `routing.oversized_request_rejected{stage:preflight}` ≫ `{stage:dispatch}` (preflight catching real oversized traffic); `token_budget_exhausted` 503 + `first_chunk_timeout` 504 rates fall; total rejection rate not inflated. |
| **3 / C2** | New `health_ejection_test.go`: stable-identity window accumulates **across simulated reconnect churn** (different session UUIDs, same Serial); ejects on served-fault collapse; capacity-shed (503/`rejectionTransientCapacity`/`rejectionDeterministicUnservable`) and OOM-disconnect-flush 502 **never count**; fail-open never ejects last provider for a model; half-open re-probe; live kill-switch via getenv. | Zombie stable-ids appear in an ejection gauge; their served-fault contribution to overall 5xx drops; healthy-provider success rate per model rises; no model goes to zero providers. |
| **4 / C5** | `projectedPerRequestDecodeTPS` test: idle box (`NumRunning==0`) with low `fleetMedianTPS` projects **below** floor → deprioritized; whole-cohort-below-floor → **full pool survives, request still routed** (no 429, no zero-out); cold-start `fleetMedianTPS==0` → static (today's behavior). | `client_gone` rate on gemma falls; p90 stream latency on gemma improves; routing no longer selects historically-9-tok/s idle boxes. |
| **5 / P1** | `swift test`: provider emits each reason on batched + VLM paths; node-ceiling math is pressure-blind. Go: `classifyRejection` trusts explicit reason; `reason==''` fallback test (mixed-fleet guard); wire round-trip with old-provider zero-values. | New provider versions emit `error_reason` distribution; coordinator telemetry distinguishes `request_exceeds_context` vs `request_exceeds_node` vs `capacity_busy`; classification accuracy (vs the stale heuristic) improves. |
| **6 / P2** | `swift test`: N-parallel-tool split → N sequential turns, `tool_call_id` pairing (out-of-order results test), content/thinking separation, orphan-tool-result → clean 400, idempotent re-normalize. Byte-gate fires before JSON round-trip (non-tool traffic pays nothing). | gpt-oss parallel-tool 400 rate falls to ~0; gpt-oss tool-call request success rate rises. |

**Per-objective quality gate (CLAUDE.md):** after each phase, do a modular refactor pass, then spawn **both** reviewers in parallel (Codex rescue subagent + general-purpose Claude subagent) on the diff; proceed only after both pass; run `go test ./...` / `swift test` / `npm run build` as appropriate.

---

## 5. Risk register & explicit HUMAN-ONLY steps

### Risk register
| # | Risk | Phase | Mitigation |
|---|------|-------|-----------|
| R1 | C1 stop-set wrongly includes 404 → cold-load failover regresses | 0 | Stop set is exactly `{400,413,422,415}`; 404 explicitly excluded (also matches `"not loaded"` capacity marker). Integration test asserts cold-miss still fails over. |
| R2 | A provider that wrongly returns 400 for a transient condition now stops instead of failing over | 0 | Provider map returns 400 only for genuine client faults; kill-switch backstop. |
| R3 | C4 over-rejects a "legitimate" remote-URL client | 1 | Remote URLs DON'T work today (provider 400s), so clean rejection is strictly-better UX, never a capability regression. Unknown shapes fail-open. |
| R4 | C3 over-sheds a valid mid-size request off a stale ~5s heartbeat | 2 | Fail-open on `sawUnknown`; RAW (under-counting) estimate; ship dark; watch `{stage:preflight}` vs `{stage:dispatch}`; clamp only DOWN. |
| R5 | C3 emits non-retryable 413 too eagerly | 2 | 413 only when nothing (even `prompt+floor`) fits ANY provider's live budget; otherwise 429. |
| R6 | C2 ejects busy-but-healthy boxes (counts OOM-disconnect as fault) | 3 | OOM-disconnect-flush 502 + synthetic GatewayTimeout treated as capacity/neutral; only real provider `InferenceErrorMessage` served-faults count; fail-open never zeroes a model. |
| R7 | C2 ejection state lost on coordinator restart | 3 | Documented + accepted (window re-accumulates in minutes; prod store is in-memory; cross-restart durability is out of scope). |
| R8 | C5 hot-spots onto a few fast boxes | 4 | Pre-filter feeds the same cost-based + tie-break + random-spread selection; `QualityCap` headroom gate prevents over-packing; deprioritize-only (never reject) → worst case is mild mis-ranking, not lost capacity. |
| R9 | P1 mixed-fleet: old providers omit fields | 5 | Explicit-reason switch fires only on exact new strings; `reason==''` fallback unchanged; regression test guards it. |
| R10 | P1/C3 reason-string vocabulary drift | 2,5 | Pin the `{request_exceeds_context, request_exceeds_node, capacity_busy, invalid_request}` vocabulary in a shared test mirrored in `inference_failure_class.go` markers; on drift the coordinator silently falls back to the heuristic (degrade, not regression). |
| R11 | P2 parallel→sequential semantic reframing | 6 | Benign for the model's next turn (sees all calls+results); the only alternative is a hard 400, so any faithful split dominates; deterministic ordering + `tool_call_id` pairing tested. |
| R12 | C3 prod activation requires flipping env gates | 2 | `EIGENINFERENCE_SERVABILITY_GATE`/`EIGENINFERENCE_OVERSIZED_CLAMP` are **human-only** KMS flips (no NEW secret). Ship dark; agent prepares the flip commands. |

### HUMAN-ONLY steps (agent prepares; does NOT execute)
1. **All prod coordinator deploys** (`ecloud compute app deploy d-inference`) — EigenCloud, human-only per CLAUDE.md, for **every** coordinator-only phase (0–4) and the Go half of P1 (5). Agent prepares the PR + the exact commands; agent may run read-only `ecloud compute app logs` / `curl https://api.darkbloom.dev/health`.
2. **C3 env-gate activation** — flipping `EIGENINFERENCE_SERVABILITY_GATE` / `EIGENINFERENCE_OVERSIZED_CLAMP` in EigenCloud KMS at deploy time (phase 2). No new secret introduced.
3. **C2 rollback knob** — `EIGENINFERENCE_HEALTH_EJECTION` defaults **on** in code (live getenv, no redeploy to disable); flipping it via KMS env for rollback is human-only.
4. **Swift provider releases** for P1 (phase 5) and P2 (phase 6) — tag/release is **human-only** (never tag/release without explicit ask). Agent prepares version bump (`ProviderCore.swift`), changelog, and the squash. Mixed-fleet auto-update follows.
5. **The 429→413 consumer-status flip** (P1) is a **separate, explicitly-gated** change — must be called out in its own PR and human-approved; do NOT bundle it into the P1 protocol PR.

### Standing constraints honored
- Warm-pool / cold-spill / load-spreading: **untouched** (`OBSERVE_ONLY`).
- No prod-config flips in the core (phases 0–4 ship behind in-code defaults; only C3 has env gates, human-flipped).
- Protocol symmetry: only P1 changes the wire; Swift `Messages.swift` + Go `messages.go` edited together.
- Every fix converts a **served-5xx/storm into an uptime-neutral 429/400**, not "more requests served."
```

I verified all load-bearing claims in the specs against the live tree before sequencing — the line references, the provider error→status codes, the breaker-keying/Disconnect deletion, the servability/scheduler hooks, and the Harmony/toolschema gate patterns all check out, so the plan stands on the actual code rather than the spec text alone.

The plan above is the deliverable (PLAN.md content). Key sequencing decision: **C1 → C4 → C3 → C2** are the coordinator-only uptime core, all shippable now (no provider release needed), capturing the 29× storm, the ~537/hr vision storm, the oversized 503/504, and the ~7,880-disconnect zombies on the existing wire. C5 (quality, S-effort) slots in opportunistically. P1 and P2 are the human-gated provider releases that *upgrade* classification and recover gpt-oss parallel-tool revenue — explicitly **not** blocking the uptime wins because the coordinator stays correct via legacy fallback against the mixed fleet.

If you want, I can write this to `/Users/gaj/Documents/Builds/d-inference/PLAN.md` (note: CLAUDE.md instructs me not to auto-create summary .md files, so I've returned it inline rather than writing it without being asked).
