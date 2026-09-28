# Distributed local HTTP quota rotation

> Last updated: 2026-09-15 · commit `605651bb9`

The local distributed host passes 90 Provider tests and five actual local
HTTP/owner-child scenarios for listener-preserving request-quota rotation.
The tested runtime and repository tests are promoted to the working tree.
CLI activation, physical multi-Mac rotation and lifetime rotation remain open.

## Observed behavior

| Case | Result |
|---|---|
| Two quota boundaries | 33 complete HTTP requests across three fresh epochs; one listener and one discovery publication; all six owner endpoints released cleanly |
| Held acquisition and response | Replacement stayed blocked until both old holds ended; the same canonical lease inodes were reused after the release barrier |
| Missing release ACK | Native cleanup and owner exit did not permit replacement; quarantine remained |
| Nonzero owner exit | A release ACK did not permit replacement when the owner exited nonzero; quarantine remained |
| Stop during replacement startup | The started owner was retained and cleaned; no late second owner or replacement was published |

The 90 repository tests also cover stale response tickets and callbacks,
reuse of an earlier epoch after an intervening generation, changed installed
binding, an already-started factory result, late factory completion, fixed
lifetime expiry and the existing no-factory behavior.

Each driver exited and was reaped with its owned process group absent. The
private candidate's 13,780 source/dependency pins and MAIN's 13,766 pins stayed
unchanged through qualification. The Provider test process took 117.635 seconds
including compilation; the runner reported 1.052 seconds for the tests. The
five actual-child scenarios took 7.832 seconds after the final fixture rebuild.
These durations are not inference-performance measurements.

## Corrections and promotion

Two failed attempts remain preserved. The private executable first required
a test-only import for the existing internal endpoint constructor. A later
fixture incorrectly required the canonical lock to be unheld after the new
owner was already Ready. Its corrected assertion checks the old endpoint's
release proof; the full same-inode empty/unlocked check still runs before every
replacement and after final clean shutdown. Production code did not change
between the repository test pass and these fixture corrections.

The promotion contains 14 runtime files and two repository test files: eight
replacements and eight additions. It excludes private executable/fixture
products, Package.swift changes and CLI activation. The host separates
generation ownership from its listener in
`DistributedLocalServerGeneration`, `DistributedHTTPResponseRouter` and
`DistributedLocalServer+Rotation.swift`. The existing installed session's
native-cleanup, authenticated-release and owner-termination barriers remain
authoritative; no journal is cleared by the host or fixture.

Evidence is retained under `cluster-research`:

| Evidence | SHA-256 |
|---|---|
| Frozen source promotion, `cluster-session-quota-rotation-promotion-20260915/manifest.json` | `e26a0cd416d03951d2708701915c5bde507e2283a30cab88c69dde1474604cc6` |
| MAIN promotion receipt, `cluster-session-quota-rotation-main-integration-20260915/promotion-receipt.json` | `83446ccefadf6e651c4de85a113b1a87df00ec52168a5bad689414fa9a3a358b` |
| Five-case receipt, `cluster-session-quota-rotation-build-20260915/sequence-3/cases/checks.json` | `fbff177148aa1bf0d3daa98a40b91b8b01a13ea256ad6d8694f5889298809747` |

## Limits

The optional replacement factory is enabled only by an explicit caller. The
current CLI still uses the default nil factory and keeps its one-session
behavior. Fixed lifetime expiry still stops the host; limits are unchanged.
No model payload, GPU computation, remote owner or physical rotation was
exercised. Trusted coordinator-verified/routable membership and atomic
reservation of both devices remain separate work in the
[delivery plan](../design/distributed-cluster-delivery.md). The current host
mechanism is described in [provider inference](../architecture/inference.md#experimental-local-distributed-host).
