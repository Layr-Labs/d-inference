# Provider verification with App Attest

> Last updated: 2026-11-18

How to check provider verification. Darkbloom verifies Macs with App Attest
only, which needs macOS 27 or later; a `hardware` label is not required to
serve. For
operators; the mechanism — what each layer proves, the grant and loss
conditions, the routing gate, and the code map — is in
[`../architecture/security/attestation.md`](../architecture/security/attestation.md)
and is not restated here.

Current backend behavior is defined by the
[platform's latest default branch](https://github.com/Layr-Labs/darkbloom-platform/tree/master).
Immutable platform links below preserve evidence snapshots, not current source
or proof of deployment. The connected coordinator's verdict remains authoritative
for serving.

Optional [App Attest shadow checks](../reference/app-attest-shadow.md) run in the background. Shadow results do not change these enrollment requirements or your existing trust eligibility. Version/cohort controls protect older clients; see the [rollout procedure](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/operations/app-attest-rollout.md).

App Attest replies and received grant updates can progress while model loading
is suspended. A local Apple success still does not establish coordinator
acceptance; use the current coordinator verdict when diagnosing expiry. See
[provider connection control](../architecture/security/attestation.md#provider-connection-control).

A signed version is registered as an official build
by trusted release CI before publication. Its durable identity survives
coordinator restarts. No per-release hardware qualification or manual approval
is required. Runtime serving still requires actual Apple enrollment/assertion
verification matching the official code/runtime hashes; registration and
notarization cannot substitute for those checks or undo permanent revocation.
Recurring receipt readiness is a separate platform-owned reward
requirement, not a basic-serving gate.
Missing official identity keeps serving pending, not a reason to delete
credentials or replace an employer profile. See the
[current build-registration contract](https://github.com/Layr-Labs/darkbloom-platform/blob/master/docs/reference/provider-authorization.md#durable-build-qualification);
the [earlier qualification contract](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/reference/provider-authorization.md#durable-build-qualification)
is retained as historical evidence.

Account erasure also clears delayed account-specific proof writes;
[shared-device cleanup](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/architecture/account-erasure.md#shared-machines-and-shared-keys)
retains another live account's device evidence. Unshared APNs tokens and pending
challenges are removed from the coordinator's runtime cache too; stale replies
cannot restore them ([identity cleanup](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/architecture/security/identity-binding.md#account-erasure-and-apns-runtime-state)).

Autopilot earnings-floor qualification is a separate historical check: a new
authorization does not qualify a declaration received before that grant. See
the [reward policy](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/reference/pricing-model.md#autopilot-rewards).

## Read current verification in the dashboard

Open a machine's verification panel to inspect the coordinator's separate App
Attest and legacy decisions, verification times and authorization deadlines.
Green requires a current server verdict; expired, revoked, unsupported, offline
and stale/missing states do not manufacture a current grant from saved hardware
trust. App Attest-only machines retain their legacy `self_signed` field. A
provider advertising an App Attest protocol other than version 3 displays
`unsupported`, even if its reported OS supports App Attest.

The footer counts the union once and reports both method counts and overlap.
Offline machine records stay in the owned-machine denominator but not current
authorization. Public proof views omit raw certificates, receipt blobs and
credential identifiers. See [consumer verification](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/consumer/verification.md)
and the [wire contract](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/reference/api-contracts.md#verification-presentation-contract).


## App Attest setup and recovery

A failed initial enrollment can leave an Apple key unusable even when its identifier is still in Keychain. Darkbloom replaces that identifier after non-service-unavailable failures, or after an attempt whose answer was lost because the provider ended during the Apple call, subject to the persisted one-hour replacement cooldown and shared hourly generation budget. A crash or forced kill can lose that answer; a disconnect, `darkbloom stop` or a cluster restart lets Apple answer first. Service-unavailable failures keep the same key, and already saved enrollment proofs are retained for retry. Do not delete account, machine, Keychain or employer-management state to force retries. This recovery is not proof that the Mac is authorized; check the coordinator verdict. See the [key lifecycle](../reference/app-attest-shadow.md#bounds-and-credential-lifecycle).

After a macOS upgrade, the running signed app checks App Attest again on its next coordinator connection. If a completed Apple callback reports key-generation failure without a usable ID, Darkbloom can retry after one minute within its persisted hourly budget; timeout, cancellation and busy admission retain the safer one-hour cooldown. A definite Apple service-unavailable assertion gets one local retry using the same key and challenge. These attempts cannot grant access without Apple's verified proof and the coordinator's applicable authorization, build and security checks.


App Attest renewal and transient retries follow a coordinator-driven bounded schedule. The [updated platform recovery policy](https://github.com/Layr-Labs/darkbloom-platform/blob/20b821646acfbf0968d1c30239cb583eeb0fa2bc/docs/reference/provider-authorization.md#controls) distinguishes first-proof backoff from recovery after an accepted proof; retries neither grant permission nor extend the original 15-minute assertion validity, and current policy can shorten serving further. Keep the provider running and check `darkbloom status` or `darkbloom doctor`; persistent native errors still need diagnosis, not credential/profile deletion. This source reference does not establish which schedule a deployed coordinator runs.
The [earlier recovery policy](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/reference/provider-authorization.md#controls)
is historical evidence, not the current retry schedule.

When the coordinator asks the provider to enroll a key that this Mac already enrolled, the provider clears that key and answers `key_unregistered`; the next exchange generates a replacement within the one-hour cooldown and shared hourly generation budget. The replacement goes through the full enrollment checks. Do not delete the Keychain item yourself.

`darkbloom doctor` shows the provider's local App Attest state in the `APP ATTEST` section: whether a key is stored and enrolled, any remaining local key-generation safeguard, whether the provider runs in the logged-in GUI session, and a stalled Apple call. The countdown is calculated by the provider; it is not an Apple-supplied deadline or the coordinator's retry time. The coordinator may retry later under its [configured recovery schedule](https://github.com/Layr-Labs/darkbloom-platform/blob/20b821646acfbf0968d1c30239cb583eeb0fa2bc/docs/reference/provider-authorization.md#controls), independently of this local safeguard. The daemon records local state on each coordinator App Attest exchange (`provider-swift/Sources/ProviderCore/Diagnostics/AppAttestLocalDiagnosis.swift`). If Apple reports App Attest as unsupported (`is_supported_false`) for a provider outside the GUI session, log in at the console and run `darkbloom restart` so the provider runs inside the GUI session. For a provider already in the GUI session a restart does not help: re-register the app with LaunchServices instead (see the self-update paragraph below). In both cases, confirm SIP is enabled and Startup Security Utility is set to Full Security.

Local key/history observations refresh after every proof exchange, including repeated assertions without another `prepare`. `doctor` and `report` advance displayed ages between exchanges while retaining the original observation metadata.

Each `ready` reply carries bounded diagnostics about process start and previous exit, console-user presence, SIP/authenticated root, signing preflight, key history and APNs push history. Failed attestation/assertion replies can additionally carry the native NSError chain. These optional fields are outside the signed transcript and never used for authorization. [`app-attest-shadow.md`](../reference/app-attest-shadow.md) defines them. `darkbloom doctor` explains the available observations with targeted advice ([doctor checks](./troubleshooting.md#doctor-checks)):

- `gui session`: a user is logged in, but the provider runs outside that session. Run `darkbloom restart` from the desktop session.
- `boot security` / `app signing`: Apple needs Full Security and an intact signed install. Known-invalid checks call for repair in Recovery or reinstallation. Missing signing data or unknown profile expiry produces an indeterminate warning, not a pass.
- `key history` / `last apple failure`: generation-attempt totals and the last recorded native failure, or a CryptoTokenKit `-3` key loss after a restart. A generation count plus a recorded `invalidKey` does not establish earlier per-key attestation outcomes. The recorded failure can predate a later success (`provider-swift/Sources/ProviderCore/Diagnostics/AppAttestDeepDiagnosis.swift`, `keyHistory`; `provider-swift/Sources/ProviderAppAttest/AppAttestShadowClient.swift`, `recordAppleFailure`).

For the last two, run `darkbloom report` from an administrator account; macOS lets only administrator accounts read the system log. Use `sudo darkbloom report` instead if this account is allowed to use sudo. The report adds device-wide `devicecheckd` observations reduced to closed failure patterns and numeric codes. They can originate from other apps and are not attributable to Darkbloom, so they do not independently diagnose this provider's key. System-log evidence is never collected or sent automatically.

On the default in-process path, an Apple DeviceCheck call that never answers
keeps later App Attest calls `busy` until the callback arrives or the provider
restarts. The provider reports the stall and restarts through the normal drain
when idle; see the [thresholds and limits](../reference/app-attest-shadow.md#bounds-and-credential-lifecycle).
The log line starts with `App Attest: Apple operation stalled`. An explicit
`darkbloom restart` uses the same graceful lifecycle; it is not instant or proof
that Apple will accept the next call.

After a self-update, some macOS 27 Macs report App Attest as unsupported
(`is_supported_false`) although it worked before. Apple's answer also depends on
macOS LaunchServices' record of the running app, and the update swaps
`Darkbloom.app` in place. Until LaunchServices registers the new bundle, every
process reports unsupported, including restarted ones. Fleet data for the 0.10.6
and 0.10.7 rollouts: 12–15% of updating macOS 27 Macs; it cleared on its own
after minutes to hours. The updater registers the new bundle with
LaunchServices (`LSRegisterURL`, as `lsregister -f` does) right after the swap
(`SelfUpdater.commitStagedBundle`). When Apple answers unsupported, the
provider also re-registers the running bundle and asks Apple again before
replying (`AppleAppAttestService.checkAvailability`,
`provider-swift/Sources/ProviderAppAttest/AppAttestSupport.swift`). It does
this at most once per process, or once per scheduled window for a provider with
an availability schedule. To do it by hand:

```bash
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$HOME/.darkbloom/Darkbloom.app"
```

Then wait for the next App Attest check (up to 10 minutes) or run
`darkbloom restart`. The command only refreshes macOS's record of the app; it
changes no Darkbloom file or key. If the coordinator granted
this Mac App Attest in the last 7 days and launchd runs the provider, the
provider restarts once through launchd when the state lasts 5 minutes and the
provider is idle. It restarts once per verified episode: if the new process
still reports unsupported, it waits until the coordinator verifies the Mac
again. This restart shares the stall restart's limit of one per 6 hours.

For root-cause analysis, the provider log (`~/.darkbloom/provider.log`) gets a
line that starts with `App Attest entitlement evidence` once at startup and at
each `is_supported_false` answer. It shows the start reason, the App Attest
entitlements the kernel gave the running process next to the ones in the code
on disk, and the executable's modification time minus the process start time.
The line stays on the Mac; it is not sent to the coordinator
(`provider-swift/Sources/ProviderAppAttest/AppAttestPreflightProbe.swift`,
`AppAttestEntitlementEvidence`). The log line starts with `App Attest: isSupported is false`. See the
[thresholds and limits](../reference/app-attest-shadow.md#bounds-and-credential-lifecycle).

The separate [supervised worker candidate](../architecture/security/identity-binding.md#supervised-app-attest-worker-candidate)
is internal, defaults off and is **not ready for production**. It retires the
worker rather than restarting the inference process; do not enable its
[qualification flag](../reference/configuration.md#app-attest-worker-qualification)
as an operator workaround. The [recorded native passes](../../scripts/nativequalification/README.md#qualification-status)
separate worker components, loaded-engine callback recovery and Stage C
resumption. They apply only to the tested signed artifacts; rebuilt binaries
need fresh qualification, and physical OS/update/reboot and fleet-rollout gates
remain separate.
macOS 27, GUI-session checks and an intact signature alone are not Apple acceptance.

During a same-process reconnect the provider can answer a fresh, encrypted
[endpoint-resumption challenge](../reference/protocol-messages.md#app-attest-endpoint-resumption-candidate)
without another Apple call. This proves custody of the existing in-memory key,
not local permission to serve or a fresh Apple proof. The coordinator must
support the separate protocol and authorize the new connection. Neither resume
nor worker replacement extends the coordinator-driven renewal schedule or
fifteen-minute proof-validity window; process restart creates a new endpoint key.
The matching platform support must recheck retained evidence and current policy.
The [isolated native qualification](../reports/2026-10-11-native-serving-resumption-qualification.md)
passed with real Apple verification and encrypted inference across a 125-second
break on one exact signed candidate. It does not enable production resumption
or establish cross-process or worker-recovery continuity.

After enrollment, a missing or unverified recurring risk receipt or missing risk metric remains unknown. Under the [updated platform receipt policy](https://github.com/Layr-Labs/darkbloom-platform/blob/20b821646acfbf0968d1c30239cb583eeb0fa2bc/docs/reference/provider-authorization.md#receipt-monitoring-and-stricter-readiness), this alone does not clear an accepted, otherwise valid basic serving grant or require extra assertions. First authorization still requires a fresh cryptographically verified proof and coordinator acceptance under current build, revocation and identity checks. Rewards retain stricter verified-receipt and decision-freshness requirements; do not assume every deployment uses the updated policy.

A verified assertion is one step toward authorization. Current serving also
requires the complete proof archive, the same authenticated account and
machine identity on this connection, a registered official signed build and the current
runtime checks. A transient identity or storage refusal remains pending; the
coordinator requests another fresh assertion on its bounded retry schedule.
Keep the provider running and inspect the current authorization reported by
`darkbloom status` or `darkbloom doctor`. A historical `eligible` observation
cannot authorize serving by itself. The verified Apple code
measurement must match the registered official signed build; registration alone
cannot supply missing evidence or repair a mismatch. Do not delete a working
credential to bypass that check.

Darkbloom verifies Macs with App Attest only, on macOS 27 or later. The
installer and `darkbloom enroll` download no profile. Start the signed provider and check
`darkbloom status` / `darkbloom doctor` for current App Attest authorization.
Company-managed Macs keep their employer profile; it never affects this path.

`darkbloom status` and `darkbloom doctor` describe only the coordinator's App
Attest decision (`provider-swift/Sources/ProviderCore/Diagnostics/ProviderAuthorizationReadiness.swift`,
`summary`). They never ask you to keep a Darkbloom profile; see the [authorization reference](../reference/provider-authorization.md).

New setup remains pending if App Attest is unavailable or unqualified; diagnose
with `darkbloom doctor`. No profile is needed or offered.

`darkbloom logout` stops the provider before removing its saved credential and
attempts token revocation. If remote revocation is unconfirmed, its output says
so; local deletion is not proof that remote copies were invalidated. See
[logout flags and failure behavior](cli-reference.md#darkbloom-login--darkbloom-logout).

## Macs on macOS 26 or earlier

A Mac on macOS 26 or earlier cannot use App Attest, so it cannot serve until
macOS is updated to 27 or later. Every command in the CLI warns on stderr when the local OS is below 27
(`provider-swift/Sources/darkbloom/MacOSUpgradeNotice.swift`). After updating
macOS, run `darkbloom update` and `darkbloom restart`, then check
`darkbloom status`. App Attest sets itself up; your account, earnings history
and models are kept.

Base rewards always required current qualified App Attest authorization; that
is unchanged. Inference/work earnings are unchanged, with no retroactive
clawback of rewards. See [billing](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/consumer/billing.md) for the reward policy.

Upgrading macOS does not uninstall the old "Darkbloom Provider Enrollment"
profile. It no longer does anything. When it is still installed, `darkbloom
start`, `darkbloom status` and `darkbloom doctor` say so in one line
(`provider-swift/Sources/ProviderCore/Diagnostics/RetiredMDMProfile.swift`).

## Remove the retired Darkbloom profile

1. Run `darkbloom unenroll` and choose **2** (or run
   `darkbloom unenroll --keep-serving`). No coordinator approval is needed and the
   provider keeps running.
2. The command names the profile **Darkbloom Provider Enrollment** and the
   Darkbloom server that `profiles status -type enrollment` reports, then opens
   System Settings at the installed profiles (`--no-open` skips this). It needs
   no administrator access
   (`provider-swift/Sources/darkbloom/UnenrollCommand+KeepServing.swift`,
   `guideRetiredProfileRemoval`).
3. In **System Settings → General → Device Management** (or **Privacy & Security
   → Profiles**), select the profile with exactly that name, click **Remove** and
   authenticate. If no profile has exactly that name, remove nothing. Keep any
   profile from your employer or school. macOS lets only you remove it; the CLI
   never does.
4. Verify: `darkbloom doctor` no longer shows the `darkbloom mdm profile` line.

Choosing **1** instead fully exits Darkbloom: it stops the provider and offers
identity cleanup. Options are in
[`cli-reference.md`](./cli-reference.md#darkbloom-enroll--darkbloom-unenroll).

## Keep App Attest authorization

- **Stay online and awake.** Authorization belongs to the live connection and
  renews on the coordinator's schedule; a reconnect needs a fresh proof.
- **Keep the console session.** Apple's App Attest answers inside a logged-in
  GUI session; `darkbloom doctor` reports `console session`, `automatic login`,
  `auto-logout on idle` and `sleep prevention`
  ([`troubleshooting.md#doctor-checks`](./troubleshooting.md#doctor-checks)).
- **Keep the default boot settings and leave authenticated root enabled.** All are changed only in
  Recovery, and App Attest's Mac access policy checks them. The provider also
  checks them itself: it serves Darkbloom requests only when SIP is at Apple's
  default configuration (no `csrutil enable --without …` exception; the exact
  value is read from the kernel and reported at registration), when
  `Startup Security Utility` doesn't report `Reduced Security` or
  `Permissive Security`, and when authenticated root (the signed system volume
  check) isn't explicitly disabled. An unreadable Secure Boot report only warns
  on the Mac. The service reads it again for up to a minute at startup and,
  on a Mac that serves alone, once more before each connection while it stays
  unread; only then is it reported as `unknown`, with why
  (`secure_boot_read_failure`) and after how many reads
  (`secure_boot_read_attempts`). An unreadable authenticated root
  setting only warns, and is left out of the registration. The provider also
  refuses to serve from inside a macOS sandbox it didn't set up, since it can't
  verify the boot settings there. If one of these keeps Darkbloom serving off, a
  `darkbloom start` that would install the Darkbloom service stops with the fix,
  a running service stays up without connecting to Darkbloom, and
  `darkbloom doctor` names each protection that is off. Only me (`darkbloom start --local`) still serves
  your own requests.
- **Keep the same identity.** The Secure Enclave signing key is persistent in
  the keychain, so your SE public key survives restarts
  ([`../architecture/security/identity-binding.md`](../architecture/security/identity-binding.md)).
  If the keychain path fails — for example a binary without the
  `keychain-access-groups` entitlement — `ProviderLoop.swift` falls back to an
  ephemeral key with a warning; reinstall a signed release build.
- **Run a released build.** Binary, metallib and model-hash drift against
  registration untrusts you; `darkbloom update` returns you to a build in the
  release record ([`cli-reference.md`](./cli-reference.md#darkbloom-update)).

## Verify

`darkbloom status` prints the coordinator's current decision as
`Authorization: App Attest authorizes this connection.` when this connection is
authorized (`StatusCommand.swift`). Without a current decision it prints the last
`trust_status` as `Trust: <level> / <status>` with advice from
`provider-swift/Sources/ProviderCore/Diagnostics/TrustReasonCatalog.swift`. At
registration the coordinator sends `SE attestation verified`: the Secure Enclave
check passed, and serving waits for App Attest. The reason strings are listed in
[trust status messages](../architecture/security/attestation.md#trust-status-messages-to-providers).

`darkbloom doctor` shows the local side: App Attest state, SIP, the
console-session checks above, an informational line if the retired Darkbloom
profile is still installed, and (with `--support`) the coordinator URL ([`troubleshooting.md#doctor-checks`](./troubleshooting.md#doctor-checks)).

Anyone can read your public verdict, which includes `app_attest_authorized` and
the verified posture fields but never your serial, UDID, APNs token or
`code_attested`, from `GET /v1/providers/attestation`. The fields are explained in
[../consumer/verification.md#public-attestation-endpoint](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/consumer/verification.md#public-attestation-endpoint).

Single-node inference is the supported security boundary: multi-node RDMA over
Thunderbolt bypasses the in-process memory protections and is not trusted. The
process defences behind the privacy capabilities the routing gate requires, and
their known limits, are recorded in [`../threat-model.yaml`](../threat-model.yaml)
and summarised in
[`../architecture/components/provider.md#process-boundaries`](../architecture/components/provider.md#process-boundaries);
what the provider can and cannot see is in
[`../architecture/security/encryption.md#what-each-party-can-observe`](../architecture/security/encryption.md#what-each-party-can-observe).

## Troubleshooting

The provider's `status_signature` must cover the same canonical bytes the
coordinator reconstructs. `StatusCanonical.build` in
`provider-swift/Sources/ProviderCore/Security/AttestationBuilder.swift` matches
the coordinator's ordering of mixed-case `model_hashes` and `template_hashes`
keys and its escaping of U+2028/U+2029. This encoding correction leaves
signature verification and trust requirements unchanged; the byte
format and failure policy are in [Layer 2](../architecture/security/attestation.md#layer-2--periodic-challenge).

| Symptom | Likely cause | Fix |
|---|---|---|
| No `Authorization: App Attest authorizes this connection.` line | App Attest pending, unqualified, or the Mac runs macOS 26 or earlier | On macOS 26 or earlier, update to macOS 27; otherwise follow `darkbloom doctor`'s `APP ATTEST` and traffic lines |
| `trust_level: self_signed` | The legacy level; App Attest serving does not raise it | Informational; check the `Authorization:` line instead |
| `mdm_verified: false`, `mda_verified: false` | Retired fields the coordinator still sends for older CLIs ([kept until](../operations/retired-mdm-remnants.md)) | Informational; routing does not use them |
| `code_attested` never passes | No Aqua session / no APNs token / pushes throttled | Log in at the console, enable automatic login, disable auto-logout; check `darkbloom doctor`; a reconnect soon after a proof uses the resume path instead of a push ([Flag — APNs code identity](../architecture/security/attestation.md#flag--apns-code-identity)) |
| Derouted after missed challenges | Sleep or network blip | Recovers on the next passing challenge; prevent sleep |
| `status signature verification failed` while the plain challenge signature passes | Invalid status signature or a mismatch between provider and coordinator canonical bytes | Run `darkbloom update` and `darkbloom restart`; if it persists, use the diagnostics below. The coordinator continues to reject mismatching signatures |
| Binary hash drift warning | Running a build not in the coordinator's release record | `darkbloom update` |
| `darkbloom mdm profile: installed but no longer used` | The retired Darkbloom profile is still installed | [Remove it](#remove-the-retired-darkbloom-profile); it does nothing either way |
| Every flag lost after an update or reinstall | The Secure Enclave key fell back to ephemeral (warning in `darkbloom logs`) | Reinstall a signed release build so the `keychain-access-groups` entitlement is present |

For local diagnostics use `darkbloom doctor` and `darkbloom logs --last 1h`.
Provider logs are never uploaded automatically; `darkbloom report` uploads a
unified-log excerpt to `POST /v1/provider/log-report` only when you run it
(`--dry-run` prints it first; [`cli-reference.md`](./cli-reference.md#darkbloom-report)).
On macOS 27 the report also carries the App Attest snapshot and the APNs push
history. Run from an administrator account (or with `sudo` where allowed), it
also carries closed, device-wide `devicecheckd` pattern matches, not provider-specific proof.

## Related

- [`../architecture/security/attestation.md`](../architecture/security/attestation.md) — trust levels, the three layers, both flags, the routing gate, invariants, and code map.
- [`../architecture/security/enrollment.md`](../architecture/security/enrollment.md) — how the provider detects the old Darkbloom profile and guides its removal.
- [`../architecture/security/identity-binding.md`](../architecture/security/identity-binding.md) — how the SE key, `K`, the APNs token, and your account are bound.
- [`../architecture/security/encryption.md`](../architecture/security/encryption.md) — the three NaCl Box hops and the privacy statement.
- [../consumer/verification.md](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/consumer/verification.md) — how consumers read your verdict.
- [`troubleshooting.md`](./troubleshooting.md) — doctor checks and symptom → fix rows.
- [`../design/apns-code-attestation.md`](../design/apns-code-attestation.md) — design record for code identity.

Local [cache-volume checks](../architecture/security/encryption.md#provider-cache-storage)
are storage suitability checks, not evidence of peripheral firmware authenticity
and not part of the coordinator's provider attestation verdict.
