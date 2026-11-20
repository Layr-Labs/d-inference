# Native worker endpoint factoring

Ready: one new `ClusterWorkerEndpoint.swift` plus mechanical Pair/Request changes
on the frozen originating-deadline overlay. `ClusterWorkerProcess.swift` is byte
identical to the current public supervisor. Its conformance delegates to the same
send/receive, invalidation, fence and actual-exit methods; no pump, signal, callback,
resource or generation behavior is replaced.

Pair accepts two `[any ClusterWorkerEndpoint]` values. Existing arrays of direct
children remain accepted. The interface distinguishes `requestNativeCleanup`
from `nativeCleanupObserved` and both wait methods. A future SSH endpoint must
bind actual remote-owner native terminal evidence to its current membership,
rank, owner and lease. SSH exit/EOF, timeout, signal-sent and a request-only retired
event cannot satisfy native cleanup. No remote endpoint is implemented here.

All deadline values on this interface are in the caller's local clock domain.
A remote implementation must translate reserve generation/admission budgets to
remaining durations before forwarding, derive its own local deadlines, and keep
the origin's acceptance/cancellation authority. The endpoint lifetime property
retains the deadline overlay's minimum across ranks; separate TTFT admission caps
remain unchanged.

`mechanical-checks.json` records exact reversal to the frozen deadline Pair and
Request sources: only endpoint type/name substitutions and Pair's scope comment.
The required deadline package manifest is
`9711a629399b1c32c0227b6a1615bcfc6d0e75af2d3a8b67b8a147ac2837055e`.
Apply that overlay before this patch. Test support includes unchanged copies of
its provider owner/context sources; they are not additional runtime changes here.

Validation: `bash libs/darkbloom-cluster/Tests/ProcessChecks/run.sh` in `workspace`
passed in 25.311 seconds, Swift6 warnings-as-errors, empty stderr, all input pins
unchanged. It ran ten unchanged existing actual local-child groups, the unchanged
ProviderCore owner contract fixture against MLX value stand-ins, and two new
endpoint groups. There was no MLX/model/native inference, network or SSH execution.

The new fixture wraps an actual local child with a fabricated transport endpoint.
After simulated EOF and actual child exit it withholds owner proof: retirement
and resource release remain blocked/charged until proof is exposed. The other
case verifies the local lifetime minimum and that an expired admission cap neither
consumes the request ID nor invalidates ready workers. This is not a real remote
authentication or process-fencing test.

The public test runner gains the now-required `DistributedRequestDeadlineContext`
compiler input and the new endpoint fixture. Existing process/provider test bodies
and fake worker are unchanged.

Remaining: an installed SSH owner/service adapter, authenticated bootstrap channel,
durable remote ownership recovery and real two-host failure qualification. Startup
failure still requests cleanup before throwing, as the existing Pair does; a
remote endpoint factory must retain those owners and await/retain unresolved
native ownership independently of an unsuccessful Pair construction.

Root owns integration and further provider/native builds. No main repository files
were edited. Independent endpoint source review is pending at this freeze and may
be attached as a separate supplement.
