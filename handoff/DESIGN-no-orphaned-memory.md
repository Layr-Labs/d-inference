# No orphaned memory on any exit path (S00)

The owner's two-Mac tools saw 92-176 GB stay wired after a rank died without
its release, until the Mac was restarted. This slice gives every Darkbloom rank
one forced way out that releases first, refuses to start a rank over memory a
dead process left wired, sizes the owner's SIGTERM-to-SIGKILL grace to what the
rank holds, and records whether dense Qwen stages should hold a standing wired
limit. Sources: the owner's `run_with_watchdog.py` (ThunderMLX), oMLX
`sigterm-release` / `stability` (rank-exit claim, dead-man, size-aware stop
timeout, orphan guard), upstream `_release_metal_memory`, guard-032c.

## The one forced exit (`ProcessForcedExit`)

Every forced end of a worker goes through one once-only claim:

| Trigger | Status | Reason in the log |
|---|---|---|
| Lifetime deadline thread (`ProcessDeadline`) | 124 | `process-deadline` |
| Startup deadline (`WorkerStartupDeadline`) | 123 | `startup-deadline` |
| SIGTERM / SIGHUP / SIGINT (routed) | 143 / 129 / 130 | `signal-N` |
| Lifetime alarm (SIGALRM, routed) | 124 | `signal-14` |
| Input ended before shutdown, request or lifetime deadline seen by the reader | 1 | `lost-input`, `request-deadline`, `lifetime-deadline`, `worker-input` |
| Failure caught by the executor (a JACCL guard error among them) | 1 | `worker-failure` |
| Any other worker error | 1 | `worker-error` |
| Clean end after `shutdownComplete` | 0 | `shutdown-complete` |

The claim, in order: (1) arm a dead-man thread that `_exit`s with the claimed
status after 20 s and never writes, locks or allocates; (2) run the release:
`mlx_set_wired_limit(0)` first, then `mlx_clear_cache()`; (3) either exit at
once (deadline threads, signals) or let the executor unwind inside the dead-man
bound (cancel, release the model) and then `finish`. A later trigger either
does nothing or waits for the claimed exit; `finish` keeps the first claim's
status. Each step writes one `darkbloom-forced-exit-v1` line, which the pair
driver keeps in its reports.

The release calls mlx-c directly. mlx-swift's `Memory.clearCache()` takes the
process-wide `evalLock`, which an executor blocked in a collective holds, so it
would wait for the dead-man instead of releasing.

Signals: SIGTERM and SIGALRM always, SIGINT and SIGHUP unless the worker
inherited them ignored, are blocked in every thread and taken by one `sigwait`
thread. The pair driver's launch script ignores INT and HUP before it execs the
worker so that an interrupted driver cannot take a loaded worker down; that
ignore is kept. Before S00 the worker had no SIGTERM handling at all (it died
at once with no release), and its SIGALRM handler and both deadline threads
called `_exit` directly.

### Limits while the executor is inside a native collective

A release from another thread (deadline thread, signal thread, reader) while
the executor waits in a JACCL collective:

- shrinks MLX's residency set and returns cached buffers, through the
  allocator's own lock; it does not wait for the executor;
- does not tear down the JACCL group: its queue pairs and registered buffers
  belong to the polling thread, and end with the process (the guard's own
  teardown only runs when the guard fires first);
- does not free the model's arrays, which belong to the executor; the kernel
  reclaims them when the process ends;
- leaves resident a buffer that an already committed command buffer uses,
  until that command buffer or the process ends;
- waits, and is ended by the dead-man, if the allocator lock itself is held by
  a thread that never returns.

So a rank whose input is lost while its executor is blocked leaves at the
dead-man (20 s after the claim), before a 30-60 s collective guard, with its
queue pairs ended by the kernel at exit. The hardware runs below measure what
that leaves behind.

## Orphan-wired guard (`ClusterOrphanWiredGuard`)

At worker start (before anything is loaded) and at installed-owner start
(before anything is prepared): when no other Darkbloom process runs on the Mac
(this process and its ancestors excepted, zombies ignored), the Mac's wired
memory must not exceed its idle baseline, the larger of 16 GiB and a tenth of
physical memory (25.6 GiB on the 256 GiB Mac, 16 GiB on the 128 GiB Mac). The
refusal names the measured value and the baseline and says to restart the Mac.
Idle wired memory measured before 691 earlier pair launches: 6.6-14.6 GiB
(median 8.9) on the 256 GiB Mac, 4.6-9.9 GiB (median 5.2) on the 128 GiB Mac.
A probe that cannot read the counters skips the check (fail-open).

## Kill grace from planned bytes

`ClusterWorkerSignalPolicy.sized(plannedBytes:)`: SIGTERM to SIGKILL is the
bytes at 2 GiB/s, never under 30 s nor over 120 s (the flat 10 s it replaces
was measured too short for a ~90 GiB rank). The installed owner sizes it from
the artifact's total bytes, an upper bound for any stage; the remote endpoint
on the leader allows the largest margin. An owner still signals only after the
child's own deadline plus 5 s; the child's own forced exit (bounded at 20 s)
therefore ends a loaded rank before any SIGKILL.

## Should dense Qwen stages hold a standing wired limit? Not now.

Decision: dense Qwen stages keep no standing MLX wired limit between requests.

- The product holds one only for MiMo (`MiMoV26WiredResidency`); for dense
  models the provider passes no wired ticket, so this keeps product parity.
- Measured on the pair (9B, cut 4, 8,192/128, one-chunk lookahead, all four
  lanes held, one warm-up then three requests, off / on / off, medians of
  requests 2-4): first token 2.818 / 2.846 / 2.872 s, decode 65.3 / 64.7 /
  65.4 tok/s. No gain; the residency arm sits inside the spread of the two
  runs without it.
- Without a limit the stage is wired while in use anyway: on the 128 GiB Mac
  wired memory rose by 4.5-5 GiB at the first request and stayed there through
  all four requests, with no drop between them, with and without the limit.
- A standing limit keeps memory wired that macOS cannot reclaim between
  requests, and is the state that let the owner's unreleased exits strand
  memory (every exit path now resets it to zero first).

MiMo is a different case: about 161 GiB of sparse expert tensors under memory
pressure on a 256 GiB Mac, where residency per command buffer collapsed decode
to about 0.4 tok/s. Revisit for a dense stage that approaches its Mac's
recommended working set under pressure (the 27B's phase-split rank 1 on the
128 GiB Mac is the first candidate): pair-check `--stage-residency yes` (the
qualification switch `DARKBLOOM_CLUSTER_STAGE_RESIDENCY=stage_wired_residency_v1`)
measures it, and `ProcessStageResidency` already applies the product's ceiling
(never above the recommended working set, always leaving the larger of 16 GiB
and a tenth of physical memory unwired).

## Hardware evidence (2026-10-09, evidence/s00-20261009/hw)

Registered 9B at cut 4, rank 0 on the M3 Ultra (the listener), rank 1 on the
M5 Max, across the cable; an 8,192-token synthetic prompt, 128 outputs, serial
prefill, collective progress limit 30 s; wired memory and this build's worker
processes sampled every 0.5 s on both Macs. No run sent SIGKILL, no run left a
worker process, and on both Macs wired memory was within 1 GiB of its
pre-launch value at the first sample after the last worker exit (0.6 s at
most; idle 7.4 GiB and 5.1 GiB, 9.1-10.8 GiB while loaded and decoding).

| Run | Ended rank | Other rank |
|---|---|---|
| Clean, recorded (128 tokens, ranks agree) | both 0, `shutdown-complete` | |
| SIGTERM rank 1 mid-decode (48 tokens) | 143 in 0.03 s, released | `lost-input`, executor blocked in the collective, ended by the dead-man 20.5 s after the signal |
| SIGTERM rank 0 mid-decode (37 tokens) | 143 in 0.12 s | `lost-input`, dead-man at 20.5 s |
| SIGTERM rank 1 mid-prefill (0 tokens) | 143 in 0.19 s | `lost-input`, dead-man at 20.3 s |
| SIGTERM rank 0 mid-prefill (0 tokens) | 143 in 0.17 s | `lost-input`, unwound by itself 22 ms after the claim |
| Request deadline 5 s (80 tokens) | rank 0 `worker-failure`, rank 1 `request-deadline` | both 1, released |
| Lifetime 10 s, rank 1 started 25 s late | rank 0 124 from the deadline thread inside the JACCL bootstrap | rank 1 124 |
| Stage residency held, SIGTERM rank 1 mid-decode | 143 in 0.05 s, wired limit 5.34 GB reset to 0 | `lost-input`, dead-man |
| Timed, residency off / on / off (1+3 requests each) | all exit 0, `shutdown-complete` | |

Every worker start decided `clear` at the orphan-wired guard (7.4 GiB against
25.6 GiB, 5.1-5.6 GiB against 16 GiB). A rank whose executor was blocked in a
collective and was ended by the dead-man, with its queue pairs still posted,
returned its memory like every other exit: the owner's 160 GB case did not
reproduce here, before or after this change. Earlier Darkbloom SIGTERM runs on
this pair without any release (Gemma 4, GPT-OSS, MiMo stage and pair) also
returned their memory.
