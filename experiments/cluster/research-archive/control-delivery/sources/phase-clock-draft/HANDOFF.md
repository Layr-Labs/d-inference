# Optional local CPU phase markers

This is a source-only additive draft. Two core files target
`Sources/ClusterInference/Tracing/`; `owner-hooks.patch` changes only the long-rank
Trace/Request and long-solo Request owners. Full proposed owner files and original
pins are retained for review. No existing source, CLI, numerical/transport code
or JSON result schema was changed by this agent.

`QwenPrefillPhaseRecorder` is optional and caller-owned. Its immutable identity
contains `requestFingerprint`, `profile` and `role` (`rank0`, `rank1`, `solo`).
For these hooks, **requestFingerprint means the recorded request/history
fingerprint**, including the admitted prompt: `local.request.fingerprint` or
`admission.request.fingerprint`. It is not the geometry-only fingerprint.
The utility checks identity spelling/equality and lifecycle; it does not admit
a model, a profile's request geometry, arithmetic or a transport.

Production construction stores a closure that reads
`DispatchTime.now().uptimeNanoseconds`. Only `observe` invokes it. A separate
`testClock:` initializer visibly labels resulting traces `injected_test_clock`.
Construction, `begin`, `seal`, `fail` and `successfulTrace` do not read time.
The capacity is caller-selected from 1…1024 events, default 512. Each event has
an ordinal, a bounded ASCII phase name, optional frame sequence, committed-token
frontier and UInt64 timestamp. Metadata bounds (frame below 128, frontier at most
32768) are storage limits, not a widening of any existing request admission.
Timestamps and committed frontiers cannot decrease; equal timestamps are valid.
Frame sequence may return to the previous frame while draining its consumed ACK
after a lookahead preparation.

Lifecycle is fresh → active → sealed, with any invalid operation or callback
error leading to failed. Begin checks the exact expected identity. Nonempty seal
is one-shot, and no partial trace is publicly available. Failure discards internal
partial/sealed observations and is nonthrowing/idempotent. A recursive lock and a
clock-read guard reject reentrant operations. Even if an injected clock catches
its own nested error, the outer observation sees the failed state and cannot
publish another event. Original clock errors are rethrown unchanged.

The returned trace contains copied CPU values only, never a callback, model,
native array, payload or state bytes. It explicitly says the recorder does not
independently verify request retirement or assert model release, cross-process
clock alignment or GPU overlap. Spans include recorder/lock/metadata overhead.
The full marker span includes phases outside the existing origin timing window;
it is not itself a throughput interval.

## Request hooks and publication

Both Request signatures add the defaulted `phaseRecorder` parameter **after**
`onReady`. Existing calls remain valid. Identity construction is inside an
`if let phaseRecorder` branch. Remaining observer calls use optional chaining.
With nil there are no additional recorder/event collection allocations or clock
reads. The rank Trace object gains a stored optional reference, and hook branches
remain: byte-for-byte heap layout, allocation or timing invariance is not claimed.

Rank Trace forwards each existing scalar action immediately after appending it.
It therefore yields 204/235 local events for the existing sender/receiver traces,
covering preparation, payload/control sends and receives, received/consumed
acknowledgements, actual consumption and post-stop closure. No native operation
or acknowledgement is moved, and no GPU synchronization or copy is added.

Solo adds 41 markers: three setup markers, 16 `prefill.begin` / `prefill.committed`
pairs, then six selection/diagnostics/retirement markers. The existing primary
start remains immediately before fresh CBv2 construction. The existing stop
remains immediately after finite argmax returns. `selection.completed` is placed
after that stop and its guard, so its timestamp includes those CPU instructions;
it is not an exact GPU-selection completion timestamp. `request.closed` follows
the existing closed-time read/guard. The numerical calls, finite selection,
final captures and native close/cancel order are unchanged.

Each owner seals only **after construction of its final successful CPU result,
verified clean request retirement and native error checks**. It never seals after
initial fresh-session construction. Observer failures enter the existing owner
catch; the recorder is failed first, then original transport/request cleanup and
primary-error handling continue. A late observer/seal failure after already-clean
retirement preserves the existing rule against cancelling that closed request.
`fail` cannot interrupt a blocked native operation; external cohort deadlines and
peer fencing remain necessary.

Request success is narrower than outer model-owner success. The present patch
does not change Check/Main or publish an extra JSON record. Future outer plumbing
must use the following pattern and never expose a sealed request trace early:

```swift
do {
    let existingReport = try runOuterCheckForwardingRecorder(recorder)
    // Outer model release, cache clear and error checks have succeeded.
    let phaseTrace = try recorder?.successfulTrace()
    // Publish existingReport and optional phaseTrace under the outer contract.
} catch {
    recorder?.fail()  // Also invalidates a request seal after later outer failure.
    throw error
}
```

The above function name is pseudocode, not a new API. No pointer to the recorder
or partial trace should escape an outer failure path. Successful Trace access is
CPU-only but does not itself prove that the outer caller respected this rule.

## Checks and root-only integration

`check_sources.py` verifies original owner pins, exact patch reconstruction,
unchanged native/primary-clock source lines, source order and nil-call forms. It
rejects six deliberately malformed seal/fail/clock mutations. Those are source
checks, not execution proof. Its receipt is `source-check-20260914.json`.

`QwenPrefillPhaseRecorderCheck.swift` and `FoundationHarness.swift` are unexecuted
pure Foundation fixtures. The source-derived expected result is six accepted and
47 rejected fixtures. Cases include skipped nil argument evaluation, capacity,
wrong identity/profile/role, partial-read rejection, timestamp ties/reversal,
UInt64 maximum, exact clock-error preservation, caught reentrant invalidation,
repeat seal, explicit failure and outer failure after seal. Only injected test
clocks are exercised. Root may compile/run these four files outside the inference
target:

```sh
swiftc Tracing/QwenPrefillPhaseTypes.swift Tracing/QwenPrefillPhaseRecorder.swift \
  QwenPrefillPhaseRecorderCheck.swift FoundationHarness.swift -o phase-clock-check
./phase-clock-check
```

No Swift compiler, fixture, native inference, GPU, model payload, transport or SSH
was run by this agent. Root owns compilation, integration and later qualification.
Independent source review by `pipeline_stage_plan` found no concrete lifecycle,
CPU ownership or hook-order blocker; it specifically called out the optional
field/layout caveat and the need for outer failure fencing/publication.
