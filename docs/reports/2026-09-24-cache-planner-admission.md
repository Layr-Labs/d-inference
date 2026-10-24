# Cache planning admission: reproduced opportunity loss

> Last updated: 2026-09-25

## Status and scope

Initial diagnosis plus the implemented client-admission repair described below.
The baseline is d-inference `b6f9574ed40a5e1f8b8fb288224ea3de88d1be98`.
The observed defaults are not a measurement of fleet configuration.
No model weights, quantization, attention math or SDK pins change.

## Connection-budget follow-up

Independent review reproduced a nondefault configuration failure with 64 workers
and 64 server connections: planning occupied all connections, and new health
and control connections failed. Rust's connection permit lasts through HTTP
keep-alive idle time, so separate client pools alone were insufficient.

The follow-up caps active and idle planning connections at the minimum of worker
capacity, the existing 64-call admission bound, and total server connections
minus four reserved control connections (two health, two preload/control).
The default remains four planning workers and 64 server connections. No worker,
memory, queue-byte or request-deadline limit is increased. Enabled supervisor
configurations with fewer than five total connections are rejected; a directly
constructed client with that invalid budget refuses planning without dialing.

The unchanged review regression fails at `94a1d6d78` and passes with the repair.
The full repaired `promptcontract` race suite passes 54 top-level tests / 259
named events, with one explicit real-sidecar opt-in skip. Added cases cover
5/8/64-connection saturation, fresh and repeated health/control reconnects,
configuration bounds, unchanged server worker limits and admission refunds.
These are actual Go HTTP clients against a synthetic Unix listener mirroring
the Rust lifetime connection semaphore, not execution of a new Rust binary.
Earlier sidecar/native experiments below remain historical evidence; they do
not qualify this follow-up candidate or establish fleet cache-hit improvement.

## Finding

The Go planning client in `coordinator/promptcontract/client.go` permits
16 simultaneous planning connections. The sidecar defaults to four workers
(`supervisor_defaults.go`) and rejects excess work immediately
(`coordinator/promptsidecar/src/planner.rs`). The registry admission bucket can
admit an initial burst of 40. Planning refusal falls back to ordinary dispatch:
inference can succeed without a cache lookup or donor-planning opportunity.

The initial tests exposed the default mismatch and used the actual registry gate
at synthetic 20/40/80/160 request-per-second arrival rates. They are diagnostic
witnesses, not assertions that the mismatch should remain after a fix.

## Controlled experiment already completed

An unchanged optimized sidecar and Go client processed synthetic 40-request
bursts using two verified published contracts: Bonsai and native Qwen4.
Each arm included three prompt lengths (5,633, 44,833 and 64,033 tokens),
three repetitions and both contracts: 18 bursts, 720 requests.

| Configuration | Planned/admitted | Successful total p95 | Largest total | Observed sidecar RSS |
|---|---:|---:|---:|---:|
| Current four workers, current client | 72/720 | 86.6 ms | 89.3 ms | 576.1 MiB |
| Four workers, caller-side bounded-wait prototype | 720/720 | 497.2 ms | 600.4 ms | 726.3 MiB |
| Sixteen workers, current client | 720/720 | 228.3 ms | 275.3 ms | 965.6 MiB |

Successful plans preserved every reference token count and prefix boundary;
no timeout or restart occurred. Baseline latency excludes the 648 refusals and
therefore must not be interpreted as better overall service.

A second prototype placed bounded waiting **after actual registry admission**
using a local Unix proxy. Both arms admitted 720 requests; direct planning
completed 72, bounded planning completed 720. Bounded p95 total latency was
478.8 ms, maximum 540.5 ms and sampled sidecar RSS 706.1 MiB, preserving the
one-second request context and exact successful plans.

Retained post-admission result SHA-256:
`d84a093240710350d1fa1c0021271ca8c270c98a7b44591b26badbd20546dfc8`.
This hash identifies retained evidence; it is not a substitute for the full
experiment harness, which is not shipped in this change. The portable tests
here reproduce defaults/admission only, not this benchmark.

Lifecycle controls preserved 40 admitted / 56 throttled from a mixed 96-request
burst; direct planning completed 10, bounded planning 40. Cancelled queued
requests did not later reach the backend, fully expired queues forwarded none,
and health plus post-drain recovery passed. The first proxy had an unread-body
cancellation bug; the test harness was corrected with bounded buffering.
Normal controls passed. A race-instrumented run initially failed a 200 ms
queue-entry precondition; its separately labelled 600 ms fixture passed without
race findings. That does not replace the normal 200 ms result or change the
one-second product deadline.

## Repair implemented after the diagnosis

The client now matches normalized supervisor worker capacity (four by default)
and bounds active/waiting calls at 64 plus 64 MiB of accounted input/envelope
bytes. Waiting precedes serialization; the original request deadline includes
all work. Health/control pools, rollout sampling/QPS, successful plan contents,
sidecar worker/memory limits and ordinary cold fallback remain unchanged.

The actual repaired client and unchanged release Rust sidecar completed all
720 requests across the six contract/length cells, with exact warm-reference
prefix vectors, zero overloads/timeouts and zero restarts. Successful total p95
was 623.745 ms and maximum 744.237 ms. This run overlapped local compilation;
it is deadline/correctness evidence, not a clean timing comparison to the earlier
prototype or a deployment CPU/memory qualification.

The real-sidecar fixture initially failed because a symlinked temporary parent
was correctly refused, then because its synthetic body omitted the required
model field. Both fixture defects were corrected without weakening production
validation. Normal and race client/registry tests pass; full API and native
end-to-end checks remain separately recorded during implementation qualification.

## Design constraints retained

The repair aligns normalized capacity and bounds waiting before serialization,
instead of retaining an encoded body for every HTTP connection waiter. It keeps
separate health/control pools, the original deadline, exact scope/prompt identity
and fail-cold semantics. This placement is tested independently of the earlier
proxy prototype.

Do not blindly raise workers to 16: the two-contract experiment approached the
1 GiB sidecar limit; the configuration permits eight contracts. Waiting before
the client call is not equivalent to waiting after serialization/admission.

The pinned Go run also passes an additional 40-request mixed-length/model/scope
burst, queued cancellation, active-backend drain, health/control isolation and
post-drain recovery. Every mixed plan matches its own scope-bound reference.
Deployment CPU/memory and sustained tenant-fairness measurement remain distinct
from these bounded local burst tests; no fairness scheduler was added.

## Interpretation limits

These are planning-completion results, **not SSD hits or a demonstrated
44–48% fleet hit rate**. Mac CPU bursts and 100 ms RSS samples are not Linux
deployment qualification or kernel peaks. The reported roughly 5% fleet figure
still needs a specific numerator, denominator, model and time window.

Count planning eligibility, completed plans, accepted routing receipts,
request-level adoption and reused-token share separately. Missing API usage
after a cancelled stream is unknown, not a zero-cache-hit measurement.

## Reproduce portable witnesses

From the coordinator directory:

```bash
GOTOOLCHAIN=go1.25.0 go test ./promptcontract ./registry -count=1
GOTOOLCHAIN=go1.25.0 go test -race ./promptcontract ./registry -count=1
```

No model, GPU, coordinator database or real credentials are needed.
See [test commands](../developer/test.md) for component validation.

Review staging validation: the complete Go `promptcontract` and `registry`
package tests pass; focused diagnostic cases also pass with the race detector.
At 80 and 160 synthetic arrivals/second the gate admits 2,439 requests in each
60-second window, versus 4,800 and 9,600 arrivals respectively. These are
eligibility ceilings, not cache-hit rates. Documentation and diff checks pass.

The full coordinator `go test ./...` suite passes under pinned Go 1.25.0
(237.432 s), with external Postgres/APNs and other explicit opt-ins reported as
skips. The real sidecar opt-in is run separately: 720 homogeneous plus 40 mixed
plans pass, no skip. The complete client/registry race run passes (25.557 s).
The pinned homogeneous run records total p95 669.069 ms and maximum 798.932 ms;
these remain bounded local qualification timings, not fleet performance claims.
The installed Go 1.27.1 instead fails four JSON escaping/length tests identically
on unchanged upstream; the same cases pass on 1.25.0. No JSON behavior was changed
to hide this toolchain mismatch.

Full-suite log SHA-256: `15636005c4bf360f806d969c9c97486a21467ea672068be6d602b7e495a885dd`.
Race log SHA-256: `a568bacc2e3d54dfc2690b5aaecf7c7ba28a56c1be6678c3e74b7443db5c412e`.
Real-sidecar log SHA-256: `483a5bdc9acafbbc06dacc69242461f843f3b657c923533ea176e7230e9323a9`.
Composed native coordinator/provider tests also pass three eviction-pressure
cases and the ten-case cache-OFF/SSD-ON matrices. Native output/tool equality,
tenant separation, actual cache adoption, image input, cancellation and cold
fallback remain intact. These use ephemeral keys and mock trust, not a hosted
provider route or release-signed persistence.

The Linux/amd64 coordinator cross-build also passes with pinned Go 1.25.0 and
CGO disabled (11.490 s). This establishes build compatibility, not measured
Linux/container resource behavior. Build log SHA-256:
`f9c2439b5b21f2f9b76ab1bcc70b04e5501b2d472b03bea0257d1fee5e402930`.
