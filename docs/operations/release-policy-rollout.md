# Release-Policy Gate Rollout (Application Evidence)

Authoritative procedure for the first deployment of any coordinator containing
the release-policy routing gate, and for the later enforcement flip. Follows
[`coordinator-deploy.md`](coordinator-deploy.md) for the mechanics of every
swap; this document adds the gate-specific stages and acceptance criteria.

Canonical code (code wins over this doc):

| Behavior | Code |
|---|---|
| Mode parsing + boot grace | `coordinator/cmd/coordinator/main.go` (`EIGENINFERENCE_RELEASE_POLICY_MODE` switch) |
| Routing chokepoint + evidence gate | `coordinator/registry/registry.go:providerSupportsPrivateTextModeLocked` |
| Live-enforcement predicate (mode + enforce-after) | `coordinator/registry/registry.go:releasePolicyEnforcedLocked` |
| Evidence derivation + typed outcomes | `coordinator/api/server.go:deriveApprovedReleaseTransition`, `releaseMetallibMatches` |
| Sweep re-proof / invalidation | `coordinator/api/server.go:releaseEvidenceStillApproved`, `coordinator/registry/registry.go:SetReleasePolicyGeneration` |
| Coverage counters | `coordinator/registry/registry.go:CountProvidersWithCurrentApplicationEvidence`, `ApplicationEvidenceModelCoverage`; served by `coordinator/api/stats.go` |

## Background

On 2026-08-31 two candidate coordinators connected ~1,250 providers and
admitted zero for routing: release rows carried CI-fabricated per-model-family
`template_hashes` no provider has ever reported, the evidence gate demanded
them, and every rejection was an untyped `false`. `/v1/models/capacity`
returned no models and all inference received 429 until rollback
(`docs/reports/2026-08-31-coordinator-agent-deployment-failure-postmortem.md`).

The reworked contract: application evidence proves that the SE-signed
challenge `binary_hash` matches an **active release row** for (version,
platform, backend) and that the release's `metallib_hash` matches the
provider's reported `mlx_metallib` — nothing else. The gate has two modes via
`EIGENINFERENCE_RELEASE_POLICY_MODE`:

- `shadow` (default, also on unset/invalid): evidence is derived, granted,
  swept, and counted, but never blocks routing or clears runtime capabilities.
- `enforce`: after a boot grace (default 20m,
  `EIGENINFERENCE_RELEASE_POLICY_ENFORCE_GRACE`), the chokepoint requires
  generation-current evidence and policy sweeps clear capabilities with
  invalidated evidence.

## Invariants

- A new global trust gate MUST ship in shadow first; enforcement is a separate
  human-approved action after live coverage is proven.
- Never add a release-row fact to evidence derivation unless the production
  provider build demonstrably reports it (check
  `provider-swift/Sources/ProviderCore/Security/` and
  `ProviderLoop+AttestationChallenge.swift` first).
- `deriveApprovedReleaseTransition` and `releaseEvidenceStillApproved` MUST
  compare the same fact set; changing one side alone desyncs grant from sweep
  and wipes evidence every policy rebuild.
- Enforcement flips happen via env + container recreate; the boot grace exists
  because a restarted coordinator has an empty registry (zero evidence) and
  would otherwise 429 the fleet until first challenges complete. Do not set
  the grace below the default for a production flip.
- Registering a release MUST NOT deroute the fleet running the previous
  release. The runtime manifest (`SyncRuntimeManifest`) is the UNION of every
  ACTIVE release row's hashes — one accepted set per template name,
  `mlx_metallib` included — so providers on v(N-1) and v(N) both pass the
  challenge runtime policy for the whole self-update window. Deactivating a
  release (`DELETE /v1/admin/releases`) is the only way to retire its hashes.
  A manifest gate that keeps a single expected value per key is the
  2026-09-03 brownout: registering v0.8.16 replaced the v0.8.15 metallib hash
  and ~1,180 still-current providers were excluded from routing at their next
  challenge until they self-updated. Regression tests:
  `coordinator/api/runtime_manifest_union_test.go`.

## Stage 1 — shadow deployment

### Prerequisites

- Candidate image built by the repository trigger from the exact reviewed
  merge SHA; digest verified in Artifact Registry.
- `/etc/d-inference/env` has `EIGENINFERENCE_RELEASE_POLICY_MODE=shadow` (or
  the variable absent).
- All prechecks from [`coordinator-deploy.md`](coordinator-deploy.md)
  (database locks, env integrity, rollback state captured).
- Baseline captured for comparison: `/v1/models/capacity` (models +
  routable_providers per model) and `/v1/stats` (`active_providers`).

### Steps

1. Perform the approved swap per [`coordinator-deploy.md`](coordinator-deploy.md).
2. Confirm the startup log prints `release-policy routing gate in SHADOW mode`
   (an `ENFORCED` warning here means the env is wrong — roll back).

### Verification (within 20 minutes; challenges run every 5)

| Check | Requirement |
|---|---|
| `/health`, `/readyz` | ok, expected build commit |
| `/v1/models/capacity` | all expected models present; routable counts near baseline (shadow cannot zero this) |
| `/v1/stats` `application_evidence_connected` | ≈ pre-swap `active_providers` |
| `/v1/stats` `application_evidence_providers` | climbing toward connected; ≥90% within ~20 min |
| `/v1/stats` `application_evidence_models` | for EVERY model: `with_evidence` ≈ `routable` (per-model criterion — a small family's uncovered providers must not hide inside the fleet average). The denominator is the advertised-catalog surface, not full dispatch: a small persistent gap can be providers dispatch already excludes (e.g. the dedicated-model rule). Before treating a stable gap as a blocker, confirm via `release_evidence.outcome` that the uncovered providers have a benign typed reason. |
| Datadog `release_evidence.outcome` | `granted` dominates; every other reason explained (`version_floor` stragglers, `no_active_release` dev builds) |
| Real inference | succeeds on every model family |

If coverage stalls near zero: routing is unharmed; diagnose from the outcome
counters. Do NOT flip enforce and do NOT redeploy guesses.

### Rollback

Shadow-stage failures are ordinary deploy failures. Before any rollback:

1. Export evidence FIRST: `sudo docker logs coordinator > /tmp/candidate-<ts>.log`,
   plus `/v1/stats` and the outcome counters.
2. Then run the canonical rollback in
   [`coordinator-deploy.md`](coordinator-deploy.md). It replaces the container
   named `coordinator` with the previous image; the failed candidate container
   is preserved under a `coordinator_fallback_<ts>`-style name by the
   procedure's container swap. Do not `docker rm` any preserved candidate or
   fallback container until its logs and state are archived (the 2026-08-31
   investigation lost primary evidence to exactly that).

## Stage 2 — enforcement flip

### Prerequisites

- Stage 1 verification has held for ≥ 24 hours.
- Per-model coverage (`application_evidence_models`) shows
  `with_evidence` ≈ `routable` for every model, and fleet-wide
  `application_evidence_providers` ≈ `application_evidence_connected`.
- Human approval for the flip as a distinct operation.

### Steps

1. Set `EIGENINFERENCE_RELEASE_POLICY_MODE=enforce` in
   `/etc/d-inference/env`. Leave
   `EIGENINFERENCE_RELEASE_POLICY_ENFORCE_GRACE` unset (20m default) unless a
   longer grace is wanted.
2. Recreate the container per [`coordinator-deploy.md`](coordinator-deploy.md).
3. Confirm the startup log prints the ENFORCED warning with `boot_grace=20m0s`.

### Verification

- During the grace: routing identical to shadow (`release_policy_enforced`
  in `/v1/stats` stays `false`); coverage rebuilds as providers re-challenge.
- After the grace elapses: `release_policy_enforced` flips `true`; routable
  provider counts stay within a few percent of `application_evidence_providers`;
  no capacity drop; no 429-rate change; per-model capacity unchanged.

### Rollback

Set `EIGENINFERENCE_RELEASE_POLICY_MODE=shadow` and recreate the container —
no image change. This is the incident lever if enforcement ever misbehaves.
