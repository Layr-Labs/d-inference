# Provider serving authorization

> Last updated: 2026-09-20 · commit `a981e3fbb`

The coordinator can authorize private inference through complete legacy verification or a qualified App Attest connection. These are separate evidence paths; App Attest never sets legacy MDA/APNs flags. The [rollout runbook](../operations/mdm-optional-rollout.md) separates code availability from activation qualification.

The [App Attest module map](../../coordinator/appattest/README.md) explains the verifier/service folders, thin integration adapters and package-local tests.

## Controls

| Control | Default and behavior | Code |
|---|---|---|
| `EIGENINFERENCE_APP_ATTEST_SERVING` | `false`; enable the independent App Attest serving path and its proof/receipt refresh worker | `coordinator/appattest/service/config.go` (`ConfigFromEnvironment`) |
| `EIGENINFERENCE_APP_ATTEST_MDM_REMOVAL` | `false`; allow qualified live providers to receive removal readiness; disabling this does not disable existing App Attest serving | Same |
| Existing shadow cohort and build qualification | Existing cohort, safe-version floor, production environment and exact qualified binary/CodeDirectory mappings still apply; a serving switch alone cannot qualify a build. Durable approvals override legacy env pairs | `coordinator/appattest/service/rollout.go` (`appAttestRolloutDecision`); `coordinator/appattest/service/build_qualifications.go` (`applyBuildQualification`) |
| Registration identity cohort | Use the authenticated token account and configured percentage in production; providers outside that cohort, including explicit macOS versions below 27, retain legacy history/MDA recovery and duplicate handling | `coordinator/appattest/service/authorization_identity.go` (`appAttestIdentityCandidate`) |
| Assertion freshness | `AssertionFreshness = 15 * time.Minute`; receipt and revocation deadlines may shorten it | `coordinator/appattest/authorization.go` (`EvaluateAuthorization`) |
| Durable revocation/receipt refresh | `appAttestAuthorizationRefresh = 5 * time.Second`, batched at most 1000 distinct keys per query | `coordinator/appattest/service/authorizer.go` (`refresh`) |
| First-proof readiness lookup failure | Without an existing authorizer record, request a fresh assertion after one minute, then five minutes, then the normal ten-minute cadence while the lookup remains unavailable. A known decision or retained refresh record resets the backoff; all identity and policy gates still apply before granting | `coordinator/appattest/service/retry.go` (`nextAssertionDelay`); `coordinator/appattest/service/authorization_identity.go` (`updateServingAuthorization`) |
| Revocation freshness ceiling | `appAttestRevocationFreshness = 30 * time.Second` from the query start; a failed read cannot renew it | Same (`apply`) |

## Durable build qualification

| Contract | Behavior | Code |
|---|---|---|
| Exact approved artifact | Binary, full CodeDirectory, bundle, metallib, version/platform/backend/URL, source commit and CI run; operator/test evidence retained separately from the public release catalog | `coordinator/store/app_attest_builds.go` (`AppAttestBuildIdentity`, `AppAttestBuildQualification`) |
| Approval API | Admin `GET/POST /v1/admin/app-attest/builds`; POST contains `release`, `code_directory_hash`, `source_commit`, `ci_run_id`, `evidence`. Attribution and timestamps are server-owned. A scoped CI release key cannot approve | `coordinator/api/app_attest_builds.go` (`handleAdminAppAttestBuilds`) |
| Publication gate | Production workflow sets `require_app_attest_qualification=true`; the coordinator also requires it whenever production App Attest serving is enabled. Missing/mismatched/revoked approval returns 409; unreadable policy returns 503; previous latest remains unchanged | `coordinator/api/app_attest_publication.go` (`persistReleaseForPublication`) |
| Qualification refresh | Poll every five seconds; `BuildQualificationFreshness = 30 * time.Second` from read start. Every lease recomputes qualification and full code match from retained verified Apple metadata; no I/O at dispatch | `coordinator/appattest/service/build_qualifications.go` (`RefreshBuildQualifications`, `applyBuildQualification`); `coordinator/appattest/service/authorizer.go` (`apply`) |
| Build withdrawal | Admin `POST /v1/admin/app-attest/builds/revoke` with `binary_hash` and `reason`; 200 includes `revoked`, `changed`, `max_propagation_seconds`. Local qualification generation fences before acknowledgement; remote/stale-store leases expire within 30 seconds. A build tombstone also overrides env-only approvals | `coordinator/api/app_attest_builds.go` (`handleAdminAppAttestBuildRevoke`); `coordinator/registry/app_attest_authorization.go` (`SetAppAttestQualificationGeneration`) |
| Failure and retry | Malformed approval 400, missing/invalid authentication 401, authenticated non-admin or non-interactive credentials 403, conflicting/revoked immutable identity 409, unavailable/pending durable policy 503. Idempotent retry preserves original audit evidence. Revocation never restores through approval retry | `coordinator/store/app_attest_builds_postgres.go` (`QualifyAppAttestBuild`, `SetQualifiedRelease`) |

The [qualification runbook](../operations/app-attest-build-qualification.md) gives the staged publication, migration and rollback procedure. Build withdrawal removes App Attest eligibility; it does not fabricate a credential violation or revoke independently valid legacy evidence.

## New-provider setup

| Local OS / state | Setup behavior | Code |
|---|---|---|
| macOS 27 or later | Skip MDM profile download and opening Settings; link account, start provider and wait for App Attest serving approval | `scripts/install.sh` (`configure_device_verification`); `provider-swift/Sources/ProviderCore/Auth/Enrollment.swift` (`EnrollmentService.enroll`) |
| Older macOS | Legacy enrollment with an explicit macOS 27 upgrade option and upcoming Darkbloom MDM deactivation notice | Same; `provider-swift/Sources/ProviderCore/Auth/ProviderOnboardingPolicy.swift` |
| Installer cannot parse the OS version | Download no profile; direct the user to `darkbloom enroll`, which uses the native OS version | `scripts/install.sh` (`configure_device_verification`) |
| App Attest disabled or unqualified | New macOS 27+ setup stays pending; status/doctor explain the missing authorization, without silently enrolling in MDM | `provider-swift/Sources/ProviderCore/Diagnostics/ProviderAuthorizationReadiness.swift` (`summary`); `provider-swift/Sources/ProviderCore/Diagnostics/MDMTrustDiagnosis.swift` (`diagnose`) |
| Existing Darkbloom or employer profile | Leave installed; Darkbloom removal still requires separate current readiness and local user action | `provider-swift/Sources/darkbloom/UnenrollCommand+KeepServing.swift` |

The setup page in `console-ui/src/components/provider-onboarding/content.ts`
explains the same OS choice and planned MDM deactivation. This notice sets no
retirement date and does not disable legacy serving.

## Serving decisions

| Condition | Result | Code |
|---|---|---|
| Complete legacy verification | Legacy behavior remains eligible, subject to existing common runtime/routing gates | `coordinator/registry/attestation_policy.go` (`providerSupportsPrivateTextModeAtLocked`) |
| Qualified App Attest assertion | Expiring authorization bound to authenticated account, verified machine, credential, connection, endpoint, approved policy and signed hardware | `coordinator/appattest/service/authorization_identity.go` (`updateServingAuthorization`); `coordinator/registry/app_attest_authorization.go` (`GrantAppAttestServingAuthorization`) |
| Verified credential before serving qualification | Track the current presenter and retained last-granted key for local and periodic revocation checks. This bounded connection state grants no permission and cannot replace a qualified proof record | `coordinator/registry/app_attest_presenter.go` (`RecordVerifiedAppAttestPresenter`, `VerifiedAppAttestPresenters`) |
| Expired authorization | No new App Attest-only dispatch; diagnostics and recovery remain possible | `coordinator/registry/inference_authorization.go` (`authorizeInferenceHandoff`) |
| Explicit credential revocation | Both paths are fenced for matching live connections, including a connection presenting a freshly verified revoked key before its first grant; late verifier results cannot restore the revoked credential | `coordinator/registry/app_attest_authorization.go` (`RevokeAppAttestCredential`); `coordinator/appattest/service/authorization_identity.go` (`updateServingAuthorization`) |
| Reconnect, endpoint/account change or policy generation change | Old authorization cannot be reused; cryptographic evidence is bound to the current connection and re-evaluated policy | Same |
| Transient Apple/key recovery failure | No extra permission or lifetime; an independently valid legacy path or existing unexpired authorization can remain available | `coordinator/appattest/service/policy.go` (`confirmedAppAttestViolation`) |
| Transient readiness lookup failure after a valid assertion | Preserve the prior bounded lease and refresh record; the next durable refresh can recover without waiting for another assertion. The failure itself cannot extend authorization | `coordinator/appattest/service/authorization_identity.go` (`updateServingAuthorization`); `coordinator/appattest/service/authorizer.go` (`refresh`) |
| Archive gap or missing required code/receipt evidence | Unknown/ineligible, never permission to remove MDM | `coordinator/appattest/authorization.go` (`EvaluateAuthorization`) |

The final write check occurs after frame construction and owner handoff, before the socket write. That check is the dispatch linearization point. Invalidation fences later handoffs; a frame already committed to the writer is in flight and cannot be recalled. Registry locks are not held over network I/O. All direct, retry, cold and queued dispatches use `coordinator/api/provider_dispatch_write.go` (`writeProviderInferenceRequestDeferred`). Preparation sets provisional owner timing, but only a committed handoff publishes dispatch counts/profile stamps; a rejected frame clears that provisional timestamp. Cancellation while waiting for final authorization does not close a healthy provider socket.

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

`darkbloom status` and `darkbloom doctor` distinguish App Attest authorization from legacy verification. `darkbloom unenroll` offers full exit or App Attest migration. The migration option and direct `--keep-serving` shortcut require macOS 27 or later and a fresh running-provider snapshot, matching coordinator and process identity, and an unexpired removal-ready authorization. Both the state-file write and receipt of the coordinator decision must be at most `snapshotMaxAge = 10` seconds old (`provider-swift/Sources/ProviderCore/Diagnostics/ProviderAuthorizationReadiness.swift`, `currentStatus`); periodic local writes cannot refresh an old removal decision. It preserves account/config/key data and opens System Settings only after identifying the exact Darkbloom enrollment. It never removes a company profile or the app's embedded signing profile. Full exit stops the provider service before offering profile removal and optional cleanup. Enter/EOF cancels; noninteractive use requires an explicit mode flag. Code: `provider-swift/Sources/darkbloom/UnenrollCommand+KeepServing.swift` and `provider-swift/Sources/ProviderCore/Security/DarkbloomMDMRemoval.swift`.

## Owner dashboard and upgrade guidance

The setup page prominently explains macOS 27 and planned MDM deactivation.
The provider dashboard warns machines whose `os_version` reports an older OS,
separates unknown versions, and identifies reports retained for offline Macs.
The upgrade warning is informational: it does not make an otherwise eligible
legacy machine unroutable. Every CLI invocation on older macOS also warns on
stderr; see the [CLI reference](../provider/cli-reference.md#global-options).

`coordinator/api/me_authorization.go` supplies the owner dashboard with a
current App Attest verdict and expiry, independently of legacy trust fields.
The UI uses `console-ui/src/app/providers/authorization.ts`
(`hasCurrentAppAttestAuthorization`) to suppress legacy-only trust/challenge
warnings for a currently authorized connection. Runtime failure, offline and
untrusted states remain blocking. The expiry timer in
`console-ui/src/app/providers/dashboard/useCurrentAuthorizations.ts` removes
cached authorization even if a fleet poll fails. These are display decisions;
backend dispatch authorization remains authoritative, and profile removal still
requires the CLI's separate fresh readiness check.

## Machine identity and base rewards

| Behavior | Contract | Code |
|---|---|---|
| Canonical history | Fresh verified account/credential association; a later canonical merge can supply a previously missing historical baseline. Apply the baseline once, preserving live trust and current-session work without adding overlapping cumulative snapshots twice | `coordinator/store/machine_continuity.go` (`MachineOperationalStore`); `coordinator/registry/machine_history.go` (`MergeVerifiedMachineHistory`) |
| Base-reward eligibility | Current complete serving authorization, public model readiness and hardware measured inside the qualified signed app; existing memory caps, uptime and pool/account limits continue | `coordinator/payments/baserewards/machine_candidates.go` (`rewardSnapshotEligible`, `rewardMemoryGB`) |
| Duplicate sessions | Union overlapping uptime and sum only matching-account organic earnings across original encryption keys | Same (`buildCandidates`) |
| Settlement identity | New canonical floors use `machine:<canonical ID>`; original ledger rows/balances remain intact | `coordinator/store/machine_floor_settlement.go` (`MachineFloorKey`) |
| Rotation and merge races | Resolve canonical aliases inside the settlement transaction, including previously raw candidates, before checking same-epoch floors | `coordinator/store/postgres_machine_floor_settlement.go` (`SettleMachineFloorDraw`); `coordinator/store/machine_floor_settlement.go` (`SettleProviderFloorDrawForSession`) |
| Authorization changes during allocation | Commit the remaining plan atomically, including partial and zero-value rows. A late rejection rolls back that plan and reallocates its unspent budget; prior finalized rows and account/pool caps remain intact | `coordinator/payments/baserewards/settlement_plan.go` (`settleCandidatePlan`); `coordinator/store/floor_draw_batch.go` (`FloorDrawBatchStore`) |
| Pending session inventory | A same-account durable endpoint association can resolve the canonical reward identity; ambiguous associations cannot authorize a credit | `coordinator/store/machine_floor_settlement.go` (`resolveSessionFloorDrawLocked`); `coordinator/store/postgres_machine_floor_settlement.go` (`resolveSessionFloorDraw`) |

Canonical identities deduplicate verified known associations. They do not prove physical uniqueness across deliberate reinstalls/new accounts, and App Attest does not independently certify RAM. These remain abuse-policy limits; the receipt fraud metric is a signal rather than a unique device identifier. Existing account/pool caps are retained.

Owned/self-route traffic retains the existing authenticated-owner policy. Every final handoff still checks its applicable policy; the public fleet floor and base rewards do not inherit that owner relaxation.

## Admin revocation

`POST /v1/admin/app-attest/revoke` requires existing admin authentication. Body: `{"key_id":"…","account_id":"…","reason":"operator_revoked"}`. Unknown/mismatched account keys return 404; malformed input returns 400; unavailable durable storage returns 503. An accepted/idempotent revocation returns `{"revoked":true,"changed":true,"max_propagation_seconds":30}` (`changed` is false for a repeat). The accepting coordinator checks credential ownership before the durable write and fences locally immediately after it succeeds, even if the request deadline is then exhausted. Each denied live provider also moves to nonrecoverable `untrusted` status, with online/model counters decremented once; status-only model availability, version/coverage metrics and idle capacity exclude it. A repeated denial or later disconnect does not decrement again. The connected socket remains available for diagnostics. All credential/presenter denial entry points use `coordinator/registry/app_attest_denial.go` (`denyAppAttestProviderLocked`). Other coordinators converge through the bounded durable refresh. Code: `coordinator/api/app_attest_revocation.go` (`handleAdminAppAttestRevoke`).

Proofs, original/renewed receipts, machine associations and assertion counters retain the [existing private archive](app-attest-shadow.md#storage-and-complete-evidence-archive). A refreshed serving lease is a current policy decision, not a new Apple signature. DeviceCheck's two-bit API remains unused.
