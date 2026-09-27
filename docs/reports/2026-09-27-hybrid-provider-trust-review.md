# Hybrid provider trust model review

> Last updated: 2026-09-27 · commit `93d556533`

This follow-up to the [September 10 security review](2026-09-10-security-model-review.md) verifies the current coexistence of legacy MDM/APNs and App Attest in source and focused tests. It updates the [canonical threat model](../threat-model.yaml) and [provider trust explanation](../architecture/security/provider-trust.md). It does not reclassify all 13 historical findings or claim that the live fleet has adopted particular settings.

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

## Evidence and validation

Reviewed source at `93d5565330244da6406cc247d231806f2801b0bd`:

- Coordinator proof/policy: `coordinator/appattest/verify.go`, `authorization.go`, `service/authorization_identity.go`, `service/authorizer.go` and `service/build_qualifications.go`.
- Shared and owner routing: `coordinator/registry/attestation_policy.go`, `routing_eligibility.go`, `owner_authorization.go` and `inference_authorization.go`.
- Provider bindings/onboarding: `provider-swift/Sources/ProviderCore/ProviderLoop+AppAttestShadow.swift`, `provider-swift/Sources/ProviderAppAttest/ShadowProtocol.swift`, `provider-swift/Sources/ProviderCore/Auth/ProviderOnboardingPolicy.swift` and `provider-swift/Sources/darkbloom/UnenrollCommand+KeepServing.swift`.

Focused existing Go tests passed: 32 top-level tests across registry, App Attest policy/service and API packages, including 103 passing test/subtest events. Coverage includes independent authorization paths, shadow-only behavior, expiry, qualification withdrawal, revocation, final-writer races, identity binding and owner routing. The final runs used Go 1.25.0 with `CGO_ENABLED=0`; an initial local SDK linker failure and sandboxed HTTP-listener failure were resolved by that build setting and authorized local test sockets. No runtime source changed and the historical unsafe-behavior probe files were excluded by positive test-name filters.

Swift source/tests were inspected for transcript parity, wrong-session/endpoint rejection, v3 hardware binding, diagnostic exclusion, onboarding, readiness and enrollment recovery. Swift tests were not rerun for this documentation-only change. Documentation lint, impact and YAML/reference checks are recorded in the PR validation results.

## Deployment and residual limits

`deploy/environments/prod.env` explicitly describes itself as a sanitized reference rather than the consumed live environment. It retains MDM and a hardware trust floor. `coordinator/appattest/service/config.go` defaults shadow/serving/removal off and rollout to zero; `deploy/gcp/prod/refresh-env.sh` preserves live environment settings. Source review therefore does not establish live rollout percentages, current qualified builds, profile-removal readiness or fleet composition.

No deployment, provider release, build approval, credential revocation or profile removal was performed. Signed-artifact/physical-Mac security-transition qualification, hostile-host resistance and per-request inference correctness remain separate evidence requirements. The September 10 report and its pinned probes remain a historical record; this follow-up supersedes its provider-trust assumptions only where explicitly discussed above.
