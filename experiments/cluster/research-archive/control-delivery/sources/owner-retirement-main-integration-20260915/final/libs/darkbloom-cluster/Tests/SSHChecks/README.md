# Owner transport and retirement checks

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

The temporary test directory is owned by the runner and removed on exit. Any
nonempty journals in refusal tests are fabricated test artifacts, not production
recovery. Cleanup observations do not establish physical peer or model behavior.
