# Verified cluster pair reservation checks

> Last updated: 2026-09-16 · commit `605651bb9`

The coordinator registry's distributed pair-reservation implementation passed
15 focused tests and all 1,051 top-level registry tests with the Go race detector.
The exact tested sources are integrated into the development working tree.
Provider grant delivery, native executable approval and traffic-key establishment
are not enabled by this result.

## Change and qualification

The change holds two exact registered connections and both physical identities
atomically. Ordinary routing, warm-pool selection, model loading and model-command
writes respect the hold. Preparation does not authorize native startup. After
commit, cancellation, stale trust or connection loss quarantines both devices
until both original trusted connections report actual native cleanup and owner
lease-release acknowledgment.

Review corrected two lifecycle issues before compilation: provider-lock waits
must consume the original deadline, and failed runtime-policy reconciliation must
invalidate the exact prior membership even if policy later recovers. The frozen
candidate includes regression tests for both cases.

| Run | Top-level tests | Execution time | Result |
|---|---:|---:|---|
| Focused verified-pair suite | 15 | 15.001 seconds | Passed |
| Complete registry suite | 1,051 | 26.833 seconds | Passed |

Both runs used Go 1.25.0, `-race -p 2 -count=1`, a 120-second test timeout and
a 300-second parent timeout. Each exited naturally with status zero, was reaped,
left no owned process group and produced empty stderr. All 493 source snapshot
files remained unchanged. No external coordinator or model was used.

The integration copied 20 Go files: twelve changes and eight additions, including
three test files. Every existing-file preimage and every new-file absence was
checked before mutation. Source and result receipts are retained in the private
development evidence directory:

- Candidate manifest: `22022f178730d3e80c11e9e18329dd9ff86039c7f21e28c5ab52e552237f0e6f`.
- Full-suite result: `429c9dd916bc591c0411b1fac7ded09bb867cbdba8d734599533c095639e3805`.
- Source integration receipt: `ddb24601c7399a17d9b9c64c0d127be088233543d28b81f2f5e2ec17c5101d9e`.

## Limits

This qualifies the registry lifecycle, not a deployed distributed service. The
provider member role, authenticated grant exchange, approved native capability,
fresh traffic keys and native encrypted transfers still require implementation
and end-to-end checks. The quarantine map is process-local; coordinator restart
does not preserve it. Local device leases and actual owner cleanup remain
independent requirements. No release or production deployment occurred.

The current mechanism is documented in
[routing](../architecture/routing.md#verified-cluster-pair-reservations) and
[cluster authorization](../architecture/security/encryption.md#experimental-cluster-pair-authorization).
