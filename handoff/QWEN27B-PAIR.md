# Registered Qwen3.8 27B as the second distributed model

> Last updated: 2026-10-09 (branch `work/qwen27b`, base `b816a8c54`)

"Mac A" is the M3 Ultra (256 GB), "Mac B" the M5 Max (128 GB). Raw logs and
reports are outside the repository in the task's evidence folder
`q27-20261009`. Nothing here was pushed.

## Status

| Step | Status | What was shown |
|---|---|---|
| Artifact on both Macs | **Done** | Pinned manifest served by the model CDN; 14 of 14 files verified on each Mac |
| Admission, capability, worker arguments | **Done** | Unit level, from the artifact's real `config.json` and `manifest.json` |
| Per-Mac stage load and release | **Done** | Cuts 12, 16, 20, both ranks, both Macs; equal storage commitments |
| Single-Mac reference | **Done** | 30, 4,096 and 8,192 prompt tokens on both Macs, cuts 16 and 20 |
| Two-Mac run | **Not run** | Mac B's Thunderbolt port has no IPv4 address of its own, so JACCL refuses its device. The pair driver's preflight passes; three launches stopped before any model was loaded |
| Fault with both stages loaded | **Not run** | Needs the two-Mac run |

No pair prefill or decode figure exists for the 27B. The single-Mac figures
below are measured; the pair figures under "What the pair should do" are
arithmetic from them and are labelled as such.

## Artifact

| Field | Value |
|---|---|
| Runtime model ID | `registered_qwen38_27b` |
| Catalog model ID, version | `EigenLabs/Qwen3.8-27B-4bit-mtp`, `2026-09-03-r1` |
| R2 prefix | `v2/EigenLabs-Qwen3.8-27B-4bit-mtp--96c072dbd610/2026-09-03-r1` |
| Manifest SHA-256 | `d1239a5bc6d26d5ce4bf87f22270e3a703f4942e3d0d779948b4f65410df6dcc` |
| `config.json` SHA-256 | `4691da94a1b4ef415aad112ec46abebd33f8a41ad07380e486c0526eb945c1ff` |
| Aggregate SHA-256 | `bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463` |
| Files, bytes | 14 files, 16,320,415,757 bytes |

The CDN returned HTTP 200 for `manifest.json` under that prefix, 3,122 bytes,
hashing to the manifest pin in the runtime's registered specification. Mac A
fetched every file with its size and SHA-256 checked. Mac B received the
directory by `rsync` over the Thunderbolt link (16.3 GB in 55 s) and re-hashed
every file there. Both are flat directories of real files with no symlinks.
The catalog ID carries `-mtp`; the runtime loads the 1,847 text tensors
(15,132,802,048 bytes) and runs with MTP off.

## What changed

| Commit | Change |
|---|---|
| `77165b9ce` | Protocol: a capability's model and profile must be one registered pair of the adapter (9B or 27B); crossed pairs refused |
| `4051ce73c` | Manifest and named-state ceilings per registered model. 9B: 8 GiB and 768 MiB, unchanged. 27B: 16,320,415,757 and 1,616,248,896 bytes |
| `d52114d6a` | Resident admission selects the model from the closed catalog by the identity's model ID. 27B cuts are every whole-interval partition of 64 layers, 4 through 60 |
| `508558c99` | Capability metadata describes whichever registered model the configuration bytes belong to (27B: fifteen partitions, 10,384 bytes of the 16 KiB record) |
| `ea91003be` | Stage check and reference take the model from the artifact's `config.json` |
| `519933904` | 27B metadata fixtures and admission suite |
| `594e11838` | Worker argument validation against the registered model's cuts |
| `1fa10f90a` | Qualification request, reference and pair driver name a registered model |

Every commit builds and passes the shared library tests (22 in 5 suites up to
`ea91003be`, 29 in 6 from `519933904`), the worker capability check and the
protocol capability check. The worker package tests pass at each commit that
touches that package (46 at the tip: 12 worker, 34 qualification). The 9B's
admission suite, capability fixtures, plan and profile fingerprints are
unchanged.

Two files other workers also edit carry one small hunk each:
`QwenResidentAdapterDefinition.swift` (the profile ID comes from the model's
row) and `WorkerConfiguration.swift` (model ID and cut checked against the
registered model).

## Stage loads (model level, one Mac, no collective)

`darkbloom-cluster-stage-check`, worker binary `5facd7ef…a099f`, guarded JACCL
`aec94c2b`. Verified aggregate `bbd0e0ad…8463` in all twelve runs. No process
was left after any of them.

| Mac | Cut | Rank | Layers | Active loaded | Load | Active after release | Storage commitment |
|---|---:|---:|---:|---:|---:|---:|---|
| A | 12 | 0 | 12 | 3.059 GiB | 11.0 s | 1,520 B | `d66ec4a7c8fb…` |
| A | 12 | 1 | 52 | 11.035 GiB | 13.7 s | 6,472 B | `d66ec4a7c8fb…` |
| A | 16 | 0 | 16 | 3.857 GiB | 10.7 s | 2,016 B | `092458153610…` |
| A | 16 | 1 | 48 | 10.238 GiB | 13.5 s | 5,976 B | `092458153610…` |
| A | 20 | 0 | 20 | 4.654 GiB | 11.6 s | 2,512 B | `b176601035e4…` |
| A | 20 | 1 | 44 | 9.440 GiB | 13.2 s | 5,480 B | `b176601035e4…` |
| B | 12 | 0 | 12 | 3.059 GiB | 6.6 s | 1,520 B | `d66ec4a7c8fb…` |
| B | 12 | 1 | 52 | 11.035 GiB | 7.9 s | 6,472 B | `d66ec4a7c8fb…` |
| B | 16 | 0 | 16 | 3.857 GiB | 6.7 s | 2,016 B | `092458153610…` |
| B | 16 | 1 | 48 | 10.238 GiB | 7.6 s | 5,976 B | `092458153610…` |
| B | 20 | 0 | 20 | 4.654 GiB | 6.8 s | 2,512 B | `b176601035e4…` |
| B | 20 | 1 | 44 | 9.440 GiB | 7.4 s | 5,480 B | `b176601035e4…` |

Cached bytes after release were 0 and the model object was deallocated in
every run. The two ranks of a cut, and the two Macs, derive the same storage
commitment. System wired memory stayed within its usual wander (A 8.2–8.6
GiB, B 5.0–5.7 GiB before and after). The load time includes hashing all
16.3 GB of the artifact.

## Single-Mac reference (model level, one Mac, no collective)

`darkbloom-cluster-reference`, both stages in one process, chunk 512, greedy,
no stop IDs, prompts through the 27B's own tokenizer in its chat format with
thinking disabled. Clock: prefill and decode are the summed in-process frame
times (stage 0 forward, residual copy, stage 1 forward, selection); "request"
is the in-process wall time from request state to retirement, which also
includes copying every row to the CPU. None of these is a serving figure.

| Mac | Prompt tokens | Outputs | Cut | Prefill tok/s | Decode tok/s | Request s | Process total s |
|---|---:|---:|---:|---:|---:|---:|---:|
| A | 30 | 64 | 16 | 9.5, then 88.9 | 29.5, 29.8 | 5.52, 2.67 | 30.5, 27.5 |
| A | 30 | 64 | 20 | 98.8 | 30.2 | 2.61 | 26.2 |
| A | 4,096 | 64 | 16 | 303.6, 305.3 | 28.7, 28.5 | 16.11, 16.05 | 40.0, 39.4 |
| A | 4,096 | 64 | 20 | 305.4 | 21.9 | 16.82 | 40.6 |
| A | 8,192 | 128 | 16 | 298.7, 298.4 | 28.3, 27.1 | 32.62, 32.88 | 56.1, 56.8 |
| A | 8,192 | 128 | 20 | 298.7 | 28.2 | 32.63 | 56.4 |
| B | 30 | 64 | 16 | 53.7, then 127.1 | 28.9, 29.1 | 2.91, 2.57 | 17.4, 17.1 |
| B | 30 | 64 | 20 | 127.3 | 29.0 | 2.57 | 17.1 |
| B | 4,096 | 64 | 16 | 880.4, 881.9 | 28.0, 27.8 | 7.26, 7.27 | 21.8, 22.0 |
| B | 4,096 | 64 | 20 | 878.9 | 27.8 | 7.28 | 21.8 |
| B | 8,192 | 128 | 16 | 772.3, 760.7 | 27.0, 27.1 | 15.90, 16.06 | 31.0, 31.2 |
| B | 8,192 | 128 | 20 | 800.4 | 27.2 | 15.50 | 30.4 |

Two values in a cell are two separate processes. The first short run on each
Mac paid a one-time cost in its only prefill frame. The 21.9 tok/s decode on
Mac A at cut 20 is one run; the same request decoded at 28.5–28.7 at cut 16.

- **Memory.** 14.09 GiB active with both stages loaded; peak 14.4 GiB (30
  tokens) to 16.3 GiB (8,192); 7,992 bytes active and 0 cached after release;
  both stage models deallocated in all 18 runs; no process left.
- **Determinism.** On each Mac the two runs of each request are `exact`:
  tokens, final row bytes and all 144 state digests.
- **Across cuts.** On each Mac, cut 16 against cut 20 is `exact` for all
  three requests.
- **Across chips.** Mac A against Mac B: every token equal for all three
  requests at both cuts (64, 64 and 128 tokens), verdict
  `tokensEqualLogitsDiffer`. The final rows differ by at most 0.13, 0.36 and
  0.375; 127 of 144 state entries differ. As with the 9B, the chips are not
  bit-identical; unlike the 9B's long prompts, no token differed here.
- **Speed ratio.** Mac B prefills 2.9 times as fast as Mac A at 4,096 tokens
  and 2.6–2.7 times at 8,192. Decode is the same on both, 27–30 tok/s; the
  9B's faster decode on Mac B does not carry over.

## The pair: not run, and why

`darkbloom cluster link` on Mac B reports `portBridgedWithoutAddress`: the
active Thunderbolt port is a member of the bridge with no IPv4 address of its
own and so publishes no IPv4-mapped GID. Mac A reports `ready`. The Mac had
not restarted. Giving the port its address is a network setting behind a macOS
approval prompt (`darkbloom cluster link --fix`), which is the owner's to make.

What ran without the link:

- **Preflight, cut 16 serial and cut 20 lookahead: passed.** Worker and
  metallib hashes identical on both Macs, both workers carry the JACCL
  progress guard, both describe the 27B identically for their own
  `config.json` and `manifest.json`, no worker running.
- **Launch, free memory prepared on both Macs: stopped at JACCL
  initialization.** Rank 1: `[jaccl] No IPv4-mapped GID for this device`,
  exit 1. Rank 0: `[jaccl] Recv failed with errno=57`, exit 1. JACCL
  initializes before the load agreement and the load, so no stage was loaded
  on either Mac. Both ended by themselves; no worker left; run files removed.
- **Two earlier launches stopped one step sooner, at the host gate**, once on
  each Mac: `Selected-stage loading requires at least 6 GiB actual free
  memory` (see the next section). In the second, rank 0 had passed the gate
  and waited in JACCL for a peer until its 45 s lifetime, then exited 124.

### What the pair should do (arithmetic, not measured)

A layer pipeline with lookahead is bounded by its slower stage. With the
8,192-token rates measured at cut 16 (299 tok/s on Mac A, 766 on Mac B) and
equal cost per layer:

| Cut (layers on A) | Serial tok/s | Lookahead bound tok/s |
|---:|---:|---:|
| 12 | 590 | 940 |
| 16 | 550 | 1,020 |
| 20 | 515 | 960 |

The balance point is 64 / (1 + ratio) = 16 to 18 layers on Mac A, so the cut
the speed ratio suggests is 16, which is also the research's cut. Cut 20 is
the neighbour on the other side of that point and is the second cut prepared. For the 9B
the same bound predicted 3,186 tok/s at cut 4 and 3,069 was measured. On
these numbers the pair would prefill about a third faster than Mac B alone
with lookahead, slower than Mac B alone without it, and decode no faster than
either Mac (27–28 tok/s less the per-token transfers).

## The free-page gate refused both Macs tonight

The host gate requires actual free pages: at least 6 GiB, and during a load
the remaining tensors plus two host copies plus 4 GiB. It never counts file
cache. Both Macs spent the night reading model files for several workloads,
and their free pages sat between 0.1 and 21 GiB while 60 to 143 GiB was
file-backed and reclaimable. Hashing an artifact before loading it moves that
artifact's size from free to cache as well.

| When (UTC) | Where | Refusal |
|---|---|---|
| 07:14 | Mac B, single-Mac reference (6 runs) | `Selected-stage loading requires at least 6 GiB actual free memory`, partway through loading. Two minutes later: 20.8 GiB free, 66.6 GiB inactive |
| 07:17 | Mac A, 8,192-token reference (2 runs) | `Resident request exceeds live actual-free or allocator policy`, after loading; 6.3 GiB free with the model loaded |
| 08:00 | Mac A, pair rank 0 | the 6 GiB message, before JACCL. Five minutes later: 2.1 GiB free, 143 GiB file-backed |
| 08:06 | Mac B, pair rank 1 | the 6 GiB message, before JACCL. At 08:19: 0.6 GiB free, 80.7 GiB file-backed |

The per-rank stage loads fit each time they were tried; the whole 27B in one
process (14.1 GiB plus the floor and the request allowance, about 23 GiB free
before starting) often did not.

To get the reference numbers, free pages were restored without privileges
and without changing any setting: a process touched 44 GiB of anonymous
memory in 1 GiB steps and exited, twice on Mac B and once on Mac A,
stopping early if memory pressure left normal or the compressor grew by 2 GiB
(neither happened). File-backed pages fell from about 60–80 to 37 GiB on Mac B
and from 143 to 101 GiB on Mac A; 44 GiB was free afterwards. This is a
workaround for a qualification night, not something a serving path should do.
A supported 27B needs either a host that is kept in that state or a gate that
can tell reclaimable cache from pressure.

## What a distributed execution policy for the 27B must state

The ordinary policy admits the 27B on one chip class with one runtime
capability. That is a single-Mac serving rule and stays as it is. A pair on
mixed chips needs its own explicit grant, and it must not be reached by
reporting a capability a member does not have or by renaming the model.

1. **Identity.** The artifact (manifest, configuration and aggregate hashes),
   the runtime model and profile, the adapter and arithmetic policy, the
   worker binary hash, the cut and the prefill schedule. A grant is for that
   tuple, not for "the 27B".
2. **Members by rank.** Which chip classes may hold rank 0 and rank 1, stated
   per rank. Tonight's evidence covers an M3 Ultra and an M5 Max on one host
   each, not yet as a pair.
3. **What "correct" means across chips.** The two chips produce equal tokens
   and different logits on the three requests run. The policy must name the
   accepted comparator verdicts (`exact`, `tokensEqualLogitsDiffer`, and
   whether `divergedAtNearTie` within a stated number of units in the last
   place is accepted), and the single-chip reference a pair is judged against.
4. **Memory per member and cut.** Free pages needed to load (cut 16: about
   9.1 GiB for rank 0 and 15.4 GiB for rank 1) and to admit the largest
   request (the 6 GiB floor or state plus fusion plus 4 GiB, whichever is
   larger), and how a member is brought to and kept in that state given the
   section above.
5. **Cut and roles from measured speed.** The slower chip takes rank 0 and
   about a quarter of the layers (cut 16 for this pair); lookahead is the
   schedule that makes the pair worth running. A pair in the other order
   would want a cut above 32.
6. **Time budgets sized for this model.** Load is 7–14 s per rank and the
   whole session lives inside 300 s. By the arithmetic above an 8,192-token
   prompt would take about 8 s to first token with lookahead and about 15 s
   without; the provider's fixed first-token budget of 10 s plus 1 ms per
   prompt token (18.2 s) and its 90 s startup ceiling were set on the 9B.
7. **Transport.** The guarded JACCL with a progress limit above the slowest
   chunk, and the link state both Macs must report before a start.
8. **Scope.** Greedy text, one request at a time, MTP off: the `-mtp`
   catalog ID is served without its speculative head.

## Provider and coordinator: what stands in the way

Neither names the 9B anywhere in the cluster, distributed or pair path; model
and profile IDs, cuts and partitions come from the capability record. What
blocks or constrains a 27B distributed session (paths from the repository
root, lines at `b816a8c54`):

| Where | What |
|---|---|
| `provider-swift/Sources/ProviderCore/Models/ModelRuntimeRequirements.swift:141-152` | Both 27B catalog IDs require `appleM5` and `mlxNAX` |
| `provider-swift/Sources/darkbloom/StartCommand+ClusterMember.swift:31` and `:39` | A member's capability set is `[.appleM5]` on an M5 and empty otherwise, never `mlxNAX`; `requireEligible` then throws for either 27B ID on any Mac. `StartCommand+Distributed.swift:16` goes through the same function, so `start --local --distributed` cannot start a 27B session either |
| `provider-swift/Sources/ProviderCore/ProviderLoop.swift:810`, `ProviderLoop+NativePair.swift:12`, `Coordinator/CoordinatorClient+NativePair.swift:23`, `Coordinator/CoordinatorClientCodec.swift:34` | The same eligibility check drops the 27B from the advertised and cluster model lists and refuses the pair member control |
| `coordinator/registry/provider_capabilities.go:16`, `:251`, `:290`, `:304`; `coordinator/internal/api/catalog/registration/registry_validation.go:109` | The coordinator's built-in rule names only `EigenLabs/Qwen3.8-27B-4bit`. The registered artifact's ID is the `-mtp` one, which the coordinator gates only as far as its catalog row says. The provider gates both IDs |
| `coordinator/registry/verified_pair_membership.go:26` | Pair membership runs the ordinary routing gate for the model, so a pair for the 27B is `not_eligible` wherever that gate requires `mlx_nax` |
| `coordinator/registry/native_pair_approval.go:14-17`, `native_pair_reservation.go:55` | A pair approval carries an allowed-chip list but, by its own comment, does not relax model eligibility. This is where a distributed policy would have to be expressed |
| `provider-swift/Sources/ProviderCore/Inference/Distributed/Installed/DistributedInstalledManifest.swift:39`, `Server/Distributed/DistributedLocalServer+HTTP.swift:52`, `Config/ClusterNativeMemberAttachment.swift:37`, `coordinator/registry/native_pair_formation.go:213` | One installed artifact answers to exactly its manifest's model ID, and an approval must name that same string |
| `provider-swift/Sources/ProviderCore/Inference/Distributed/Installed/DistributedInstalledOwner.swift:17`, `Coordinator/NativePairMemberSession.swift:106` | Coordinator-formed pairs are declined for every model (gap C10) |
| `provider-swift/Sources/ProviderCore/Inference/Distributed/Installed/DistributedInstalledSession.swift:137`, `DistributedInstalledOwner.swift:47`, `provider-swift/Sources/darkbloom/StartCommand+Distributed.swift:19-20` | 90 s startup ceiling and the 10 s + 1 ms per token first-token budget |
| `provider-swift/Sources/ProviderCore/Inference/Distributed/Installed/DistributedInstalledPlan.swift:18` and `:55` | One arithmetic policy ID and one worker environment for every model; fine today, since the 27B uses the same policy |
| `provider-swift/Sources/ProviderCore/Inference/Distributed/Membership/ClusterMemberPreparation.swift:30` | A member hashes the whole artifact before registering, with no deadline: 16.3 GB instead of 6.1 GB |

Byte and count bounds in the provider's distributed path (manifest size,
tokenizer files, the 16 KiB capability record, record and cumulative limits
of a pair approval) are all satisfied by the 27B.

## Resuming

1. On Mac B, the owner runs `darkbloom cluster link --fix` (or sets an address
   on the Thunderbolt port); `darkbloom cluster link` must print `Local link:
   ready` on both Macs.
2. Check free pages on both Macs (`vm_stat`); each rank needs the figures in
   policy item 4 before it starts.
3. Requests: the three in the evidence folder's `requests/` (30, 4,096 and
   8,192 prompt tokens). References at cuts 16 and 20 for both Macs are in
   `reference/`.
4. Run `darkbloom-cluster-pair-check run` (rank 0 Mac A, rank 1 Mac B,
   `--progress-timeout-ms 60000`) at cut 16 and cut 20, `serial_v1` and
   `one_chunk_lookahead_v1`, a warm-up and three repetitions each, and compare
   each report with both Macs' references (`--allow-schedule-difference yes`
   for lookahead).
5. Fault: with both stages loaded and the 8,192-token request decoding, end
   rank 1 with SIGTERM; rank 0 must report the JACCL error at its limit and
   exit by itself. Record worker processes and wired memory on both Macs
   before and after, and compare a short run after the fault with one before.

## Not done

- No two-Mac run of the 27B, so no pair speed, no pair comparator verdict and
  no fault result.
- Stage loads were run at cuts 12, 16 and 20 only. The other twelve cuts are
  admitted and planned in the unit suite and have never been loaded.
- Rank 0 on Mac B (the pair in the other order) was stage-loaded but no
  reference or plan was made for cuts above 32.
- The request allowance and the metadata profile's planning scope for the 27B
  have no unit test: they need the 1,847-entry tensor inventory, which is not
  a fixture. They ran for real in every stage load and reference above.
- The changes on this branch have not been independently reviewed.
