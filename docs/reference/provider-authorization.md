# Provider serving authorization

> Last updated: 2026-09-15 · commit `605651bb9`

The coordinator can authorize private inference through complete legacy verification or a qualified App Attest connection. These are separate evidence paths; App Attest never sets legacy MDA/APNs flags. The [rollout runbook](../operations/mdm-optional-rollout.md) separates code availability from activation qualification.

## Controls

| Control | Default and behavior | Code |
|---|---|---|
| `EIGENINFERENCE_APP_ATTEST_SERVING` | `false`; enable the independent App Attest serving path and its proof/receipt refresh worker | `coordinator/api/app_attest_shadow_config.go` (`readAppAttestShadowConfig`) |
| `EIGENINFERENCE_APP_ATTEST_MDM_REMOVAL` | `false`; allow qualified live providers to receive removal readiness; disabling this does not disable existing App Attest serving | Same |
| Existing shadow cohort and build qualification | Existing cohort, safe-version floor, production environment and exact qualified binary/CodeDirectory mappings still apply; a serving switch alone cannot qualify a build | `coordinator/api/app_attest_rollout.go` (`appAttestRolloutDecision`); `coordinator/api/app_attest_build_policy.go` (`qualifiedAppAttestMeasurement`) |
| Assertion freshness | `AssertionFreshness = 15 * time.Minute`; receipt and revocation deadlines may shorten it | `coordinator/appattest/authorization.go` (`EvaluateAuthorization`) |
| Durable revocation/receipt refresh | `appAttestAuthorizationRefresh = 5 * time.Second`, batched at most 1000 distinct keys per query | `coordinator/api/app_attest_authorizer.go` (`refresh`) |
| Revocation freshness ceiling | `appAttestRevocationFreshness = 30 * time.Second` from the query start; a failed read cannot renew it | Same (`apply`) |

## Serving decisions

| Condition | Result | Code |
|---|---|---|
| Complete legacy verification | Legacy behavior remains eligible, subject to existing common runtime/routing gates | `coordinator/registry/attestation_policy.go` (`providerSupportsPrivateTextModeAtLocked`) |
| Qualified App Attest assertion | Expiring authorization bound to authenticated account, verified machine, credential, connection, endpoint, approved policy and signed hardware | `coordinator/api/app_attest_authorization_identity.go` (`updateServingAuthorization`); `coordinator/registry/app_attest_authorization.go` (`GrantAppAttestServingAuthorization`) |
| Expired authorization | No new App Attest-only dispatch; diagnostics and recovery remain possible | `coordinator/registry/inference_authorization.go` (`authorizeInferenceHandoff`) |
| Explicit credential revocation | Both paths are fenced for matching live connections; late verifier results cannot restore the revoked credential | `coordinator/registry/app_attest_authorization.go` (`RevokeAppAttestCredential`) |
| Reconnect, endpoint/account change or policy generation change | Old authorization cannot be reused; cryptographic evidence is bound to the current connection and re-evaluated policy | Same |
| Transient Apple/key recovery failure | No extra permission or lifetime; an independently valid legacy path or existing unexpired authorization can remain available | `coordinator/api/app_attest_shadow_policy.go` (`confirmedAppAttestViolation`) |
| Archive gap or missing required code/receipt evidence | Unknown/ineligible, never permission to remove MDM | `coordinator/appattest/authorization.go` (`EvaluateAuthorization`) |

The final write check occurs after frame construction and owner handoff, before the socket write. That check is the dispatch linearization point. Invalidation fences later handoffs; a frame already committed to the writer is in flight and cannot be recalled. Registry locks are not held over network I/O. All direct, retry, cold and queued dispatches use `coordinator/api/consumer.go` (`writeProviderInferenceRequestDeferred`).

## Provider diagnostics

The additive `trust_status.authorization` object is coordinator-to-provider only. Legacy `trust_level` retains its meaning. Code: `coordinator/protocol/provider_authorization.go` (`ProviderServingAuthorization`), mirrored in `provider-swift/Sources/ProviderCore/Protocol/ProviderAuthorizationStatus.swift`.

| Field | Meaning |
|---|---|
| `protocol` | `1`; unknown versions never permit migration |
| `app_attest_available` | Coordinator supports the enabled path; not proof of this Mac's eligibility |
| `path` | `legacy`, `app_attest`, or `none` |
| `expires_at` | Exclusive Unix-seconds deadline for current App Attest authorization |
| `mdm_removal_ready` | Current full App Attest authorization plus explicit removal rollout |
| `reason` | Operator-facing bounded policy explanation |
| `session_id`, `machine_id` | Current connection and verified canonical machine; never caller-selected authorization |

`darkbloom status` and `darkbloom doctor` distinguish App Attest authorization from legacy verification. `darkbloom unenroll --keep-serving` requires a fresh running-provider snapshot, matching coordinator and process identity, and an unexpired removal-ready authorization. It preserves account/config/key data and opens System Settings only after identifying the exact Darkbloom enrollment. It never removes a company profile or the app's embedded signing profile. Code: `provider-swift/Sources/darkbloom/UnenrollCommand+KeepServing.swift` and `provider-swift/Sources/ProviderCore/Security/DarkbloomMDMRemoval.swift`.

## Machine identity and base rewards

| Behavior | Contract | Code |
|---|---|---|
| Canonical history | Fresh verified account/credential association; late history reconciliation preserves live trust and current-session work | `coordinator/store/machine_continuity.go` (`MachineOperationalStore`); `coordinator/registry/machine_history.go` (`MergeVerifiedMachineHistory`) |
| Base-reward eligibility | Current complete serving authorization, public model readiness and hardware measured inside the qualified signed app; existing memory caps, uptime and pool/account limits continue | `coordinator/payments/baserewards/machine_candidates.go` (`rewardSnapshotEligible`, `rewardMemoryGB`) |
| Duplicate sessions | Union overlapping uptime and sum only matching-account organic earnings across original encryption keys | Same (`buildCandidates`) |
| Settlement identity | New canonical floors use `machine:<canonical ID>`; original ledger rows/balances remain intact | `coordinator/store/machine_floor_settlement.go` (`MachineFloorKey`) |
| Rotation and merge races | Resolve canonical aliases inside the settlement transaction, including previously raw candidates, before checking same-epoch floors | `coordinator/store/postgres_machine_floor_settlement.go` (`SettleMachineFloorDraw`); `coordinator/store/machine_floor_settlement.go` (`SettleProviderFloorDrawForSession`) |

Canonical identities deduplicate verified known associations. They do not prove physical uniqueness across deliberate reinstalls/new accounts, and App Attest does not independently certify RAM. These remain abuse-policy limits; the receipt fraud metric is a signal rather than a unique device identifier. Existing account/pool caps are retained.

Owned/self-route traffic retains the existing authenticated-owner policy. Every final handoff still checks its applicable policy; the public fleet floor and base rewards do not inherit that owner relaxation.

## Admin revocation

`POST /v1/admin/app-attest/revoke` requires existing admin authentication. Body: `{"key_id":"…","account_id":"…","reason":"operator_revoked"}`. Unknown/mismatched account keys return 404; malformed input returns 400; unavailable durable storage returns 503. An accepted/idempotent revocation returns `{"revoked":true,"changed":true,"max_propagation_seconds":30}` (`changed` is false for a repeat). The accepting coordinator fences before responding. Other coordinators converge through the bounded durable refresh. Code: `coordinator/api/app_attest_revocation.go` (`handleAdminAppAttestRevoke`).

Proofs, original/renewed receipts, machine associations and assertion counters retain the [existing private archive](app-attest-shadow.md#storage-and-complete-evidence-archive). A refreshed serving lease is a current policy decision, not a new Apple signature. DeviceCheck's two-bit API remains unused.
