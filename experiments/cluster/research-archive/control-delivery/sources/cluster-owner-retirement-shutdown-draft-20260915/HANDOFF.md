# Preserve owner release after an exhausted worker retires

The actual MTP probe completed its two-token request and reported native cleanup,
but neither owner acknowledged device-lease release. Both canonical journals
remained nonempty. This package preserves that failed physical result and fixes a
reproduced owner shutdown race; it does not recover those journals.

The only runtime delta is `ClusterWorkerOwnerService.swift`, base SHA
`67a597484dc15c1c9733e74efc8bc5ab449ff12730ce869058f907ef0150f7ae`,
proposed SHA
`b23e811ae3c80de443c1e2c29c43c89c6283cefa74af68a431d1c5a9fc58120b`.
`runtime.patch` and `integration.json` identify the exact MAIN destination. MAIN
and the old physical/native packages are unchanged.

## Cause and scope

The private MTP wrapper requires readiness to become nil after its one successful
request. The shared WorkerCoordinator then emits `finished`, `retired(clean)`,
and `unavailable(runtimeError)`. The owner reacts to unavailable by quarantining
and fencing its child. Meanwhile, the controller sends shutdown after retirement.
A shutdown already in transit can therefore arrive after native fencing or even
after the actual terminal observation. The former service attempted an ordinary
native shutdown, threw, and left its explicit release-reading loop.

The failed run did not record the precise wire interleaving. The CPU reproduction
deliberately delays that valid shutdown until after the service's actual native
terminal. It reproduced both missing acknowledgments and sticky journals, with
the owner's explicit error `Shutdown requires no outstanding request resources`.
The baseline service is byte-identical to the MTP package's pinned service. This
establishes a concrete failure path consistent with the physical outcome; it does
not invent a retrospective packet trace.

The correction first retains every existing route, sequence, WorkerSession,
request-phase and delivery check. When a valid shutdown reaches an owner that is
already fencing or has observed native terminal, it consumes that shutdown as a
drain request without forwarding into the unavailable child. It emits no synthetic
shutdownComplete, native terminal or release acknowledgment. The owner continues
to require actual native cleanup, released request charge, successful terminal
publication, and the current connection's explicit release before clearing its
own journal. Active-request, duplicate and replayed shutdowns still fail.

No native model code, wire format, timeout, resource limit, admission count,
selection policy, journal-resolution guard or automatic recovery changes.

## Retained verification

- `checks-baseline-1`: build-runner refusal caused by Bash3.2 empty-array expansion
  under `set -u`; no tests ran. `corrections/runner-bash3.2` retains exact old bytes.
- `checks-baseline-2`: Foundation build passed in4.605s. The intended two-rank
  regression failed in1.590s: both actual request/native retirements observed,
  no release ACK, sticky308/309-byte test journals, owners exited nonzero.
- `checks-proposed-1`: unchanged proposed source built in4.611s. Six actual
  owner/child cases passed in4.124s: two late-shutdown ranks release and exit0,
  active/duplicate/replay shutdowns fail, and missing explicit release retains the
  journal. No shutdownComplete was synthesized. The existing13 SSH control groups
  passed in9.717s. Build and test stderr are empty; expected child refusal stderr is
  retained inside each test-owned directory.

Baseline and corrected new cases use eight actual owner/worker pairs in total.
They launch local CPU fixtures only, with ordinary production Foundation
Service/Process/Protocol/Remote code. They use no SSH connection, model, MLX/native
worker, remote machine, real canonical journal or credentials. All reported owner
processes exited; actual child termination is supplied by the production process
owner. Source hashes were checked before and after each run.

Reproduction uses `python3 -B run_checks.py baseline NEW_NUMBER` (expected exit1)
or `python3 -B run_checks.py proposed NEW_NUMBER` (expected exit0). The runner
retains all outputs and compiles only Foundation modules with jobs2.

## Integration still required

Root reviews and applies the one-file change, then rebuilds a coherent portable
owner/controller and its four Foundation modules for physical verification.
Do not mix this test build's dylibs into the old MTP bundle. The existing9B MTP and
27B native binaries can remain byte-identical. Actual failed journals require a
separate, explicitly reviewed administrative recovery; this patch does not make
the old physical run pass. A fresh epoch and actual two-host release-ACK check are
still required before claiming the physical lifecycle repaired.

Arithmetic's independent narrow source pass found no concrete blocker; its
separate pin-bound supplement is pending at this package freeze.
