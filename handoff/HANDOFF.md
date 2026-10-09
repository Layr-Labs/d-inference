# Handoff: two-Mac clustering

> Last updated: 2026-10-08

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
| G2 One real model on both ranks | **Passed at the runtime level; product path open** | Qwen3.5 9B generates across both Macs over RDMA through the pair driver: nine requests up to 8,192 prompt tokens, tokens equal or differing only at near-ties (the two chips alone differ the same way), pair exact run to run, prefill 3,069 tok/s with lookahead against 971 and 2,788 for each Mac alone, decode 60–63 against 60–65 and 77–81; a rank killed mid-decode leaves no process and no memory behind | Serve the same thing through `darkbloom start --distributed` and then the coordinator: the installed plan always passes the bootstrap flags the worker refuses; the owner path signals workers on fixed 2 s timers |
| G3 Terminal UI | **Not started** | Existing surface mapped: `cluster configure/status/doctor/worker-owner`, hand-rolled termios UI elsewhere in the CLI, no TUI library | Start from the link probe and `cluster doctor`; add the missing verbs (C13) |
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

Pushed: branch `feat/cluster-two-mac-foundation` on `Layr-Labs/d-inference`, draft pull request 1407 (opened 2026-10-08 at `6693e195b`, every commit verified). Later commits are local until the next push. The clone's default push URL stays disabled on purpose; pushes name the destination explicitly. The `mlx` fork branch is local only: that fork carries upstream's rule against agent-written commit messages and agent pushes, so it waits for the owner.

## What only the owner can unblock

Nothing at the moment. Mac B's port got its address through `darkbloom cluster`
(approved by the owner in the macOS prompt). The address is lost at a restart
or a cable replug; running `darkbloom cluster` again on that Mac reapplies it.

## Resuming

1. Read [AGENT-HANDOFF.md](../AGENT-HANDOFF.md) for the rules.
2. Re-check the starting facts; they go stale: `git status`, the upstream
   tip, the link state on both Macs (runbook section 1), whether another heavy
   job or a provider is running.
3. Rebuild before any `--skip-build` test run if sources changed since the
   last build, and compare test counts with the ledger.
4. Upstream master is 12 commits ahead of this branch's base with identical
   submodule pins; a trial merge conflicts only in
   `docs/reference/protocol-messages.md`. Refresh before any pull request.

## Dependencies outside this repository

The pinned forks need small changes for a supported result. Each one changes
provider bytes, so each is a pin decision (D2 in the gap map). Draft pull
requests for the research halves already exist on the forks (opened by Gaj
on 2026-09-28):

| Fork | Change | State |
|---|---|---|
| mlx | Clear the tail of partially filled JACCL send frames | Draft [Layr-Labs/mlx#26](https://github.com/Layr-Labs/mlx/pull/26). The same commit is carried onto the current pin on the local branch `darkbloom/jaccl-send-frame-progress-guard` (`97fbd680`) |
| mlx | Bound every JACCL polling loop, check completion status, release and report on timeout | **Local only** (`aec94c2b`). Shown on the real link; required for any serving. Not pushed: the fork carries upstream's rule against agent commits and pushes, so it waits for the owner |
| mlx | Send from the advertised GID's index | Local only (`83291eb6`); not needed on this pair |
| mlx-c | JACCL bootstrap callback bridge | Draft [Layr-Labs/mlx-c#14](https://github.com/Layr-Labs/mlx-c/pull/14) (`489e965`, one commit on the pinned `02cf6f4`) |
| mlx-swift | Export the bridge and point at the above | Draft [Layr-Labs/mlx-swift#33](https://github.com/Layr-Labs/mlx-swift/pull/33), on an older base; needs redoing on the current pin once the mlx and mlx-c changes are settled |
