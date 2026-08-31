# Release-Policy Gate Rollout (Application Evidence)

Status: authoritative for the first deployment of any coordinator containing
the release-policy routing gate (`releasePolicyRequired` +
`ApplicationEvidence`, introduced by #778, made deployable by
`fix/release-policy-fleet-compat`).

## Background — why this runbook exists

On 2026-08-31 two candidate coordinators built from master connected the full
production fleet (~1,250 providers) and admitted **zero** of them for routing.
`/v1/models/capacity` returned no models and every inference request received
429 until rollback. Root cause chain:

1. Release rows carry CI-fabricated per-model-family `template_hashes`
   (`qwen3.5`, `trinity`, `gemma4`, `minimax`) hashed from CDN jinja files by
   `release-swift.yml`. No provider build has ever reported those keys — the
   provider's entire challenge template vocabulary is `{"mlx_metallib"}`, and
   `python_hash`/`runtime_hash` are hardcoded nil (there is no Python runtime).
2. `releaseRuntimeMatches` required the provider's challenge to echo **every**
   release-row template hash → application evidence was underivable for 100%
   of the fleet by construction.
3. The routing chokepoint made evidence mandatory whenever any release row
   exists (`releasePolicyRequired`, data-driven, no kill switch) → zero
   routable providers, zero capacity, all-429.
4. Every rejection branch returned a bare `false` — the failure was
   undiagnosable from the outside during both deploys.

The fix changed the contract:

- Application evidence proves exactly: **SE-signed challenge binary hash
  matches an active release row for (version, platform, backend), and the
  release's metallib hash matches the provider's reported `mlx_metallib`.**
- Python/runtime/per-family-template facts are gone from evidence derivation,
  the sweep re-proof (`releaseEvidenceStillApproved`), the
  `ApplicationEvidence` struct, and release CI registration.
- Every derivation outcome is a typed counter:
  `release_evidence.outcome{outcome:granted|precondition|invalid_binary_hash|
  policy_unavailable|policy_not_required|process_identity|runtime_gate|
  version_floor|registration_hash_mismatch|no_active_release|metallib_mismatch}`.
- The routing gate has two modes via `EIGENINFERENCE_RELEASE_POLICY_MODE`:
  - `shadow` (default, and default when unset/invalid): evidence is derived,
    granted, swept, and counted, but NEVER blocks routing. Routing behavior is
    identical to the pre-release-policy coordinator.
  - `enforce`: the routing chokepoint requires generation-current evidence.
- Coverage instrumentation: `/v1/stats` exposes
  `application_evidence_providers`, `application_evidence_connected`, and
  `release_policy_enforced`.

## Invariants (do not violate)

- A brand-new global trust gate MUST ship in shadow first. Enforcement is a
  separate, human-approved action taken only after coverage is proven on the
  live fleet.
- Never add a release-row fact to evidence derivation unless the production
  provider build demonstrably reports it (verify in
  `provider-swift/Sources/ProviderCore/Security/` before trusting a fixture).
- `releaseEvidenceStillApproved` and `deriveApprovedReleaseTransition` must
  compare the same fact set; retuning one side alone silently desyncs the
  sweep from the grant and wipes evidence every policy rebuild.
- Production deploys follow `docs/operations/coordinator-deploy.md` (human
  approval, prechecks, rollback state). This runbook adds gate-specific
  acceptance criteria; it does not replace the deploy runbook.

## Stage 0 — preflight (before any swap)

1. Candidate image built by the repository trigger from the exact reviewed
   merge SHA; digest verified against Artifact Registry.
2. `EIGENINFERENCE_RELEASE_POLICY_MODE` is `shadow` or absent in
   `/etc/d-inference/env`.
3. Startup log line confirms mode: `release-policy routing gate in SHADOW
   mode` (or the loud ENFORCED warning — abort if present).
4. Capture the current-production baseline for acceptance comparison:
   `/v1/models/capacity` (models, routable_providers per model) and
   `/v1/stats` (`active_providers`).

## Stage 1 — shadow deployment

Perform the approved swap per the deploy runbook. Acceptance within 20
minutes (one full challenge cycle is 5 minutes; trust reconstruction dominates
the first minutes):

| Check | Requirement |
|---|---|
| `/health`, `/readyz` | ok, expected build commit |
| `/v1/models/capacity` | all expected models present; routable counts near the pre-swap baseline (shadow mode cannot zero this) |
| `/v1/stats` `application_evidence_connected` | near pre-swap `active_providers` |
| `/v1/stats` `application_evidence_providers` | climbing toward connected as challenges complete; expect ≥90% of connected within ~20 min |
| `release_evidence.outcome` in Datadog | `granted` dominates; every non-granted reason explained (e.g. `version_floor` for pre-floor stragglers, `no_active_release` for unregistered dev builds) |
| Real inference | succeeds on every model family |

If `application_evidence_providers` stalls near zero: the gate is still
incompatible with the fleet. Routing is unharmed (shadow), production stays
up. Diagnose from the outcome counters — do NOT flip enforce, do NOT iterate
by redeploying guesses.

## Stage 2 — enforcement flip (separate approval)

Only after Stage 1 acceptance has held for at least 24 hours:

1. Set `EIGENINFERENCE_RELEASE_POLICY_MODE=enforce` in
   `/etc/d-inference/env`; recreate the container per the deploy runbook.
2. Acceptance: identical to Stage 1 PLUS routable provider counts within a
   few percent of `application_evidence_providers`, no capacity drop, no 429
   rate change.
3. Rollback lever: set the mode back to `shadow` and recreate — no image
   change required.

## Failure handling

On any acceptance failure: preserve the candidate container (rename, do not
remove) and export its logs plus `/v1/stats` and the outcome counters BEFORE
starting the previous image. The 2026-08-31 investigation was materially
slowed because failed candidates were destroyed during rollback.
