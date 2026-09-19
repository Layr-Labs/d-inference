# Roll out MDM-optional providers

> Last updated: 2026-09-18 · commit `397b4d902`

Enable the independent App Attest serving path and, separately, allow providers to remove Darkbloom enrollment. This runbook does not authorize a production change. The [authorization reference](../reference/provider-authorization.md) owns exact controls and deadlines.

## When to use

Use after the coexistence release has produced retained evidence and the final signed provider artifact has passed qualification. Company-managed Macs keep employer management and must meet the same app/runtime/security requirements.

## Prerequisites

- Explicit operator approval for the deployment and each production control change.
- Final notarized Developer ID bundle/profile; verified production App Attest identity, exact CodeDirectory mapping and active release catalog; configured receipt-renewal key.
- Passing Mac tests: fresh enrollment, repeated assertion, encrypted inference, upgrade/restart/reconnect, account change, Keychain loss, altered/re-signed executable/resources, substituted endpoint and replay.
- Physical security-transition tests using a previously accepted key after disabling SIP and after lowering boot security, followed by reboot. Neither an old certificate nor a stored credential may authorize the changed process.
- Older supported macOS legacy regression, actual Darkbloom-only profile removal and employer-managed Mac acceptance. Code tests and aggregate shadow success do not satisfy these gates.
- All coordinators that can settle base rewards must run the canonical-aware settlement code before activation; do not mix legacy-only settlement writers with the new path.
- A rollback image with App Attest serving support. After users remove MDM, an old legacy-only coordinator cannot serve as a compatible rollback.

## Steps

1. Deploy reviewed coordinator code with serving/removal disabled, following the [coordinator deploy runbook](coordinator-deploy.md). Preserve the configured drain and immutable rollback state.
2. Publish the qualified signed provider. Register its immutable approved hashes only after the qualification evidence exists; do not approve hashes solely to eliminate an unknown policy verdict.
3. Coordinate publication of the macOS 27 onboarding installer/provider/UI with App Attest serving activation for the intended new-provider cohort. The installer and `darkbloom enroll` skip new MDM enrollment on macOS 27+ even if serving is disabled: those users remain pending, with no automatic MDM fallback. Enable App Attest serving for the chosen account cohort, leaving removal disabled. Verify actual MDM-free serving, full policy decisions, receipt refresh, runtime/capability/model checks and base-reward continuity.
4. Test expiry, admin revocation, interrupted database refresh, queue backlog, cold dispatch and reconnect during traffic. Check that new handoffs stop, cleanup/accounting completes, and existing delivered requests have an explicit outcome.
5. Enable removal for the qualified cohort. A provider runs `darkbloom unenroll` and selects the macOS 27+ App Attest option (or uses `--keep-serving` directly); retain all credential, authentication and machine-history data. Verify reconnection and normal serving after removing only Darkbloom enrollment.
6. Track distinct machines and accounts by authorization path, macOS/provider version, failed qualifications, expiry/revocation reasons, receipt/archive gaps, completed inference and duplicate/base-reward settlement. Keep unsupported providers on the independently verified legacy path.

## Verification

Verify a fresh macOS 27 install never requests `/v1/enroll` or opens profile Settings, including while App Attest is unavailable. Verify older macOS retains enrollment and sees the upgrade/deactivation notice. Run `python3 scripts/test-install-onboarding.py` for mocked setup coverage; actual signed-Mac serving remains a separate check. Check full authorization, not merely Apple signature success or `isSupported`. The accepting coordinator fences admin revocation before returning; remote/store-side revocations have the documented freshness bound. Stop admission when required state becomes unknown. Validate that no raw proof, receipt, signing credential or prompt content enters ordinary telemetry.

## Rollback

Disable new removal readiness first while retaining App Attest serving. Keep an App Attest-capable coordinator and approved provider build available for machines already unenrolled. A security incident may require revocation and loss of serving capacity; do not silently turn off the authorization gate or claim MDM fallback exists on unenrolled Macs. Re-enrollment is a separate operator/user action and must not replace employer management.

## Related

- [Design and before/after diagrams](../design/mdm-optional-provider-authorization.md)
- [Authorization controls and contracts](../reference/provider-authorization.md)
- [Existing App Attest qualification runbook](app-attest-rollout.md)
