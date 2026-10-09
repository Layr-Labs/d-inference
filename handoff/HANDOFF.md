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
| G1 Two-Mac qualification | **Blocked** | Both Macs inventoried. First two-rank run refused at JACCL initialization: Mac B's Thunderbolt port has no IPv4 address of its own | Mac B's port needs its own IPv4 address (administrator). Then rerun the transport check in both modes and record device evidence |
| G2 One real model on both ranks | **Blocked** on G1 and on the artifact | The only accepted model is registered Qwen3.5 9B 4-bit; neither Mac has it | Obtain the artifact; fix C1, C2, B1 at least; run against a single-host reference |
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

Nothing has been pushed. The clone's push URL is disabled on purpose.

## The two things only the owner can unblock

1. **Mac B's Thunderbolt port.** It is a member of the Thunderbolt Bridge and
   has no IPv4 address of its own, so its RDMA device publishes no IPv4-mapped
   GID and JACCL refuses it. Mac A's port has its own address and works. The
   change is a network setting on Mac B.
2. **The 9B artifact.** 6.11 GB, catalog version `2026-09-03-r1`. Needed on
   both Macs as the code stands (see B11 for sending a stage over the link).
   Approved 2026-10-08: being fetched from the model CDN on Mac A with
   per-file verification, then copied to Mac B over the existing SSH login.

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

The pinned forks need three small changes for a supported result. Each one
changes provider bytes, so each is a pin decision (D2 in the gap map).

| Fork | Change | State |
|---|---|---|
| mlx | Clear the tail of partially filled JACCL send frames | Research commit `4e89c2e3` (+71/−58), one commit off the research pin; being carried onto the current pin |
| mlx | Bound every JACCL polling loop, check completion status, release and report on timeout | New, modelled on the ThunderMLX progress-timeout patch |
| mlx-c | JACCL bootstrap callback bridge | Research commit `489e965` (+192), directly on the pinned `02cf6f4` |
| mlx-swift | Point at the above and export the bridge | After the decisions above |
