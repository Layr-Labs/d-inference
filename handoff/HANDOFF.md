# Handoff: two-Mac clustering

> Last updated: 2026-10-09

Goal: one model served across two Macs with real collectives, then a terminal
UI wired to real operations, then the wider model matrix. Milestone: one
genuinely supported model by Wednesday 2026-10-14 (America/Los_Angeles).

"Mac A" is the M3 Ultra (256 GB); "Mac B" is the M5 Max (128 GB). They share
one Thunderbolt cable; the link reports 80 Gb/s and RDMA is enabled on both.

## Status by gate

| Gate | Status | Evidence | Next action |
|---|---|---|---|
| G0 Review, reproduction, repair | **Passed, with open findings** | Starting revision verified; 13 checks, package tests and coordinator suite reproduced; two coordinator failures shown to be toolchain-related; three independent reviews done; backend plan proven by a real-JACCL build | Work through [DESIGN-gap-map.md](DESIGN-gap-map.md) |
| G1 Two-Mac qualification | **Passed** | Real collectives over RDMA between the two Macs: 5.36 GiB exact, IP counters at 0.0003% of payload, about 8.7 GiB/s peak; dead-peer behaviour characterized with and without the progress guard; nothing left behind | Keep the guarded JACCL as a requirement for any run with a model loaded |
| G2 One real model on both ranks | **Passed at the runtime level; product path fixed, not yet run end to end** | Qwen3.5 9B generates across both Macs over RDMA through the pair driver: nine requests up to 8,192 prompt tokens, tokens equal or differing only at near-ties (the two chips alone differ the same way), pair exact run to run, prefill 3,069 tok/s with lookahead against 971 and 2,788 for each Mac alone, decode 60–63 against 60–65 and 77–81; a rank killed mid-decode leaves no process and no memory behind. The installed path (`darkbloom start --local --distributed`) now selects the direct bootstrap the worker accepts, requires the guarded JACCL, lets a fenced worker end itself and clears its own journal; unit and script checks pass | Run one HTTP completion through `darkbloom start --local --distributed` on the two Macs, then the lifecycle faults. Blocked on the Mac B port address (below) |
| G3 Terminal UI | **Link onboarding built; the rest not started** | `darkbloom cluster` (guided setup: detects the cable and RDMA, plans a port address, applies it under one macOS approval), `cluster link` (`--fix`, `--remove`, `--watch`), `cluster doctor`, `cluster recover`. The address it applies was lost on Mac B after about two hours with no restart or replug, so a one-time alias is not durable on a bridged port | Durable address (A7); then status, start, stop and model verbs wired to the real owner (C13) |
| G4 Model matrix | **Not started** | The runtime admits one model | Inventory after G2 |
| G5 Larger models | **Not attempted** | — | After G2 |

Independent review: done once, read-only, by three separate reviewers of the
inherited code. The changes made since then have not been independently
reviewed; that gate is open.

## What changed in this round

| Commit | Change |
|---|---|
| `17da399ad` | Coordinator: restore the registry lock across capability reconciliation. The pair slice had introduced a data race on the ordinary single-host path. Race-detector regression test |
| `cf0f34afd` | Slice 16: `libs/darkbloom-cluster-worker`, a macOS 26.2 package that builds the rank worker and a new two-rank transport check against the real JACCL backend, with no pin change. Capability, deadline and prefill-schedule checks staged |
| `9691c059e` | Resident admission tests: a real positive path on both ranks and one property per refusal; library README corrected |
| `745a8f484` | `darkbloom-cluster-stage-check`: one rank's verified load and release on one Mac, no collective. First execution of the loader on the real artifact |
| `960b855f5` | Host gate: swap left from earlier is admitted while memory pressure is normal; refused under warning pressure. Policy tests added |
| `651b08e93` … `c5ca5130b` | Coordinator: member acknowledgement, quarantine release, the research hunks the extraction had dropped, and pair formation (off by default) |
| `420415ded` … `b01fa68ad` | Provider: guided `darkbloom cluster`, the link probe and doctor, atomic 0600 config replace |
| `1280540b6` … `6c67c3987` | Provider: twelve commits that restore the research hooks the extraction had dropped |
| `39c1bb003` | `ProcessDeadline`: a thread ends a rank at its deadline even when the main thread is inside a collective that never returns |
| `81248e5c8` … `ec9789424` | Pair harness (`darkbloom-cluster-pair-check`, `darkbloom-cluster-reference`) and the decode fix `95782b0c8`: rank 0 drains the GPU stream before it hands over its residual. The fix wants a second reader |
| `509f6b480` … `8955cc355` | Provider pair member: membership in the register message, member approval in setup, member control install. The installed owner declines every prepare until the four pieces in C10 exist |
| `20032c2e5` … `310a328b4` | Installed path: no signal before the worker's own deadline, the owner clears its own journal, `cluster recover` for a stranded one, a startup deadline the worker enforces itself, ssh reads the key passphrase from the keychain, direct bootstrap selection, guarded JACCL required, an ordinary provider cannot hold the same model |
| `332d1d601` … `e4c63f3eb` | Coordinator: an owner's requests route to the leader of its pair; `GET /v1/me/cluster-pairs`; `execution_role` and a `cluster` block on `/v1/me/providers`; 25 s prepare window; acknowledgement before the pair frame; decline backoff. Proven against a fake member only |

Pushed: branch `feat/cluster-two-mac-foundation` on `Layr-Labs/d-inference`, draft pull request [1407](https://github.com/Layr-Labs/d-inference/pull/1407), every commit verified. The clone's default push URL stays disabled on purpose; pushes name the destination explicitly. The fork changes are drafts too (table at the end). Nothing is marked ready, nothing has a review request, nothing is merged.

## What only the owner can unblock

Mac B's port has no address again. It got one through `darkbloom cluster`
(approved by the owner in the macOS prompt) on 2026-10-08 at about 19:55 PDT
and had lost it by about 22:20 PDT, with no restart, replug or system sleep
seen. Every two-Mac run is blocked until the owner runs `darkbloom cluster` on
Mac B again and approves. The cause and a durable address are open work (A7).

## Resuming

1. Read [AGENT-HANDOFF.md](../AGENT-HANDOFF.md) for the rules.
2. Re-check the starting facts; they go stale: `git status`, the upstream
   tip, the link state on both Macs (runbook section 1), whether another heavy
   job or a provider is running.
3. Rebuild before any `--skip-build` test run if sources changed since the
   last build, and compare test counts with the ledger.
4. Upstream master was merged twice (`eb4e650ec`, `14c12c041`). Check the
   tip again before the next push and before any pin change.
5. `make provider-test` fails the same 75 tests on unmodified master on Mac A
   (a missing test resource). Compare the failing set with the master
   baseline; do not expect a green local run.

## Dependencies outside this repository

The pinned forks need changes for a supported result. Each one changes
provider bytes, so each is a pin decision (D2 in the gap map). All are drafts.

| Fork | Change | State |
|---|---|---|
| mlx | Upstream JACCL fixes (ml-explore/mlx 4443, 4557, 4558), send-frame tail clearing, the progress guard, the advertised GID index, simulated-verbs tests | Draft [Layr-Labs/mlx#33](https://github.com/Layr-Labs/mlx/pull/33), opened 2026-10-08, eleven verified commits. Contains and extends Gaj's draft [Layr-Labs/mlx#26](https://github.com/Layr-Labs/mlx/pull/26). The guard is required for any serving |
| mlx-c | JACCL bootstrap callback bridge | Gaj's draft [Layr-Labs/mlx-c#14](https://github.com/Layr-Labs/mlx-c/pull/14) (`489e965`, one commit on the pinned `02cf6f4`). Passes a syntax check against the mlx branch above. No caller yet |
| mlx-swift | Pin mlx and mlx-c to the two rows above and mirror the bridge header | Draft [Layr-Labs/mlx-swift#54](https://github.com/Layr-Labs/mlx-swift/pull/54), opened 2026-10-08 on current main. Contains and extends Gaj's draft [Layr-Labs/mlx-swift#33](https://github.com/Layr-Labs/mlx-swift/pull/33) |

Order: mlx and mlx-c merge, mlx-swift repins to the merged commits, then this
repository moves `libs/mlx` and `libs/mlx-swift`. Until then the guarded JACCL
exists only in builds that check out the mlx branch by hand, and the installed
path refuses to serve without it.
