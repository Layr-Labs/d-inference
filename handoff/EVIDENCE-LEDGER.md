# Evidence ledger

One row per claim that was actually tested. "Mac A" is the M3 Ultra (256 GB,
macOS 27.2, Xcode 27.0, Swift 6.4); "Mac B" is the M5 Max (128 GB, macOS 27.0).
Level is one of: unit, integration, physical (two Macs, real link), model (real
artifact). Raw logs are kept outside the repository in the task's evidence
directory; each row names the run folder.

## Starting revision

| Claim | How checked | Result |
|---|---|---|
| Branch tip and base | `git rev-parse`, `git merge-base --is-ancestor` | Tip `7db3f4ebe` on base `7b42e921a` (#1213): confirmed |
| Commit count on top of base | `git rev-list --count 7b42e921a..7db3f4ebe` | **22**, not the 19 reported |
| Root handoff files | `git ls-tree -r`, history search | `AGENT-HANDOFF.md` and `handoff/` were **not in the branch**; created in this work |
| Submodule pins unchanged from base | `git ls-tree` on base, tip and upstream master | mlx `cb77239b`, mlx-swift `6923a80f`, mlx-swift-lm `3fd4944c`: identical on all three |
| Upstream drift | fetch of upstream master, `git merge-tree` | Master `57fe69d87` is 12 commits ahead; trial merge conflicts only in `docs/reference/protocol-messages.md` |

## Reproduced checks (Mac A)

| Claim | Command | Commit | Level | Result | Remaining uncertainty |
|---|---|---|---|---|---|
| 13 focused cluster checks | each `run.sh` / `run.py` under `libs/darkbloom-cluster/Tests/*Checks` and `provider-swift/Tests/Cluster*Checks` | `7db3f4ebe` | unit | 13 of 13 exit 0 (`baseline-20261008T233838Z`) | None of them runs a collective or a model |
| Cluster package tests | `swift build --build-tests`, metallib copied into the test bundle, `swift test --skip-build` in `libs/darkbloom-cluster` | `7db3f4ebe` | unit | 15 tests in 4 suites pass | The README's order (metallib before the build) loses the file on this toolchain; fetch it after the build |
| Transport contract check | `swift run cluster-loopback-check` | `7db3f4ebe` | unit | Passes; reports `jacclAvailable: false`, as expected for a macOS 14 target | — |
| Coordinator suite | `make coordinator-test` with Go 1.27.1 | `7db3f4ebe` | unit | 64 groups ok; **2 packages fail** | See next row |
| The two coordinator failures are environmental | same two packages on the unmodified base worktree | `7b42e921a` | unit | Same 4 tests fail identically; the cluster commits do not touch those packages | Repository pins Go 1.26.8; the tests were not rerun under the pinned toolchain |
| Provider suite "541 tests in 84 suites" | — | — | — | **Not reproduced** | The command that produced that count is not recorded in the branch |

## Backend

| Claim | How checked | Commit | Level | Result | Remaining uncertainty |
|---|---|---|---|---|---|
| The pinned MLX can build real JACCL without a pin change | `build-native-worker.sh` (26.2 Swift and C++ targets); `nm` for the JACCL group; `vtool` for the Mach-O minimum | `cf0f34afd` | integration | Both products link the real backend; minimum is exactly 26.2 | — |
| JACCL is available on Mac A | the check run with no cluster environment | `cf0f34afd` | integration | Strict init reaches JACCL and refuses for missing rank, device file and coordinator | — |
| Worker metadata command | native worker `--describe-runtime` against the registered 9B fixtures | `cf0f34afd` | integration | 82 fields; equal to the shared protocol fixture except the binary hash and the advertised prefill schedules | No model opened |
| Worker orchestration | `DarkbloomClusterWorkerTests` built for 26.2 | `cf0f34afd` | unit | 9 of 9 pass | Fake runtime |
| Capability, deadline, prefill-schedule checks | the three staged `run.sh` | `cf0f34afd` | unit | All pass | — |

## Two-Mac link (read-only inventory and first attempt)

| Claim | How checked | Machine | Level | Result | Remaining uncertainty |
|---|---|---|---|---|---|
| RDMA enabled | `rdma_ctl status` | A and B | physical | `enabled` on both | — |
| One active RDMA port per Mac on the shared cable | `ibv_devinfo`, `system_profiler SPThunderboltDataType` | A and B | physical | One `PORT_ACTIVE` Thunderbolt device on each; link reports 80 Gb/s; each side names the other's model | — |
| IP path over the cable | `ping` both ways, `route -n get` | A and B | physical | 0% loss, about 0.5 ms; routed over the Thunderbolt interface (A) and the Thunderbolt Bridge (B) | This is the IP path, not RDMA |
| Two-rank JACCL initializes | `darkbloom-cluster-collective-check --mode raw`, rank 0 on A, rank 1 on B | A and B | physical | **Failed, cleanly.** Rank 1: "No IPv4-mapped GID for this device". Rank 0 then failed on its coordinator socket. Both exited 1; no process left on B (`g1/…-first-small`) | Not yet rerun |
| Cause of the refusal | `ifconfig`, `ibv_devinfo -v`, `networksetup -getinfo` | B | physical | B's Thunderbolt port is a member of the Thunderbolt Bridge and has no IPv4 address of its own; its device lists 2 GIDs, none IPv4-mapped. A's port has its own address and an IPv4-mapped GID | Whether an address on a bridged port is enough, or the port must leave the bridge, is untested |
| RDMA carried data | — | — | — | **Not shown.** No collective has completed | Planned evidence: payload volume against interface byte counters, loaded images and stack samples |

## Fixes

| Claim | Test | Commit | Level | Result |
|---|---|---|---|---|
| The pair slice made capability reconciliation race with App Attest revocation on the ordinary single-host path | `TestCapabilityReconciliationHoldsRegistryLockAgainstRevocation` with `-race` | `17da399ad` | unit | Race detector reports the map race on the inherited code; clean with the fix. Registry, protocol and provider API packages: 13 ok, 0 races |
| The admission tests could not fail for the reason each named | removing the duplicate-peer guard | `9691c059e` | unit | The rewritten suite fails at that case; a positive admission on both ranks now runs from the registered metadata |
| The swap rule | constructed observations | `960b855f5` | unit | Three expectations fail under the previous rule; 22 tests in 5 suites pass with the change |

## Model artifacts

| Claim | How checked | Machine | Result |
|---|---|---|---|
| The runtime accepts one model | source read, registered specification | — | Registered Qwen3.5 9B 4-bit, catalog version `2026-09-03-r1`, 12 files, 6,113,952,230 bytes, aggregate `127de76b…c24b` |
| That artifact was present at the start | Spotlight and directory search by exact file size and name | A and B | Absent on both. B had a same-named folder with tokenizer and config only (config hash differs, no weights) |
| The catalog serves the registered manifest | `manifest.json` fetched from the model CDN under the registered prefix | A | 2,685 bytes; SHA-256 `4f273502…2aa4`, equal to the manifest hash pinned in the runtime |
| The artifact is now on Mac A | per-file download, size and SHA-256 checked against the manifest | A | 12 of 12 files verified; 6,113,952,230 bytes; flat directory, no symlinks; `config.json` hash equals the pinned `c8e767de…4423` |
| The artifact is now on Mac B | copied over the Thunderbolt link (existing SSH login, already-pinned host key), then every file rehashed on B | B | 12 of 12 verified, same total bytes |

## Real model, one Mac at a time

`darkbloom-cluster-stage-check` at `745a8f484` (gate from `960b855f5` for the
Mac B rows). Level: model, single host. No collective is created.

| Claim | Machine | Result | Remaining uncertainty |
|---|---|---|---|
| The verified loader opens the real artifact and materializes each rank's stage | A | Cuts 4, 8, 12, 16 × ranks 0, 1: all 8 load in 2.9–3.6 s; verified aggregate `127de76b…` | Not a generation result |
| Both ranks derive the same storage commitment for a cut | A | Equal for each cut (cut 4: `e2e41be21c40…`) | — |
| The loaded stage is released | A | After release: 0.5–3.5 KB active, 0 cached; model object deallocated in all 8 runs | A few KB remain allocated; not identified |
| The host gate refuses a Mac with swap in use | B | Before `960b855f5`: refused, "swapped selected-stage resource observation" (about 3 GB swapped, 64 GiB free, pressure normal) | — |
| With swap admitted at normal pressure, Mac B loads and releases | B | Cut 4, ranks 1 and 0: 2.7 s and 2.2 s; released; no process left; system wired memory 5.33 → 5.60 GiB across both runs | Other cuts not run on B |
| The two Macs agree on the stage commitment | A and B | Cut 4: `e2e41be21c40…` on both | This is the value the ranks compare before serving; the comparison over the link has not run |

## Link readiness probe (`darkbloom cluster link`, `761f14d64`)

| Claim | Machine | Level | Result |
|---|---|---|---|
| A cabled, configured Mac reports ready | A | physical (local state only) | `ready`: one active device, own IPv4 address, IPv4-mapped GID published; five other ports reported down; exit 0 |
| A port inside the Thunderbolt Bridge is named as the fault | B | physical (local state only) | `portBridgedWithoutAddress` for the active port: member of the bridge, no IPv4 address of its own, no IPv4-mapped GID; exit 1 with the guidance sentence. This is the condition JACCL refused |
| Parsers, verdicts, bounded child runner | A | unit | 273 expectations in 15 groups; no address, MAC or GID in any report |

## Coordinator fixes

| Claim | Test | Commit | Result |
|---|---|---|---|
| An accepted member is acknowledged exactly once, after every refusal point | real in-process provider session, exact wire bytes | `651b08e93` | Fails before ("socket ended before cluster_member_accepted"), passes after; solo and refused registrations receive none |
| A quarantined pair is released once nothing can still run under it | registry tests on a fake clock | `b048897ca` | Five cases fail before (machine stays `pair_reserved`), pass after |
| A member's pair grant ends when the member loses trust | ported research test, eight revocation paths | `4b48612ef` | Eight cases fail before, pass after; a passing periodic challenge keeps the grant |
| Model work is not sent to a member or a held device | ported research tests | `45d21f76d` | Load, prefetch and desired-models crossings fail before, pass after; a member receives an empty desired list |
| The branch merges with current master | trial merge in a scratch worktree, `go test ./coordinator/...` | merge `c7ddceb51` (not on the branch yet) | Conflicts only in three document date stamps; 103 packages ok; the same two toolchain-related packages fail |

## JACCL fork branch (`darkbloom/jaccl-send-frame-progress-guard`, local only)

Level: unit, simulated verbs (ASan, UBSan, TSan). Nothing here has run on RDMA hardware.

| Claim | Commit | Result |
|---|---|---|
| Stale bytes follow a partial payload on the pin, and the fix clears them | `97fbd680` | On the pin 4 of 5 groups fail with a non-zero stale tail; all pass with the fix |
| A silent peer, a lost completion and a failed completion end in an error, with resources released and the group closed | `aec94c2b` | On the previous commit 34 of 38 cases fail (a silent peer is ended only by the harness watchdog; a failed completion is accepted as data); 38 of 38 pass |
| The source GID index follows the advertised GID | `83291eb6` | Compiles; no test. On Mac A the IPv4-mapped GID is at index 2, not 1 |
