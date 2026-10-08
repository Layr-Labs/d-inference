# Native-owned key prelude — implementation A

This private slice implements local PID-authenticated bootstrap and native-owned
X25519/HKDF/key confirmation. It does not approve a native runtime, acquire a
native device lease, register members, start a group, load weights or enable
protected inference. The approved architecture input is
`cluster-native-pair-authorization-plan-20260916` (manifest `fe51a10f…e422530`).

## Source delta and ownership

`integration.json` binds nine proposed files to three exact MAIN preimages and
six absences. `runtime.patch` is the complete delta. Bootstrap framing/socket
sources and eight current record codec/adapter sources are copied byte-exact
under `dependencies`; `dependency-pins.json` binds each original path and copy.
No frozen member source or protected facade source is modified.

- `ClusterBootstrapMode` defaults to `.mesh2` at both connect and accept, preserving
  the existing four/six-round gather bytes. The explicit `.nativeKeyPreludeV1`
  mode refuses mesh until the bounded prelude completes. Existing UID, exact
  parent/child PID, private socket/path, deadline and poisoning checks remain.
- `ClusterNativePreludeContext` can only be minted by the native side of an actual
  owned socket. Its locally expected start must exactly match the owner's start.
  Claiming the context twice or cancelling it revokes the single holder through
  a weak callback outside the context lock. Normal completed mesh socket closure
  is distinct from authority invalidation.
- The closed canonical transcript binds epoch, member and native-policy
  generations, membership/approved-native/Plan/artifact/runtime/capability/
  resource/profile digests, suite, transport, schedule, frame/record/byte limits,
  rank and distinct owner-incarnation/lease/launch IDs, then both fresh public
  keys in rank order. Exact-length decoding rejects unknown and extra fields.
  A digest labeled approved-native is a binding field, not evidence of approval.
- `ClusterNativeRecordAuthority(ownedPrelude:)` generates its X25519 private key
  internally. No public grant-only constructor, private/shared-key getter,
  arbitrary secret callback, Codable secret or logged key frame is added.
  Noncanonical and low-order peer keys are refused; HKDF separates record and
  confirmation keys. Each HMAC proof binds its sender rank and transcript.
- `establish()` exchanges only public hello/binding and HMAC proof packets over
  the local socket, verifies the peer proof, then emits a transcript completion.
  The owner must collect both actual completions before starting native mesh.
  Completion is not a native-cleanup or owner-release acknowledgment.
- `makeRecordTransport(io:)` constructs the existing authenticated record adapter
  once, without exporting the derived secret. It binds exact rank/world/frame
  ceiling and charges the existing record limits. The native session retains
  this authority through transport retirement. Invalidation/destruction poisons
  the returned transport and interrupts prelude IO; it never fabricates lease
  retirement. Concurrent entry refuses and poisons the original operation.

No holder lock is held during crypto or socket IO. Key publication and transport
publication are lock-checked linearization points within the original local
bootstrap deadline. Invalidation may occur after publication and before caller
consumption; native request/session checks remain mandatory. Normal successful
mesh attachment may close its setup socket before the transport is constructed,
so transport construction checks the latched authority and original deadline,
not continued setup-socket existence. No request TTFT or session lifetime is reset.

The wire has a 32-byte fixed header and at most 32 KiB public body per packet,
closed six-step order, and 32-byte proof/completion sizes. The current canonical
start/hello/binding are substantially smaller. Received lengths are bounded
before body allocation. This provides no new remote relay queue: the later
member/coordinator relay must retain its separately agreed 16-frame/1-MiB bound,
backpressure and independent cancel path.

## Planned CPU qualification — not run

`Tests/run.py` compiles only Foundation/Bootstrap/CryptoKit modules. It uses the
unchanged repository `owned_process.py`, max two compiler jobs, 60-second compile
bounds, 30-second new fixture bound, 10-second legacy fixture bounds, and a
450-second outer bound. Each real child has an independent four-second alarm;
the fixture never signals a reaped child. Failure output and source rechecks are
retained. A new output directory is mandatory; no cache or model copy occurs.

```sh
cd /Users/developer/DarkbloomDev/cluster-research/cluster-native-key-prelude-draft-20260916
/usr/bin/python3 -B Tests/run.py --output /Users/developer/DarkbloomDev/cluster-research/cluster-native-key-prelude-checks-1-20260916
```

Root must grant the compiler/CPU slot before this command. The planned checks are:

- Seven new groups, 23 actual local children: real parent/native PID refusal,
  locally expected start/role and early-mesh gates; cancellation/concurrent calls/
  context reuse during an actual blocked hello exchange; original deadline;
  key/local-binding/low-order substitutions; reflected proof; bilateral native
  agreement and ciphertext-only pipe relay through the real record adapter;
  once-only factory, cancellation after factory, wrong IO rank and expired factory.
- The exact existing five bootstrap groups/12 children check legacy mesh2.
- The exact existing eight codec and eight adapter groups check framing, tamper,
  replay, concurrent invalidation, bounds and previously frozen vectors.
- `make_vector.py` independently assembles bytes with Python and derives X25519
  using the already-installed OpenSSL 3 EVP, then stdlib HMAC/HKDF. No Swift
  output is used to generate expected values. `tool-pins.json` binds the existing
  library/header. It outputs fixture-only known private/shared keys to the new
  check directory; these constants never enter product code. No package install.

That is 28 planned groups and 35 local child cases. Only Python AST, source
preimages/dependency equivalence and packaging checks have run. Swift typechecking,
CryptoKit/OpenSSL vectors and actual-child behavior remain unqualified.

## Next integration dependencies

A successful CPU result is not verified production membership or encrypted RDMA.
The enabled member mode and exact coordinator handle/attestation/routability
checks must produce an explicit approved native policy and commit both devices
before either child launches, including key generation. The later owner path
must derive local expected start from that retained grant and actual owned child,
relay public records only through current bound connections, reject reconnect/
old generations, and keep post-commit failures quarantined until actual native
cleanup and owner lease ACK. No key-timeout cleanup inference or plaintext fallback.

The existing 27B model policy remains M5/NAX-gated in the frozen member patch.
The later cluster-native policy must explicitly approve its supported non-NAX
arithmetic/runtime/hardware combination; it must not fake `mlx_nax` or rename the
model. 9B remains the first member acceptance path.

The native owner/bootstrap adapter, protected Collective attachment, relay wire,
coordinator approval policy and product integration are deliberately not enabled
in A. Neither are new device-memory capacity, native padding or RDMA staging
claims. Admission must account for sealed frame bytes, staging and the agreed
cumulative byte budget before accepting a known request envelope. Repo-local
SecurityChecks wiring must be extended with the Bootstrap dependency when these
sources are eventually promoted; this private runner supplies that exact closure.
