# Retained protected member session adapter — 2026-09-20

This private patch connects an existing authorized protected member session to
the lifecycle interface used by `DistributedLocalServer`. It reuses the exact
member-owned endpoint, request bridge and `ClusterWorkerPair`. It creates no
native process, SSH connection, lease, state owner, key or coordinator policy.
MAIN and frozen predecessors are unchanged. This source has not been compiled.

The selected base is the qualified Provider/shared workspace named in
`lineage.json` and the root promotion map. Its existing protected request gate
still requires P32/C16/O2, empty stop tokens/strings and the approved artifact,
profile, policy and actual Ready values. No public HTTP or CLI route is enabled.

## Concrete changes

- `NativePairMemberSession` publishes a typed completion only after its existing
  terminal logic. Reuse requires actual native cleanup, owner release ACK,
  normal owner exit, request transport join, cancellation publication join,
  local signed release publication and authenticated aggregate release.
- `NativePairMemberControl` captures an exact original session in a claim handle
  before asynchronous preparation. Cancellation and both claim identity checks
  refer to that session, including after reconnect. A post-claim mismatch cancels
  the original obligation. No stale callback consults a replacement session.
- `NativePairRequestExecutionOwner` exposes the same Pair's admission state,
  synchronous admission close and graceful drain. Its request gate and all
  reserve/shutdown delegation remain byte-exact. The bridge changes one
  constructor call to pass the same Pair reference.
- `ProviderLoop.protectedMemberSession` is internal. It repeats current selected
  and owner-default pointer checks, installed metadata/trust/capability checks,
  exact protected descriptor and policy-expiry validation, then compares those
  inputs with the installation already owning the session. It claims that
  session's owner and retains the original loop. It neither renews expired
  policy nor reacquires the already-held device gate.
- `DistributedProtectedMemberSession` adapts existing readiness, reservation,
  quota, lifetime, drain and stop semantics. It closes original Pair admission
  before scheduling teardown. Stop can interrupt a pending graceful drain;
  interrupt work is joined before release. Timeout only quarantines the caller's
  observation. Missing cleanup remains retained; owner shutdown alone is not
  rotation authority.
- `httpInstalledBinding` separates the existing saved binding from optional
  diagnostic samples. Ordinary sessions preserve their previous binding through
  its default. The protected factory supplies the actual saved binding without
  mislabeling the TLS member path as SSH. Rotation still checks the full binding
  and its retained seen-epoch set.

## Scope and qualification

`runtime-and-tests.patch` has six existing-file changes, five new runtime files
and three new test files. All preimages, MAIN observations and unchanged source
controls are explicit in `lineage.json`. `check_sources.py` is read-only and
checks only these small inputs; it does not compile or execute a fixture.

Fifteen staged Swift Testing methods cover all 128 combinations of completion
barriers, single publication, missing aggregate/ACK/exit/signer proof, stale
epoch, timeout and later real completion, original owner delegation, foreign
identity/profile, changed metadata, stop/cancel during startup, normal quota
drain, stop interrupting drain, disconnected-generation isolation and saved
binding preservation. The fixtures fabricate lifecycle observations explicitly;
they supply no native, trust, resource or hardware qualification.

After root source review and a compiler grant, compose this overlay over the
exact qualified Provider base in `lineage.json`, preserving old sources and
evidence. Reuse its cache and the unchanged matching native-member CPU helper.
Run the new `ProtectedMemberSessionCompletionTests` and
`ProtectedMemberSessionLifecycleTests`, then the existing distributed host,
rotation, native-member/shared request and configuration suites. Retain their
actual discovered coverage and owned command receipts. Build the matching CLI
only after those checks pass. No execution or materialization wrapper is run by
this package.

General serving remains separate: the current protected native contract is one
short request with empty stops, while normal HTTP tokenization can add EOS.
There is no fresh authorized-policy transaction/factory here and no claim that
the session can automatically replace itself. Real signed/trusted membership,
encrypted physical pair qualification and a broader admitted workload remain
required before public route activation. No floor, resource limit, lease record,
signing policy or trust requirement changes.
