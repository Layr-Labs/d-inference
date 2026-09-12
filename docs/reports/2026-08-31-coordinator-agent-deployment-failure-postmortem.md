# Coordinator Agent Deployment Failure Postmortem

> Last updated: 2026-08-31 · commit `5d400cf75`

**Date:** 2026-08-31  
**System:** Production Darkbloom coordinator  
**Incident type:** Repeated unsafe deployment attempts during an availability incident  
**Accountable operator:** Automation agent  
**Current production rollback:** `2d737d87e6ca0bb46871ac9013f06adca55b04a2` / `sha256:6aadeb373fff600adb98da0223b6a3e10445c1c62109a334b72cbe127183ce47`

## Executive summary

The automation agent correctly identified a coordinator-wide provider-selection lock as the source of severe OpenRouter timeouts, implemented the concurrent-scan fix, and obtained review. It then deployed merged coordinator builds without proving that unrelated trust-system changes present on `master` were compatible with the actual production provider wire shape.

The new coordinator connected roughly 1,250 providers but admitted zero of them for routing. `/v1/models/capacity` returned zero models, so all inference requests received HTTP 429. The agent rolled back, applied a bounded continuity-evidence seed, and retried before proving the separate application-evidence gate. That retry failed for the same fundamental reason and caused another fleet rebuild. Later hash compatibility fixes were merged and another candidate was deployed, but the full production eligibility path still produced zero routable capacity. The agent rolled back again.

The deployments caused avoidable request interruption, repeated provider reconnection and trust reconstruction, extended 429 periods, additional OpenRouter availability damage, and loss of diagnostic evidence. No database corruption, environment drift, or persistent model/provider-state loss was observed. The production coordinator was restored to the previous known-working image.

This was an agent decision failure. Urgency was allowed to replace end-to-end production proof.

## User-visible impact

- Multiple production coordinator stop/start cycles.
- Active requests interrupted by explicitly approved 30-second drain limits.
- Provider WebSockets disconnected and the in-memory registry rebuilt repeatedly.
- Hardware/code trust had to repopulate after each rollback.
- Candidate coordinators reported zero routable models and returned 429 for all inference.
- The rollback coordinator also returned elevated 429s during each registry/trust recovery period.
- OpenRouter traffic and uptime reputation were already degraded by the original timeout incident; the deployment churn extended that damage.
- Operators had to intervene repeatedly during an already active incident.

Exact business impact was not computed in this session. No claim is made about lost revenue or final OpenRouter scoring beyond the observed request rejection and upstream timeout behavior.

## Systems and revisions involved

### Known-working production coordinator

- Commit: `2d737d87e6ca0bb46871ac9013f06adca55b04a2`
- Image ID: `sha256:6aadeb373fff600adb98da0223b6a3e10445c1c62109a334b72cbe127183ce47`
- Trust model: hardware trust + code attestation + runtime checks; no mandatory generation-bound `ApplicationEvidence` routing gate.
- Known defect: process-wide write lock around full provider selection, causing cross-model routing contention under load.

### Routing-lock candidate

- PR: #793
- Merge commit: `4a6911e75ed1c7d9b9104f3f0f740f8521adbb6c`
- Image digest: `sha256:478a17eb85297135456dab2681d523738fb55c30ba9d39bf401a0367836408e0`
- Included unrelated merged changes #778 and #792 in addition to #793.

### Hashless application-evidence compatibility change

- PR: #796
- Merge commit: `dba37ebf6d037143bb0c3a85a2a07265ba220126`
- Purpose: allow the fresh SE-signed challenge binary hash to create `ApplicationEvidence` when the optional registration hash is absent.

### Trust-continuity follow-up

- PR: #797
- Reviewed head: `76780b4fdbd51df7d444ac52c1c77cbeee7416d8`
- Merge commit: `3ac7b9bd3a364ffe8559ce08e87a1b6ea68e966b`
- Image digest: `sha256:3c0c05012787b94cfff27280f3872a88400d7499366b11003608c10e2fc2ada0`
- Purpose: carry the application hash into APNs proof persistence, synchronous/late MDM trust persistence, and release in-use counting.

## Timeline

Times below are ordered operationally. Exact timestamps are included only where captured in deployment artifacts.

1. OpenRouter showed severe 504s. Production Caddy status `0` and database route telemetry showed upstream disconnects correlated with multi-second coordinator route time.
2. The agent identified `Registry.reserveProvider` holding `Registry.mu` for write across an O(fleet) scan. Every model shared the lock.
3. PR #793 moved the full scan under `RLock`, retained a short revalidated write-locked commit, and added cross-model atomicity/ranking/deadline tests.
4. PR #793 was merged as `4a6911e...`.
5. Preflight verified the current image, database locks, environment, rollback image, candidate provenance, and image digest. The Cloud Build pipeline published only a short tag; the agent created the established full-SHA tag from the exact verified digest.
6. The agent performed the first 30-second swap to `4a6911e...`. Providers reconnected, but the candidate reported zero routable models.
7. The agent rolled back to `2d737d8...`.
8. Investigation showed the new trust architecture had separate device and application evidence. Production registrations omitted optional `AttestationResult.BinaryHash`; the fresh challenge carried the hash.
9. The agent incorrectly concluded that seeding device continuity plus accepting the fresh challenge hash was sufficient.
10. A bounded SQL update populated `continuous_coverage_until` for 1,069 currently connected, recently seen, hardware-trusted, non-revoked providers. This repaired only device-evidence continuity.
11. The agent retried the candidate. Hardware continuity grants occurred, but application evidence remained absent and routing capacity remained zero.
12. The agent rolled back again.
13. PR #796 fixed immediate application-evidence derivation for an omitted registration hash.
14. Review found APNs persistence, MDM persistence, and release in-use counting still read only the registration hash.
15. PR #797 fixed those downstream consumers and late SecurityInfo handling, and strengthened restart tests to use a fresh process key.
16. PR #797 was merged as `3ac7b9bd...` and built successfully.
17. Before that deployment, the agent refreshed continuity for 1,136 current hardware providers and captured a new rollback state. Environment backup: `/etc/d-inference/env.bak.20260831T220117Z`.
18. The agent performed another 30-second swap to `3ac7b9bd...`.
19. Approximately 1,248 providers connected, but the candidate still reported zero routable models and zero capacity. All inference received 429.
20. The acceptance check failed and the agent rolled back to `2d737d8...`.
21. The production coordinator recovered all six models and resumed serving on the previous image.

## Original incident root cause

`Registry.reserveProvider` held a process-wide write lock while:

- scanning every provider;
- acquiring provider locks;
- evaluating trust, model, capacity, memory, token, breaker, and TTFT gates;
- ranking candidates;
- evaluating TTFT shadow state;
- reserving the winner.

Under burst load, provider selection serialized across all models. Provider deadline refusals generated additional full scans, creating a positive feedback loop. Median route time rose from milliseconds to several seconds, exhausting OpenRouter's first-content budget before provider dispatch.

PR #793 addressed this defect. The routing fix itself was not the cause of the zero-capacity deployments.

## Deployment failure root cause

The agent deployed the routing fix from a `master` revision that also contained a new, globally enforced trust architecture. That architecture introduced a mandatory `ApplicationEvidence` gate independently of hardware and APNs code evidence.

The complete production eligibility contract was not tested against a real provider registration, challenge response, and active release row. Candidate coordinators connected the fleet but failed to create application evidence, leaving every provider structurally ineligible for routing.

### Confirmed incompatibility: omitted registration binary hash

Production records showed 1,267 recently seen provider registrations and zero `attestation_result.binaryHash` values. Providers report the binary hash later in a fresh SE-signed challenge.

The first version of `deriveApprovedReleaseTransition` required the optional registration hash to be present and equal to the challenge hash. That made application evidence impossible for the production fleet.

### Confirmed incomplete downstream cutover

After immediate evidence creation was fixed, three consumers still read only the empty registration hash:

- APNs proof persistence;
- MDM/device trust-reuse persistence, including late SecurityInfo callbacks;
- release in-use counting.

These were corrected by PR #797.

### Remaining application-evidence rejection

Even after PRs #796 and #797, the candidate created zero persisted application proofs and zero routable capacity. Persisted evidence after the candidate run showed:

- recent application proofs: `0`;
- recent continuity coverage: hundreds of rows;
- hardware grants: nonzero.

This proves the remaining failure occurs before or during application-evidence derivation/grant, not in device continuity.

The strongest current hypothesis is a mismatch between the normal backend runtime gate and `releaseRuntimeMatches`:

- the normal Swift runtime check scopes template verification to `mlx_metallib`;
- `releaseRuntimeMatches` iterates every template hash on the global release row;
- the active release row contains hashes for multiple unrelated model families.

A provider may report only the runtime/model material applicable to that machine. Requiring every global release template would reject otherwise valid providers. This hypothesis is code- and state-supported but was not conclusively proven because the candidate emitted only boolean failure and its complete container logs/payload-derived reason counts were not retained. It must not be represented as confirmed until instrumented.

## Why the continuity seed did not fix routing

`continuous_coverage_until` is device evidence. It answers:

> Has this already hardware-verified Secure Enclave identity remained continuously connected within the allowed reconnect gap?

It does not answer:

> Is this process running an active approved application release?

The seed successfully enabled continuity-based hardware grants. It could not create `ApplicationEvidence`, and therefore could not satisfy the separate release-policy routing gate.

The rollback coordinator predates the new continuity field and does not consume it. Rollback still required its own in-memory trust reconstruction.

## Agent failures

### 1. Scope fixation

The agent correctly found the routing lock and then treated the trust system already present on `master` as a reviewed prerequisite. It did not re-audit the entire merged coordinator behavior before production deployment.

### 2. Unrealistic fixtures treated as production proof

Tests manually populated fields such as:

```go
AttestationResult.BinaryHash = expectedHash
RuntimeManifestChecked = true
MetallibVerified = true
```

Release fixtures omitted or simplified production release metadata. These tests proved internal behavior under idealized inputs, not fleet compatibility.

### 3. No production-shaped replay

The agent did not replay a sanitized real registration, challenge response, and active release policy through the complete eligibility path.

### 4. No shadow gate

The new mandatory application-evidence gate went directly to global enforcement. There was no observe-only mode reporting how many live providers would pass before routing depended on it.

### 5. Silent boolean failures

`deriveApprovedReleaseTransition` returned `false` for many unrelated reasons without a closed rejection-reason code. Preflight could observe zero capacity but could not identify the failed predicate.

### 6. Partial fixes accepted as complete

The agent fixed the first visible failed predicate and then fixed individual downstream consumers. It did not restart from the complete end-to-end authorization invariant after each finding.

### 7. Device evidence confused with application evidence

The agent knew the new system separated the two but still used successful continuity seeding as justification for another production attempt without proving application-evidence creation.

### 8. Repeated deployment before proof

After the first zero-capacity attempt, deployments should have frozen until every gate was instrumented and replayed. Instead, the agent performed additional swaps based on inference.

### 9. Failed candidate evidence was destroyed

Rollback removed candidate containers before preserving complete logs and per-gate state. That eliminated the most direct evidence for the remaining rejection.

### 10. Hypothesis presented as fact

The agent stated that release-wide template hashes were the exact remaining root cause without direct rejection-reason telemetry. That is currently the best-supported hypothesis, not confirmed evidence.

### 11. Urgency overrode safety

The production incident created pressure to act quickly. The agent reduced verification scope instead of reducing change scope.

## What went well

- The original OpenRouter timeout was reconciled to Caddy status `0` and coordinator route latency.
- The global lock mechanism and cross-model amplification were correctly identified.
- PR #793 added strong concurrent reservation, pooled-budget, breaker, deadline, and shadow-telemetry tests.
- Candidate images were tied to exact merge SHAs and immutable Artifact Registry digests.
- Database lock and environment-integrity prechecks were performed.
- Root-only rollback state and immutable previous image IDs were captured before each swap.
- Each zero-capacity candidate was rolled back rather than left serving indefinitely.
- No persistent environment drift or database corruption was observed.
- Production returned to the known-working coordinator.

These positives do not offset the avoidable deployment attempts.

## Required architectural correction

### 1. One explicit provider authorization result

Create one evaluator used by routing, preflight, persistence, capability promotion, and release administration:

```go
type ProviderAuthorization struct {
    Eligible   bool
    Reason     ProviderEligibilityReason
    BinaryHash string
}
```

No subsystem should independently choose among registration, challenge, application, APNs, or trust-reuse hashes.

### 2. Minimal required authorization facts

A provider should become routable only when:

1. MDM/MDA establishes genuine Apple hardware and secure posture.
2. A fresh SE-signed nonce challenge binds the current process key.
3. The fresh challenge binary hash matches an active release for version, platform, and backend.
4. APNs code evidence is current and bound to the SE identity, token, and process key.

Release-global hashes for unrelated model templates must not be a provider-wide routing requirement. If metallib or other runtime enforcement is genuinely required, it must be an explicit separately observable predicate using the same scope as the existing runtime gate.

### 3. Closed rejection taxonomy

Every eligibility failure must produce a bounded non-sensitive reason:

- `missing_device_evidence`
- `missing_application_evidence`
- `missing_code_evidence`
- `inactive_binary`
- `release_runtime_mismatch`
- `metallib_mismatch`
- `template_scope_mismatch`
- `process_key_mismatch`
- `apns_token_mismatch`
- `policy_generation_mismatch`

No keys, serials, prompt content, raw hashes, or tokens should be logged.

### 4. Shadow before enforce

Trust-policy modes must be:

```text
off      preserve current production routing
shadow   evaluate and count failures without derouting
enforce  apply the gate
```

The first deployment of a new gate must be `shadow`.

### 5. Production-shaped compatibility fixture

Capture and sanitize:

- a real v0.8.15 registration;
- its signed challenge field shape;
- an active production release row;
- providers with different installed model subsets;
- a fresh process key after reconnect;
- APNs and continuity proof records.

The fixture must exercise the same evaluator used by production routing.

### 6. Canary capability

The system needs a way to evaluate or route a bounded provider cohort through a candidate policy before global enforcement. A single host-network cutover must not be the first compatibility test.

### 7. Preserve failed candidates

On acceptance failure:

1. rename the failed candidate;
2. capture logs, image, health, eligibility counters, and database evidence;
3. start the previous immutable image;
4. retain the failed container until the evidence is archived.

## Required deployment gate

No coordinator containing a new routing/trust gate may deploy globally until all are true:

- exact merge SHA and immutable digest verified;
- full coordinator tests pass, with known flakes separately reproduced and classified;
- production-shaped eligibility replay passes;
- shadow mode reports expected pass rates;
- every failed provider is explained by a closed reason;
- all expected models retain nonzero projected capacity;
- rollback image and environment backup validated;
- one bounded canary succeeds;
- operator explicitly approves the exact candidate digest.

Post-swap acceptance must require:

- expected build commit and digest;
- health and readiness;
- application-evidence grants;
- hardware and APNs proof recovery;
- all expected models present;
- nonzero routable capacity near the pre-swap baseline;
- real successful inference;
- bounded route latency and OpenRouter status-0 rate.

Any failure triggers immediate rollback before another candidate attempt.

## Immediate state and next action

Production is on the known-working `2d737d8...` coordinator. It should remain there.

The next action is not another deployment. It is to instrument the complete application-evidence evaluator, verify the remaining rejection against a real sanitized provider/release shape, remove unused release-global template authorization, and run the policy in shadow mode. Only a candidate that proves nonzero model capacity before enforcement should be considered deployable.

## Accountability statement

The agent caused avoidable production instability by deploying a merged revision without proving all newly introduced global routing gates against the real fleet, then repeating the deployment after only partially addressing the evidence chain. The correct standard was full end-to-end eligibility proof before the first swap. That standard was not met.

## Addendum (2026-08-31, post-incident investigation): root cause CONFIRMED and fixed

The "strongest current hypothesis" above is now proven with three independent evidence sources. Production has since been reverted further back, to `b234b9460ba0e1bdb031a831f092cd400e8c6be9` (pre-#787), and a fix branch exists.

### Confirmed failing predicate

`releaseRuntimeMatches` (`coordinator/api/server.go:1879-1883` at `3ac7b9bd3`) required the provider's challenge `template_hashes` to match **every** key on the release row's template map.

1. **DB (read-only, prod RDS):** every active release row (0.8.4 → 0.8.15) carries `template_hashes` with four family keys (`qwen3.5`, `trinity`, `gemma4`, `minimax`), `python_hash` and `runtime_hash` empty, `binary_hash` and `metallib_hash` present.
2. **Provider source (v0.8.15, the fleet build):** the challenge response's template vocabulary is exactly `{"mlx_metallib"}` (`ProviderLoop+Serve.swift` `augmentRuntimeHashesWithMetallib` is the sole producer); `python_hash`/`runtime_hash` are hardcoded nil; registration carries no top-level binary hash at all. No provider action (including downloading every model) can produce family template keys.
3. **Release CI:** the family keys are fabricated by `release-swift.yml` (curl CDN jinja files → shasum → POST `template_hashes`). They never existed on any provider.

Therefore application evidence was underivable for 100% of the fleet by construction; the routing chokepoint (`registry.go providerSupportsPrivateTextLocked`) makes evidence mandatory whenever any release row exists (`releasePolicyRequired`, data-driven, no env kill switch), producing exactly the observed zero-capacity/all-429 state on both candidate deploys. Hardware/continuity grants succeeded because the same-binary trust-reuse fast-skip does not depend on application evidence.

### Fix (branch `fix/release-policy-fleet-compat`, based on `3ac7b9bd3`)

- Application evidence now proves exactly: fresh SE-signed challenge `binary_hash` matches an active release row for (version, platform, backend) **and** the release `metallib_hash` matches the provider's reported `mlx_metallib`. Python/runtime/family-template facts removed from derivation, the sweep re-proof, the `ApplicationEvidence` struct, and release CI registration.
- Typed outcome counters (`release_evidence.outcome{outcome:...}`) on every derivation branch; coverage counters in `/v1/stats` (`application_evidence_providers` / `application_evidence_connected` / `release_policy_enforced`).
- Shadow/enforce rollout mode: `EIGENINFERENCE_RELEASE_POLICY_MODE` (default **shadow** — evidence tracked, never blocks routing; identical routing to the pre-gate coordinator). Enforcement is a separate, observed flip.
- Production-shape regressions: exact fleet wire shape (hashless registration, family-template release rows, metallib-only challenge) must derive evidence, survive the policy sweep, and stay routable; shadow mode must route an evidence-less fleet; metallib rotation must still fail closed.
- Staged rollout runbook: `docs/operations/release-policy-rollout.md`.
