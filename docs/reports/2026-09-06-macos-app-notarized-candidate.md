# Notarized macOS Studio candidate — 2026-09-06

> Last updated: 2026-09-06 · commit `201eff027`

The Studio candidate passed Apple notarization, the complete signed-artifact
qualifier on an approved Mac, and one authenticated model request through its
exact CLI. It remains a candidate: no release storage, coordinator release
record, or GitHub release was published. This Mac's managed Gatekeeper policy
still rejects the app, and that local check remains failed.

## Artifact identity

Version: `0.8.16`. Build source: `9dc6be50fc3deaa08d6106370ed5b98e1719b23d`.
GitHub Actions qualification run: `34026156914`, attempt `1`, artifact
`9987298156` (`darkbloom-dev-qualification-34026156914-1`).

The run used `environment=dev`, `publish_release=false`, and
`version_override=0.8.16`. All publication steps were skipped. Apple accepted
submission `d7f3dcbd-9765-4127-96fb-5bf08aa6dea7`; the app carries its valid
stapled ticket. The downloaded Actions archive and both distribution files
were independently hashed before use.

| File | SHA-256 |
|---|---|
| App ZIP | `897a8344b02528a9e91901a7cc018b966ec8d5154d2b5414ded5586588f12480` |
| Updater tar | `e18d0b0ecf38d2cef8ed39c312697420081d6c2024b878bcc8ccac753e803efc` |
| Nested provider CLI | `9511627ea55e2713d1e96a713ad785b403890e1b5a479f0b8b8e56ddb81761f9` |
| Metallib | `47357f1b5eddc71231b7cf5f2e209f02bee92c0f7d31f3aa1e39110e6f891ca3` |

## Trust checks and local restriction

| Check | Result |
|---|---|
| CI signing, notarization, archive and runtime qualification | Passed |
| Strict signatures and pinned requirements on the test Mac | Passed |
| Hardened runtime, CLI/profile grants, and sealed resources | Passed |
| Stapler and Gatekeeper on macOS 26.5.1 with SIP and authenticated root enabled | Passed; Gatekeeper verdict true, Notarized Developer ID |
| Signed nested CLI launch and packaged Metal smoke | Passed through the complete qualifier |
| Local macOS 26.5.2 Gatekeeper | **Failed**; verdict false under Notarized Developer ID |
| Apple distribution diagnostic on both Macs | Passed; this does not replace the failed local Gatekeeper check |

The local managed preference sets `EnableAssessment=true` and
`AllowIdentifiedDevelopers=false`. It is consistent with the local rejection;
the same archive is accepted on the other Mac. No Gatekeeper rule, managed
preference, quarantine setting, or security control was changed. Administrator
authorization is required before treating the local installation gate as passed.

## Exact CLI model request

On an Apple M4 Max with 36 GiB memory, the notarized CLI served
`mlx-community/Qwen3.5-4B-8bit` through loopback HTTP. It returned the exact
text `DARKBLOOM_LOCAL_OK`, HTTP 200, a complete SSE `[DONE]`, and finish reason
`stop`. Usage was 22 prompt and 8 completion tokens. Unauthenticated model
listing returned 401.

| Observation | Seconds |
|---|---:|
| Launch to discovery | 1.317 |
| First content | 3.193 |
| Complete request | 3.297 |

This was one controlled request, including model loading from files already
on disk. Filesystem caches were not cleared. It used one model slot, one
concurrent request, a 75% memory cap, contiguous KV, and disabled MTP/SSD
caching. It is CLI HTTP integration, not inference through the native Chat UI,
and does not establish general throughput or multimodal performance.

The test used isolated runtime and credential paths and a sandbox that denied
home writes outside the test root, outbound connections, and fan-helper access.
Existing provider/watchdog kernel identities and 23 protected files were
unchanged. The test process, sleep-prevention helper, listener, discovery, and
PID record exited or were cleaned up after identity checks. SSH was closed.

## Qualification tooling findings

Local qualification first falsely reported a missing hardened-runtime flag.
The actual signature contained the flag. Five runs reproduced a `codesign`
exit of 141 and a matching `grep` exit of zero: `grep -q` closed the pipe early,
and `pipefail` reported SIGPIPE as failure. The qualifier and three workflow
marker filters now drain their producers, preserving their original match
requirements and producer-error propagation. Four regression tests exercise
16 real shell pipelines, including the old quiet-filter negative control.

The release resolver also rejects CR/LF and noncanonical versions before
writing workflow outputs. A synthetic multiline version previously overrode
`publish_release` in the output file; 13 policy/manifest tests now cover this
boundary. The actual qualification used the fixed single-line version above,
and its publication steps were verified skipped. Independent review found
no P1/P2 issues in these follow-up changes. App and inference bytes are
unchanged by the tooling fixes.

## Evidence and remaining gates

Local evidence under the app-refresh artifact root includes
`release-candidate-notarized-34026156914`,
`validation/remote-notarized-static`, `validation/remote-notarized-candidate`,
`validation/notarized-local-policy`, and the policy/stream regression logs.
The Actions manifest records the source, run, notary ID, and exact hashes.

Main and integration CI passed at build source `9dc6be50f`. The automated
security review is unavailable because its Anthropic repository credential is
invalid. The effective master rules require an approving review, including
approval of the last push; they do not list that job as a required status check.
The known informational exact-cache failure and released-provider artifact-only
coverage on SIP-disabled CI are retained as explicit limitations.

Clean-Mac signed GUI install/relocation, deployed-reader upgrade and rollback,
browser approval, MDM/MDA, persistent Secure Enclave/APNs identity, and the
actual system status-item trigger remain separate checks in the
[app release runbook](../operations/app-release.md). The earlier native Studio,
Network, and shared-menu walkthrough is presentation and navigation evidence;
it does not establish those distribution and enrollment outcomes.
