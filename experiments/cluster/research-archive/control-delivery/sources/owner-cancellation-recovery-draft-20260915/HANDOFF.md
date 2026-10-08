# Owner cancellation and fresh-epoch recovery

This private Foundation controller exercises one selected cancellation, then one
8192/512/128 request on a new Pair and membership epoch. It uses the existing
Protocol, Process, Bootstrap and Remote APIs unchanged. No main source changed.

`owner-cancellation-controller CONFIG.json` accepts the closed
`darkbloom_owner_cancellation_recovery_v1` schema in `CancellationSettings.swift`.
Use the qualified ready template and the existing two installed owner endpoints;
carry the same pinned prompt and 128-token expected sequence. Supply distinct
canonical `cancellationEpoch` and `recoveryEpoch`, fresh for this invocation.
Required peer fields are the existing host/user/port, pinned known-host file,
identity-key path and installed owner path. No raw shell command or PID is accepted.
`configuration-lineage.json` maps the qualified wakeup-lookahead controller/owner
inputs to this smaller schema. Each installed owner's template has a zero epoch;
its existing BindingFactory substitutes each authenticated open epoch and new lease
incarnation. The same installed owner therefore supports both fresh epochs without
changing configuration between cancellation and recovery.

- `startedBeforeFirstToken`: issue `start`, wait the declared 100–5000 ms delay,
  and call cancel only as a qualifying case when zero tokens have been observed.
  A first token before the delay fails the case and triggers cleanup. This proves
  a controller event interval; it does not identify an active GPU prefill kernel
  or prove when the native worker received `start` on physical hardware.
- `afterFirstDecode`: call cancel synchronously on the second selected token
  (ordinal 1). The actual Request checks cancellation before sending another token
  decision. Callback `false`/clean-stop is deliberately not used for this test.

Both paths require cancellation while the request is unretired, Pair readiness
withdrawal, no clean-finish callback, and charge retention when release is attempted
before proof. Release occurs only after the actual `waitUntilRetired` completes.
That proof can be worker retirement or owned native cleanup; it is not elapsed time.
The controller then shuts the Pair down and separately waits for both authenticated
owner lease-release ACKs. Only afterward can it create the new Pair/epoch.
Recovery requires the exact 128-token sequence, `length`, retirement, zero remaining
request charge, both native-cleanup observations and both lease-release ACKs.

There is no claim that the cancelled epoch can be reused. The recovery is a reload
and fresh membership, not restoration of the old request. The controller leaves
independent remote-journal inspection false; root must retain the normal postflight
journal/process observations and resource samples before claiming physical success.
The observed ACK is distinct from a separate filesystem journal sample.

## Bounds and failure behavior

One overall local lifetime is at most 300 seconds and is never reset for recovery.
Startup is at most 90 seconds, each request at most 120 seconds, and bootstrap at
most 30 seconds, all clamped to the remaining overall lifetime. Each endpoint's
existing owner/native deadlines and cleanup machinery remain active. A controller
watchdog requests cleanup at the lifetime; a self-exit at lifetime + 5 seconds
bounds a stuck controller. Self-exit/SSH EOF never establishes native cleanup.
Missing terminal proof keeps the owner journal unresolved and prevents recovery.
Root should keep the independent outer 315-second process supervisor.

Any failed phase/sequence/identity, missed owner ACK, or publication failure stops
the invocation. Partial request observations are emitted when available; no retry,
performance aggregate or capacity update occurs. The normal native resource gates,
6 GiB free-memory floor and allocator policy are not changed here.

## CPU checks and source lineage

`build.sh NEW_DIRECTORY` builds four Foundation-only modules from exact retained
main-source copies, then the controller, local fake worker and check executable.
Run `NEW_DIRECTORY/cancellation-check NEW_DIRECTORY/fake-worker NEW_CHECK_DIRECTORY`.
Root may reuse `build-2`; no native/MLX compiler is involved. The controller itself
was compiled but not run against SSH in this task.
`artifacts.json` lists the five controller deployment files. All four dylibs and
their 32 module sources are byte-identical to the qualified wakeup owner bundle;
only the controller executable is new. Existing owner binary `7d7867…` and native
`009a671d…` are external retained inputs, not rebuilt or executed by this task.

Nine groups pass with 24 actual local children. Child-side logs prove start then
active cancel at zero tokens or two selected tokens. The fake emits failed and
exits on cancellation, never an invented abnormal retired event. Checks cover
early charge retention, delayed/missing lease ACK, fast first-token phase failure,
wrong recovery sequence, stale epoch, publication failure, and no-op cancel after
an already retired request. All child exits were observed through the real Process
API. Fixture lease ACKs are explicit CPU stand-ins, not authenticated network proof.

`source-inputs.json` binds 32 unchanged main module files plus the reused bounded
input reader. `records/cpu-receipt.json` binds final sources, build/test receipts and
all 24 child logs. Initial check failure and pre-fix timer sources are retained:
an inherited MainActor timer closure trapped on the global queue; explicit
`@Sendable` callback types corrected it. The final build and tests have empty stderr.

## Root physical sequence

Run one case per invocation with current qualified native/configuration/resource
pins and fresh epochs. Retain controller JSONL, owner/native streams, resource
samples, authenticated cleanup/lease ACKs, and postflight empty journals/processes.
Before-first and after-first-decode are separate cases. If cleanup/ACK remains
unresolved, do not launch recovery or relabel the case successful. The expected
sequence guard is useful restart evidence; no fresh full numerical comparison,
external HTTP TTFT, sustained performance or product recovery claim is made here.
