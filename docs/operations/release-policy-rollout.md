# Roll out the release-policy routing gate (shadow → enforce)

> Last updated: 2026-09-04 · commit `ac60c5ada`

Runbook for the two production changes that involve the coordinator's
release-policy routing gate: (1) deploying a coordinator that contains the gate
in **shadow** mode, and (2) later flipping it to **enforce**. The gate decides
whether a provider that lacks *application evidence* (proof that its running
binary and metallib match an active release row) may receive routed requests.
Container swaps themselves follow
[`coordinator-deploy.md`](coordinator-deploy.md); this page adds the
gate-specific checks, acceptance criteria, and rollback lever.

## When to use

- First production deploy of any coordinator build that evaluates application
  evidence (the `EIGENINFERENCE_RELEASE_POLICY_MODE` switch in
  `coordinator/cmd/coordinator/main.go`).
- Turning enforcement on after shadow coverage has been proven.
- Turning enforcement back off (incident lever).

Do not use it to debug why one provider lacks evidence; that is the per-reason
counter table under Verification, and the fix is on the release-registration
side ([`provider-release.md`](provider-release.md)).

## Prerequisites

- **Human approval for each stage as a distinct operation.** The shadow deploy
  and the enforce flip are separate approvals; agents prepare commands and read
  endpoints only.
- SSH to the production VM and the pre-swap state from
  [`coordinator-deploy.md`](coordinator-deploy.md) (candidate image pinned by
  full commit SHA, database locks checked, `refresh-env.sh --check` clean).
- Baseline captured before the swap: `/v1/models/capacity` (models and
  `routable_providers` per model) and `/v1/stats` `active_providers`.
- Datadog access to the `release_evidence.outcome` counter (emitted by
  `coordinator/api/server.go` (`recordReleaseEvidenceOutcome`); no-op without
  DogStatsD).
- Read [Background](#background) once; the 2026-08-31 postmortem
  ([`../reports/2026-08-31-coordinator-agent-deployment-failure-postmortem.md`](../reports/2026-08-31-coordinator-agent-deployment-failure-postmortem.md))
  is why every step below exists.

### Background

The gate has two modes, chosen at boot from `EIGENINFERENCE_RELEASE_POLICY_MODE`
(`coordinator/cmd/coordinator/main.go`):

| Value | Behaviour | Startup log line |
|---|---|---|
| unset or `shadow` | Evidence is derived, granted, swept, and counted, but never blocks routing and never clears runtime capabilities | `release-policy routing gate in SHADOW mode (default): …` |
| `enforce` | After a boot grace, the routing chokepoint requires generation-current evidence and policy sweeps clear capabilities whose evidence was invalidated | `release-policy routing gate ENFORCED via EIGENINFERENCE_RELEASE_POLICY_MODE — …` with `boot_grace=<duration>` |
| anything else | Treated as shadow | `invalid EIGENINFERENCE_RELEASE_POLICY_MODE; staying in SHADOW mode` |

The boot grace defaults to `minEnforceGrace = 20 * time.Minute` and is
**raise-only**: `EIGENINFERENCE_RELEASE_POLICY_ENFORCE_GRACE` values below 20m
clamp up, invalid values keep 20m. It exists because a restarted coordinator has
an empty provider registry (zero evidence) and would otherwise 429 the whole
fleet until reconnected providers complete their first challenge cycle
(`DefaultChallengeInterval = 5 * time.Minute` in `coordinator/api/provider.go`).

Application evidence proves exactly two facts, checked identically at grant
(`coordinator/api/server.go` (`deriveApprovedReleaseTransition`,
`releaseMetallibMatches`)) and at every policy sweep
(`releaseEvidenceStillApproved`): the Secure-Enclave-signed challenge
`binary_hash` matches an **active** release row for the provider's (version,
platform, backend), and that row's `metallib_hash` matches the provider's
reported metallib. Nothing else — per-model template hashes were removed after
the incident.

Where the gate lives: `coordinator/registry/registry.go`
(`providerSupportsPrivateTextModeLocked`, the single routing chokepoint;
`releasePolicyEnforcedLocked`, mode + enforce-after predicate;
`SetReleasePolicyGeneration`, sweep that re-proves or clears evidence;
`CountProvidersWithCurrentApplicationEvidence` and
`ApplicationEvidenceModelCoverage`, the coverage counters served by
`coordinator/api/stats.go` (`handleStats`)).

## Steps

### Stage 1 — deploy in shadow

1. Confirm the env file is in shadow: `EIGENINFERENCE_RELEASE_POLICY_MODE` is
   absent from `/etc/d-inference/env` or set to `shadow`.

   ```bash
   sudo grep -E '^EIGENINFERENCE_RELEASE_POLICY_(MODE|ENFORCE_GRACE)=' /etc/d-inference/env || echo "absent → shadow"
   ```

2. Perform the approved container swap exactly as in
   [`coordinator-deploy.md`](coordinator-deploy.md) → Steps.
3. Confirm the startup log line.

   ```bash
   sudo docker logs coordinator 2>&1 | grep -E 'release-policy routing gate'
   ```

   Expected: `release-policy routing gate in SHADOW mode`. An `ENFORCED`
   warning here means the env file is wrong — go to [Rollback](#rollback).

4. Run the Stage 1 verification table for at least 20 minutes (four challenge
   cycles), then leave the build in shadow for **≥ 24 hours** before considering
   Stage 2.

### Stage 2 — flip to enforce

1. Confirm every Stage 2 acceptance row (below) held for ≥ 24 hours and that
   the flip has its own human approval.
2. Set the mode in the env file. Leave `EIGENINFERENCE_RELEASE_POLICY_ENFORCE_GRACE`
   unset (20m) unless a *longer* grace is wanted.

   ```bash
   sudo sed -i 's/^EIGENINFERENCE_RELEASE_POLICY_MODE=.*$/EIGENINFERENCE_RELEASE_POLICY_MODE=enforce/' /etc/d-inference/env
   sudo grep -q '^EIGENINFERENCE_RELEASE_POLICY_MODE=' /etc/d-inference/env || echo 'EIGENINFERENCE_RELEASE_POLICY_MODE=enforce' | sudo tee -a /etc/d-inference/env
   ```

3. Recreate the container with the **same image** (the swap procedure in
   [`coordinator-deploy.md`](coordinator-deploy.md), reusing the current image
   tag). Mode is read once at boot; there is no runtime toggle.
4. Confirm the startup log prints the `ENFORCED` warning with
   `boot_grace=20m0s` (or your longer value).

## Verification

`/v1/stats` is cached for one minute (`coordinator/api/stats.go`), so poll no
faster than that. Fields used below:

| `/v1/stats` field | Meaning | Source |
|---|---|---|
| `application_evidence_connected` | connected providers | `CountProvidersWithCurrentApplicationEvidence` (second return) |
| `application_evidence_providers` | connected providers holding generation-current evidence | `CountProvidersWithCurrentApplicationEvidence` (first return) |
| `application_evidence_models` | per model: `{"routable": n, "with_evidence": m}` — providers passing every routing gate except evidence, and the subset that also hold evidence | `ApplicationEvidenceModelCoverage` |
| `release_policy_enforced` | `true` only when mode is `enforce` **and** the boot grace has elapsed | `ReleasePolicyEnforced` |

### Stage 1 (shadow) — within 20 minutes of the swap

| Check | Requirement |
|---|---|
| `/health`, `/readyz` | ok; build commit matches the candidate |
| `/v1/models/capacity` | every expected model present; `routable_providers` near baseline (shadow cannot reduce this) |
| `application_evidence_connected` | ≈ pre-swap `active_providers` |
| `application_evidence_providers` | climbing; ≥ 90 % of connected within ~20 min |
| `application_evidence_models` | for **every** model, `with_evidence` ≈ `routable`. A small stable gap can be providers dispatch already excludes for other reasons; confirm via the outcome counters that the gap has a benign typed reason before treating it as a blocker |
| Datadog `release_evidence.outcome` | `outcome:granted` dominates; every other tag explained (table below) |
| Real inference | succeeds on every model family |

Closed outcome set (`coordinator/api/server.go`, constants next to
`recordReleaseEvidenceOutcome`):

| `outcome:` tag | Means |
|---|---|
| `granted` | evidence derived and installed |
| `precondition` | untrusted status fields, SIP/Secure Boot not reported enabled, or challenge loop stopping |
| `invalid_binary_hash` | challenge `binary_hash` is not 64 lowercase hex |
| `policy_unavailable` | release inventory snapshot missing |
| `policy_not_required` | the release inventory does not require evidence |
| `process_identity` | provider has no process public key or no valid attestation result (SE public key + serial) |
| `runtime_gate` | `RuntimeVerified`, `RuntimeManifestChecked`, or `MetallibVerified` is still false for the provider |
| `version_floor` | provider below the minimum version (expected for stragglers) |
| `registration_hash_mismatch` | challenge hash differs from the registration-time hash |
| `no_active_release` | hash matches no active release row (expected for dev builds) |
| `metallib_mismatch` | release row's `metallib_hash` differs from the provider's |

If coverage stalls near zero in shadow, routing is unharmed: diagnose from the
counters, fix release rows or the provider build, and do **not** flip enforce.

### Stage 2 (enforce)

| Phase | Requirement |
|---|---|
| During the grace | `release_policy_enforced` stays `false`; routing identical to shadow; coverage rebuilds as providers re-challenge |
| After the grace | `release_policy_enforced` flips `true`; per-model `routable_providers` in `/v1/models/capacity` stays within a few percent of `with_evidence`; no capacity drop; no change in 429 rate |

## Rollback

**Stage 1 (shadow) failures** are ordinary deploy failures. Export evidence
first, then run the rollback in [`coordinator-deploy.md`](coordinator-deploy.md):

```bash
sudo docker logs coordinator > /tmp/candidate-$(date +%Y%m%d-%H%M%S).log 2>&1
curl -fsS https://api.darkbloom.dev/v1/stats > /tmp/candidate-stats.json
```

The swap procedure keeps the previous container as
`coordinator_fallback_<timestamp>`; after rolling back, the failed candidate is
likewise preserved. Do not `docker rm` any preserved container until its logs
are archived — the 2026-08-31 investigation lost primary evidence that way.

**Stage 2 (enforce) misbehaviour** needs no image change: set
`EIGENINFERENCE_RELEASE_POLICY_MODE=shadow` in `/etc/d-inference/env` and
recreate the container with the same image. This is the incident lever.

## Invariants for anyone changing the gate

1. A new global trust gate ships in shadow first; enforcement is a separate,
   human-approved action after live coverage is proven.
2. `deriveApprovedReleaseTransition` and `releaseEvidenceStillApproved`
   (`coordinator/api/server.go`) compare the same fact set. Changing one side
   desynchronises grant from sweep and wipes evidence on every policy rebuild.
3. Never add a release-row fact to evidence derivation unless the production
   provider build demonstrably reports it — check
   `provider-swift/Sources/ProviderCore/Security/` and
   `provider-swift/Sources/ProviderCore/ProviderLoop+AttestationChallenge.swift`
   first.
4. Do not lower the boot grace for a production flip; the code clamps it to
   20m for this reason.
5. Registering a release must never deroute the fleet on the previous
   release. The runtime manifest is the union of every active release's
   hashes, so v(N−1) and v(N) both pass their challenges through the
   self-update window; hashes leave the manifest only when their release is
   deactivated ([`provider-release.md` → Rollback](provider-release.md#rollback)).
   Mechanism, flags, and the 2026-09-03 brownout that motivated the rule:
   [runtime manifest](../architecture/security/attestation.md#runtime-manifest).

## Related

- [`coordinator-deploy.md`](coordinator-deploy.md) — the container swap, env
  refresh, and rollback used by both stages.
- [`provider-release.md`](provider-release.md) — how release rows
  (binary hash, metallib hash, active flag) get registered.
- [`../architecture/security/attestation.md`](../architecture/security/attestation.md)
  — the challenge loop that produces the evidence.
- [`../reference/configuration.md`](../reference/configuration.md) — every
  coordinator environment variable.
- [`../reports/2026-08-31-coordinator-agent-deployment-failure-postmortem.md`](../reports/2026-08-31-coordinator-agent-deployment-failure-postmortem.md)
  — the incident that shaped this runbook.
