# Hybrid provider trust model review

> Last updated: 2026-09-27 · commit `0bd16a9fa`

This review records the September 27 coexistence of legacy MDM/APNs and App Attest in source and focused tests. It updates the [canonical threat model](../threat-model.yaml) and [provider trust explanation](../architecture/security/provider-trust.md). It does not reassess unrelated historical findings or claim that the live fleet has adopted particular settings.

## Assessment

Both authorization paths remain implemented. Public serving accepts independently valid legacy verification **or** a qualified current App Attest authorization, together with common runtime, privacy, liveness and model gates. A connection may hold both; requiring both universally would incorrectly reject App Attest-only providers. A legacy `self_signed` label can coexist with a current App Attest grant. Shadow evidence, enrollment success and optional diagnostics alone cannot authorize serving.

Source: `coordinator/registry/attestation_policy.go` (`providerSupportsPrivateTextAuthorizationAtLocked`), `coordinator/registry/app_attest_authorization.go` (`providerTrustMeetsMinimumAtLocked`, `providerChallengeFreshAtLocked`) and `coordinator/registry/routing_eligibility.go` (`providerLivenessGateReasonLocked`).

## Corrections to the model

| Previous ambiguity or overclaim | Current interpretation |
|---|---|
| App Attest is observation-only; MDM/APNs is always authoritative | Shadow remains observation-only, but separately enabled and qualified App Attest supplies an independent serving path |
| All providers need the legacy SIP/challenge/APNs evidence | Qualified App Attest substitutes for specific legacy evidence requirements; common runtime/privacy checks remain |
| Pending MDM/MDA makes any `self_signed` provider publicly routable | Registration is not permission; public trust floor and shared gates still apply, with a separate authenticated-owner policy |
| MDA grants the hardware level | MDM SecurityInfo grants legacy hardware; MDA is separately attached device evidence |
| A self-signature proves hardware provenance and measured runtime facts | It proves possession of the signing key; independent Apple/MDM evidence and applicable policy are separate |
| App Attest proves hardware uniqueness, RAM and correct inference | It binds credential/code/access-policy evidence and app-origin claims; physical uniqueness, RAM certification and computation proofs do not follow |
| A prior grant or badge can authorize a queued write | Final handoff reevaluates the live connection and policy; revocation cannot recall already committed frames |
| MDM removal follows automatically from enrollment | Serving and removal are separate opt-ins; fresh current readiness and exact local profile targeting precede user action |

The canonical YAML adds `A-015`–`A-017`, `TB-011` and `T-052`–`T-058` for credential/evidence custody, live authorization, build qualification, replay/revocation races, continuity/rewards, runtime limits, migration availability and diagnostic privacy. It corrects the relevant existing legacy boundaries and outage/trust-elevation entries. Older unrelated entries retain their existing review scope and identifiers.

Legacy trust-reuse windows enforce a timing policy; the premise that a posture-changing recovery round trip cannot fit those windows is a physical qualification assumption. Likewise, a public nonce binding does not let an attacker forge Apple's MDA signature. These distinctions prevent a source-enforced check from being described as a stronger hardware theorem.

Build qualification retains a compatibility path for existing deployments: full Apple code measurements may match exact configured build/code mappings if no durable row exists and the snapshot is fresh. Durable rows and tombstones override this fallback; truncated measurements and new publication require durable qualification (`coordinator/appattest/service/build_qualifications.go`, `applyBuildQualification`).

## September 27 master refresh

The latest master preserves the independent legacy and App Attest serving paths while removing obsolete client compatibility. The model now distinguishes these changes:

- Only App Attest protocol 3 receives exchange frames; stored protocol 0/1/2 enrollment transcripts cannot resume. This replaces the fixed claimed-version gate without treating a protocol advertisement as code evidence (`service/session.go`, `startAppAttestShadow`; `service/context.go`, `prepareClientHash`; `authorization.go`, `EvaluateAuthorization`, all under `coordinator/appattest/`).
- Registration freshness is mandatory for every claimed provider version. An attested SE-key challenge now fails on missing/empty status signatures, and an omitted Secure Boot report fails like an omitted SIP report (`coordinator/api/provider.go`, `verifyProviderAttestation`, `verifyChallengeResponse`). The replay entry `T-033` describes the bounded timestamp and fresh possession checks without claiming a signed blob cannot be copied.
- The configured fleet version floor also excludes missing versions. The sanitized production reference sets `0.9.5`; the live deployment value was not inspected (`coordinator/api/server.go`, `belowMinProviderVersion`; `deploy/environments/prod.env`).
- Retired Python/runtime and hypervisor canonical fields, SE v1-key migration and the old on-disk X25519-key sweep stay removed. The hybrid model does not restore those compatibility paths. The independent full-measurement qualification fallback described above still exists and remains bounded by durable policy.

## Evidence and validation

Reviewed source at `0bd16a9fa5d6db3ba8c8c42a2017ad4a9294eb57` after merging the compatibility removal in #1208:

- Coordinator proof/policy: `coordinator/appattest/verify.go`, `authorization.go`, `service/authorization_identity.go`, `service/authorizer.go` and `service/build_qualifications.go`.
- Shared and owner routing: `coordinator/registry/attestation_policy.go`, `routing_eligibility.go`, `owner_authorization.go` and `inference_authorization.go`.
- Provider bindings/onboarding: `provider-swift/Sources/ProviderCore/ProviderLoop+AppAttestShadow.swift`, `provider-swift/Sources/ProviderAppAttest/ShadowProtocol.swift`, `provider-swift/Sources/ProviderCore/Auth/ProviderOnboardingPolicy.swift` and `provider-swift/Sources/darkbloom/UnenrollCommand+KeepServing.swift`.

Focused existing Go tests passed against this refresh: 36 top-level tests across registry, App Attest policy/service and API packages, including 106 passing test/subtest events. Coverage includes independent authorization paths, common and owner gates, shadow-only behavior, expiry, qualification withdrawal/store outage/restart, revocation, final-writer races, protocol-3-only negotiation, rejection of pre-v3 enrollment recovery, mandatory status/Secure Boot fields, version-independent registration freshness and the missing-version routing floor. The runs used Go 1.25.0 with `CGO_ENABLED=0` and authorized local test sockets. The PR adds no runtime changes relative to refreshed master; pre-existing untracked historical unsafe-behavior probes remain untouched and were excluded by positive test-name filters. Exact commands and latest CI status are recorded in the PR.

Swift source/tests were inspected for transcript parity, wrong-session/endpoint rejection, v3 hardware binding, diagnostic exclusion, onboarding, readiness and enrollment recovery. Swift tests were not rerun for this documentation-only change. Documentation lint, impact and YAML/reference checks are recorded in the PR validation results.

## Deployment and residual limits

`deploy/environments/prod.env` explicitly describes itself as a sanitized reference rather than the consumed live environment. It retains MDM and a hardware trust floor, with minimum provider version `0.9.5`. `coordinator/appattest/service/config.go` defaults shadow/serving/removal off and rollout to zero; `deploy/gcp/prod/refresh-env.sh` preserves live environment settings. Source review therefore does not establish live rollout percentages, current qualified builds, profile-removal readiness or fleet composition.

No deployment, provider release, build approval, credential revocation or profile removal was performed. Signed-artifact/physical-Mac security-transition qualification, hostile-host resistance and per-request inference correctness remain separate evidence requirements. The September 10 report and its pinned probes remain a historical record; this follow-up supersedes its provider-trust assumptions only where explicitly discussed above.
