# Remote owner first slice

Four new Swift files define transport-independent binding and one local owner's
lease bookkeeping. Six unchanged public Protocol files are copied under `upstream`
and pinned in `upstream-sources.json`; no existing Process, Pair, Request, provider
or native source is changed.

`ClusterOwnerBinding` reuses `ClusterWorkerSession` identity/profile/plan validation.
`ClusterOwnerLeaseState` is a value driven on the remote owner's serial executor:

- After obtaining a real device lease and excluding unresolved older ownership,
  initialize with this host's time and remaining owner lifetime. Persist the
  native launch UUID before `beginNativeLaunch`/`Process.run`; report start and
  readiness only from the local supervisor.
- Authenticate and bound control input before `accept`. Its returned action is
  an instruction to the adapter, not proof it happened. `reserve` carries a
  remaining duration, translated once to this host's uptime and clamped to the
  existing owner lifetime. Request payload/geometry and admission remain the
  existing worker's responsibility. A separate caller-origin TTFT admission cap
  must still be enforced by the endpoint; this code does not invent one.
- Actual admitted bytes replace the pending offered ceiling. Native retirement
  permits a release request; bytes disappear only after actual resource release.
  The adapter permits the next paired request only after both ranks retire.
- `disconnect`, expiry, malformed route/sequence and illegal transitions quarantine
  the lease. Service `requiresNativeFence` independently of callbacks. No timeout,
  signal-sent or EOF API creates an exit observation. An observed native exit still
  leaves request resources charged until their release returns.
- The terminal DTO exists only after actual native terminal observation (or no
  launch was attempted), request release, durable ownership-record retirement and
  actual device-lease release. These are caller-observed facts, not cryptographic
  proof. The caller must bind every native event to its owning child.
- Reconstructed incomplete ownership uses `recoveredUnresolved`, reports unknown
  charged bytes and cannot launch, become ready, manufacture direct-child exit or
  release a device lease. Actual orphan resolution is intentionally not implemented.

The proposed SSH transport and precise native bootstrap/recovery obligations are
in `DESIGN_ADDENDUM.md`. Its relative links are intended for promotion under the
repository's `docs/design/` directory. No SSH/network/crypto implementation is
included in this slice, and no native/GPU or physical performance claim is made.

Targeted Foundation-only validation:

```sh
xcrun swift test --jobs 1 -Xswiftc -warnings-as-errors
```

The target has no MLX or downloaded dependency. `Tests/ClusterOwnerLeaseStateTests.swift`
contains 15 fabricated tests for real transition failures, deadline/capacity
retention, stale identity/sequence, partial admission and clean versus abnormal
retirement. See `records/` for exact executed status; source-only checks do not
qualify authentication, process fencing or multi-machine operation.
