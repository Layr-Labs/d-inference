# Owner transport, retirement and diagnostic checks

Run from the repository root:

```sh
bash libs/darkbloom-cluster/Tests/SSHChecks/run.sh
```

The runner compiles the actual Foundation-only Protocol, Process, Bootstrap and
Remote sources with Swift 6 warnings as errors, using at most two compiler jobs.
It launches local CPU stand-in owners/workers over pipes and local Unix sockets.
It performs no SSH, network-peer, model, MLX or GPU execution.

Nineteen owner groups run first. One of them runs three hundred complete
sessions, each with its owner started from a dispatch thread as the product
starts it, and requires the endpoint to report the owner's exit in every one.
Taking that exit from `Process.waitUntilExit()` lost it in roughly one such
session in sixty, so a single session cannot show the fault. The last five
cover how an owner ends its child and what it leaves behind:

- The device journal is written immediately before the child is launched. A
  factory refusal, a child that cannot be run, and a hello that nobody reads
  each leave no journal.
- A reader error on the leader's side does not end a local owner that is still
  waiting for its child. The owner fences the child by closing its command
  stream, waits the three seconds the stand-in needs, clears its own journal
  and exits by itself.
- A child that ignores its stream lives to its lifetime and is signalled only
  after it. The owner keeps serving the terminal and the release handshake past
  the lifetime.
- An owner starts its lifetime when it reads the open, after its own
  preparation. The endpoint's patience follows that later clock, bounded by the
  hello's arrival: an owner that prepared for a second and a half and then
  retired a child that ignored its stream is neither abandoned nor signalled,
  and its terminal, release and cleared journal still arrive.
- Explicit recovery clears a journal whose owner is gone, and refuses while a
  process holds the device scope, while a running process carries the recorded
  membership epoch, or when the journal is not a record this build wrote.

An owner signals its child only after the child's own hard deadline plus a
margin; `ProcessChecks/RetirementPolicyTests.swift` checks that order directly.

Six retirement/shutdown cases follow:

- Both ranks complete a two-token request and emit clean retirement followed by
  unavailable, matching a worker that exhausts its single allowed request. A
  valid shutdown delayed until after actual native-child termination must leave
  the explicit release handshake usable. Both owners exit zero and clear their
  own journal on release; no shutdownComplete event is synthesized.
- An active request, duplicate shutdown and replayed owner sequence are refused:
  no release acknowledgement is sent and the owner exits nonzero.
- Valid late shutdown followed by EOF gets no release acknowledgement either.

In the refused and EOF cases the journal is still cleared, by the owner itself,
once it has observed its own child's exit. The journal records that a native
child may be running; a lost handshake is reported by the owner's exit status
and the missing acknowledgement, not by a journal nobody can clear.

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

The temporary test directory is owned by the runner and removed on exit.
Cleanup observations do not establish physical peer or model behavior.
