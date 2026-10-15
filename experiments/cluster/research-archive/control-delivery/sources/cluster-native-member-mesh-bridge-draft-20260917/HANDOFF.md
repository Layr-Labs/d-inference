# Committed native key prelude and four mesh rounds

This private successor adds NEXT-TRANSPORT step 2 to the same verified pair,
member connection, owned child and authenticated A socket. It preserves the
frozen key-only invocation package `9347eaf2…cac4f`, qualified A `61f28887…9c5bf`,
and current MAIN member/B integration. No code is installed or enabled in MAIN.

The coordinator authenticates `native_pair_key_confirmed` from each original
provider connection, requires the exact SHA256 of A's canonical bilateral
binding, and sends `native_pair_mesh_ready` only after both reports. This is a
statement about signed provider reports, not coordinator verification of a MAC
whose secret it never holds. The owner obtains that report only after A's
PID-authenticated child completed bilateral confirmation. Native secrets remain
inside A and never enter owner NDJSON or the coordinator relay.

Each `native_pair_mesh` / `native_pair_mesh_reply` packet binds the transcript,
local rank and exact round. The closed contributions are 4, 64, 4, 4 bytes;
replies are 8, 128, 8, 8 bytes, always rank 0 then rank 1. Count two and zero
barriers are checked byte-for-byte. Destination bytes are public native bootstrap
metadata. They are not arbitrary collectives or inference payload. Protocol tags
are `DBNK\x01` for key confirmation, `DBNM\x01` for a contribution, and `DBNG\x01`
for a gathered reply; existing signed outer type/nonce/epoch/generation/sequence
and original absolute timestamps remain authoritative.

The combined owner profile is `native_key_prelude_mesh2_v1`. Key public rounds
0–2 remain first. Native socket rounds 0–3 map to owner public rounds 3–6; a small
private pending-public-round value avoids widening A's existing socket ABI.
Only frames explicitly tagged with the combined profile admit extended public
sequences. Attachment and endpoint also require that tag to match the configured
profile. Legacy mesh and key-only frames still omit it and retain their bounds.
The key-only local completion marker remains unchanged. Combined mode uses the
four real socket exchanges instead. The owned attachment lives through the last
reply. Both native-prelude profiles still refuse model Ready.

All coordinator changes use the existing mutex, real active-grant validation,
16-frame/1 MiB-per-rank bounded writers, 64 KiB frame / 32 KiB payload ceilings,
connection sequences and fixed membership deadlines. Mesh failure follows the
unchanged cancellation-publication/writer-join barrier. Reconnect cannot acquire
the previous connection's grant. Only the original signed actual owner cleanup,
lease-release acknowledgment and transport termination can return device capacity.
Member signer limitations, immediate independent native cleanup and quarantine
semantics are unchanged. No deadline or TTFT clock restarts at mesh readiness.

The source also composes the separately frozen fixture-only noasync correction
`e1473d34…4583b` (ControlTests `54d6619a…8910b`); it changes no invocation runtime.
`base-inputs.json` retains each edited effective preimage, including sources from
the invocation overlay. `integration.json` is the complete 36-path Swift
composition over current MAIN; `go-integration.json` contains the ten Go paths.
`runtime-and-tests.patch` and `qualification.patch` show exact deltas. The Go
closure has 1,119 source/fixture files and eight real cross-repository fixtures.

## Controls staged, not executed

Six new Go test methods cover canonical vectors, all closed shapes and direction
reflection, bilateral confirmation before mesh, four actual WebSocket relay
rounds using the real committed registry, original deadlines, and early / wrong
transcript / wrong rank / skipped / duplicate / malformed / expired messages.
The real protocol decoder and API WebSocket read loop are wired and tested for refusal without a grant. Their failure paths must retain actual-owner quarantine. The existing 35 focused
pair/member/native methods, including deterministic cancellation publication
ordering, remain required. Full API coverage uses the unchanged compiled-name
discovery and four exact disjoint batches, never a larger guessed timeout.

Six new Swift methods cover the same fixed vector, closed owner-wire bounds,
actual owned CPU children completing all four authenticated-socket rounds,
cancellation while awaiting a mesh reply, changed local destination bytes with
connection quarantine, and native Ready refusal. The existing ten invocation
methods and all member/B/legacy/CLI controls remain selected. Actual mesh children
write separate bounded public evidence after the fourth reply. No native model,
JACCL group, RDMA transfer or protected serving profile is invoked by these tests.

## Exact commands after root grants each slot

Set `B` to this directory. Each output must be a new research sibling. The wrapper
refuses source/preimage drift and rechecks complete inventories after every child.
Do not execute any command merely because this source handoff exists.

```sh
python3 -B "$B/GoChecks/prepare.py" --phase go --output /Users/developer/DarkbloomDev/cluster-research/cluster-native-member-mesh-go-build-1-20260917
python3 -B "$B/GoChecks/run.py" --phase go-focused --prepared /Users/developer/DarkbloomDev/cluster-research/cluster-native-member-mesh-go-build-1-20260917 --attempt 1
python3 -B "$B/GoChecks/run.py" --phase go-all --prepared /Users/developer/DarkbloomDev/cluster-research/cluster-native-member-mesh-go-build-1-20260917 --attempt 1
python3 -B "$B/Tests/prepare.py" --output /Users/developer/DarkbloomDev/cluster-research/cluster-native-member-mesh-swift-build-1-20260917
python3 -B "$B/Tests/run.py" --prepared /Users/developer/DarkbloomDev/cluster-research/cluster-native-member-mesh-swift-build-1-20260917 --phase helper --attempt 1
python3 -B "$B/Tests/run.py" --prepared /Users/developer/DarkbloomDev/cluster-research/cluster-native-member-mesh-swift-build-1-20260917 --phase tests --attempt 1
python3 -B "$B/Tests/run.py" --prepared /Users/developer/DarkbloomDev/cluster-research/cluster-native-member-mesh-swift-build-1-20260917 --phase build --attempt 1
```

Go uses pinned offline Go 1.25, race mode, max two jobs, focused 120 s / full
180 s package bounds and the existing 300 s owned child / 16 MiB diagnostic cap.
Swift reuses the prior exact source/cache materializer, five Foundation modules,
helper and 24 legacy owner checks, then the full selected Provider test set and
actual CLI build; max two jobs, unchanged 60/30/900 s owned bounds. Helper and
module hashes are checked again after Provider execution. All failures remain.
No build or fixture result is claimed by this package.

## Next integration boundary

Pass the unchanged post-confirmation connection into the existing
`QwenResidentBootstrap.make` / `JACCLBootstrap.initialize` once; retain its callback
source lifetime and A authority through protected transport retirement. Native
worker integration and the independently qualified sealed-buffer resource policy
must succeed before relaxing the combined profile's Ready refusal. This package
does not implement that gate, CLI installation, a default approval policy,
27B model eligibility changes, or plaintext fallback. The CPU provider fixtures
use the existing explicit test-only TLS bypass after real member negotiation;
the production TLS gate remains in place. Separate Go and Swift fixtures plus a
shared vector do not claim a deployed coordinator-to-native integration test.
