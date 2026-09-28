# Owner transport, retirement and diagnostic checks

Run from the repository root:

```sh
bash libs/darkbloom-cluster/Tests/SSHChecks/run.sh
```

The runner compiles the actual Foundation-only Protocol, Process, Bootstrap and
Remote sources with Swift 6 warnings as errors, using at most two compiler jobs.
It launches local CPU stand-in owners/workers over pipes and local Unix sockets.
It performs no SSH, network-peer, model, MLX or GPU execution.

The existing thirteen groups remain, followed by six retirement/shutdown cases:

- Both ranks complete a two-token request and emit clean retirement followed by
  unavailable, matching a worker that exhausts its single allowed request. A
  valid shutdown delayed until after actual native-child termination must leave
  the explicit release handshake usable. Both owners exit zero and clear their
  own journal only after release; no shutdownComplete event is synthesized.
- An active request, duplicate shutdown and replayed owner sequence are refused
  without an authenticated release or journal clearance.
- Valid late shutdown followed by EOF retains the journal if explicit release
  never arrives.

Five additional diagnostic groups use the actual owner service and local child
processes:

- A file gate delays owner stderr until after the endpoint observes native
  cleanup and the authenticated release ACK. The final bytes and actual pipe EOF
  must be available before the owner-ended barrier completes.
- An owner exiting nonzero retains its diagnostic but cannot report a clean
  transport release.
- A post-ACK hung owner is fenced within the existing two-second exit grace.
- A test-owned writer retained after actual child exit prevents diagnostic EOF
  until the final writer closes; the drain remains bounded.
- Oversized stderr is refused under the existing 1 MiB capture cap.

`OWNER_DIAGNOSTIC_DRAIN` selects all five assertions in the retained fixture;
the archived pre-fix baseline branch is not run. Diagnostic completeness,
native cleanup, authenticated lease release and transport exit are independent
observations. No private qualification controller is compiled by this runner.

The temporary test directory is owned by the runner and removed on exit. Any
nonempty journals in refusal tests are fabricated test artifacts, not production
recovery. Cleanup observations do not establish physical peer or model behavior.
