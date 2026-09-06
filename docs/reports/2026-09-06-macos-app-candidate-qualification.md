# macOS Studio candidate qualification — 2026-09-06

> Last updated: 2026-09-06 · commit `ab992bef4`

The Studio candidate passed signed local execution, ZIP and tar round trips,
and one authenticated model request on a second Mac. This records a local
candidate, not a notarized release or production deployment.

## Candidate identity

Provider version: `0.8.16`. Source: `ab992bef42942b2706846bc67e3a044febc0c646`.
Local artifact directory:
`/Users/gaj/.codex/app-refresh-artifacts/20260905/release-candidate-final-v2`.

| Artifact | SHA-256 |
|---|---|
| App ZIP | `740ba87ab1b86e88375e07ac5442a501ef641b3a33838684cfc76880cdcf805c` |
| Updater tar | `22b48f472e02362bd4eb89b6e9575a5444533a68b0cd09c57d17714e70541f84` |
| GUI executable | `a7f075d4a67ee8c528ac1cf38fa2ac4cf35e9457b41795bb2146be0c23eae78a` |
| Nested provider CLI | `83eded3c7e7cde0e96721ae51ee8196d8619cc26f4afd7e29e01112ce31af5d6` |

All four release products built: GUI, provider CLI, enclave helper, and fan
helper. The GUI does not contain the DEBUG menu-preview command. The CLI is
the main executable of the provisioned nested provider app; the outer CLI
path is the exact compatibility alias. Restricted CLI entitlements are absent
from the GUI.

## Executed checks

| Check | Result and limit |
|---|---|
| Deep/strict signatures and pinned designated requirements | Passed for staged app/helper and both extracted archive views |
| Direct and alias CLI launch | Version `0.8.16`; passed |
| Gemma and paged Metal smoke | Passed after signed assembly and both archive round trips |
| Tar raw-header preflight and flat payload parity | Passed; no relaxation of accepted archive metadata |
| Native Studio, Network, account sheet, and menu content | Screenshots and accessibility walkthrough completed; the menu content used a DEBUG window sharing the production view, with both navigation routes verified |
| Earlier full Swift partitions | 3,342 Swift Testing tests plus 86 XCTest cases passed before the final UI/auth refinements |
| Integrated app/auth/hash follow-up | 673 tests in 63 suites passed, including interrupted recovery and migration cases |
| Unlink flow follow-up | 16 tests in 3 suites passed |
| Final account presentation/issuer follow-up | 37 tests in 3 suites passed |
| Testbed credential isolation | All three Go test packages passed with the race detector, including eight new tests |

Focused counts overlap and are not a second full-suite total. The credential
coverage includes real SIGTERM/SIGINT, concurrent migration, and SIGKILL
subprocess cases. Independent source review closed the interrupted-publication
finding. The later account checks reject a different issuer and show approval
codes only during an active code phase.

The latest visible-window relaunch could not be confirmed because the Mac
locked. Earlier window verification and the native walkthrough passed; this
last launch timeout is not reported as a pass.

## Real model request

Hardware: a separate Apple M4 Max with 36 GiB unified memory. Model:
`mlx-community/Qwen3.5-4B-8bit`, already present on disk.

The signed nested CLI returned `DARKBLOOM_LOCAL_OK` through HTTP 200 streaming,
with `finish_reason: stop`, a complete `[DONE]` terminator, and 22 prompt plus
8 completion tokens. Unauthenticated model listing returned 401.

| Observation | Seconds |
|---|---:|
| Launch to discovery | 1.921 |
| Authenticated model listing | 0.000696 |
| First assistant content | 3.028 |
| Complete request | 3.132 |

This is one bounded integration request, including a model load; filesystem
caches were not cleared. The test used one model slot, one concurrent request,
a 75% memory cap, contiguous KV, and disabled MTP/SSD caching. It does not
establish general throughput, latency, multimodal behavior, or default-setting
performance.

The test bound only to loopback, kept authentication enabled, and used isolated
runtime and credential paths. Its sandbox prevented home writes outside the
test directory, outbound connections, and fan-helper access. Existing provider
and watchdog process identities were preserved; the protected-file audit
reported no changes. The test process, its sleep-prevention helper, and the
listener exited. Owned stale discovery/PID records were removed only after
process-identity checks.

## Packaging findings retained

The first tar check rejected `com.apple.macl` attached to the staged outer app.
The release workflow now removes this host-local access metadata before
archiving and retains metallib `com.apple.cs.*` signatures. It invokes archive
preflight through Bash because the source installer is not executable. The
rebuilt archives passed preflight, strict signatures, launch, and Metal smoke.
Earlier rejected archives remain separate diagnostic artifacts.

Evidence lives under the local artifact root in
`validation/final-archive-qualification-v2.log`,
`validation/final-release-build-v2.log`, and
`validation/remote-final-candidate-v2/` (`result.json`, `final-audit.json`,
`chat.events.json`, and sanitized logs). The earlier helper-layout control
record is [the September 5 signing report](2026-09-05-macos-app-signing-qualification.md).

## Remaining release gates

Notarization, stapling, Gatekeeper acceptance, signed GUI relocation on a clean
Mac, upgrade/rollback from deployed readers, real browser approval, MDM/MDA,
and persistent Secure Enclave/APNs identity remain separate qualification
steps in [the app release runbook](../operations/app-release.md).

The draft PR must receive a new CI result. The previous Threat Model Review
failed with an Anthropic 401; its repository credential requires human repair.
No production release, release registration, or deployment was performed.
