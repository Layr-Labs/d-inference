# Native resident worker (private staging)

The five Swift sources implement an actual executable over the frozen
`DarkbloomClusterProtocol` and the compiled `QwenResidentRuntime` facade.
`NativeWorkerRuntime` calls the real load/reserve/start/cancel/shutdown methods;
it is not a fake worker or benchmark Main. No main repository files were edited.
The separate build workspace contains the unchanged 87 facade/protocol sources
plus these five worker files. `Package.swift.proposed` adds only an executable
product/target and its focused test target to the frozen facade manifest.

Normal ProviderCore must depend only on the pure Protocol/Process targets. The
native runtime and worker are separate products; do not raise the normal
provider's macOS 14 baseline or link this native owner into its default route.
Root owns the main package manifest and will merge these target additions later.

## Launch and lifecycle

The executable accepts exactly these twelve flag/value pairs, with no shell or
bootstrap JSON format:

```
--model-dir ABSOLUTE_PATH
--rank 0|1
--stage-cut 12|16
--membership-epoch LOWERCASE_UUID
--model-id registered_qwen35_9b
--artifact-sha256 LOWERCASE_SHA256
--configuration-sha256 LOWERCASE_SHA256
--peer0-id LABEL
--peer0-build-sha256 LOWERCASE_SHA256
--peer1-id LABEL
--peer1-build-sha256 LOWERCASE_SHA256
--deadline-uptime-nanoseconds LOCAL_ABSOLUTE_UPTIME
```

Pass the explicit arithmetic and JACCL environment already admitted by the
facade. Identity/build strings remain supplied bindings, not executable or
hardware attestation. Peer order is common across ranks; local rank and device
file path may differ. Deadline is on this Mac's uptime clock and no more than
300 seconds away. Remote endpoint supervisors must derive local deadlines; do
not forward another Mac's uptime value.

The main process thread is the sole native executor. It loads once, then emits
ready only after the facade completes actual source/inventory/resource admission
and bilateral loaded agreement. Input already buffered immediately before ready publication is refused. A separate
POSIX poll/read thread validates protocol epoch, sequence, UUID and command state;
it can signal cancellation while native work runs and deliver per-token decisions.
Already-read command batches are validated before waking the native executor.

Reserve retains metadata and performs actual native resource admission; start
is separate. Rank 0 emits each committed token and waits for the matching token
decision before the driver may continue. Rank 1 publishes no synthetic token
replay. Only an actual clean facade result permits finished and retired(clean).
The facade has already retired both request states and exited its request scope
before that result. The protocol retired event is still local evidence for the
outer two-worker owner, not a substitute for its own retirement/fence logic.

Shutdown is accepted only after request retirement, releases the local model,
then publishes shutdownComplete. Unexpected EOF, malformed/replayed commands,
output failure, cancellation or request failure aborts the worker. It attempts
local release, emits failed only when the pipe/protocol still permits that
record, and exits nonzero without manufacturing a retirement event. The outer
owner must keep its provider lease until both workers are retired or fenced.

A fixed SIGALRM is installed before MLX initialization. It is never reset, and
its handler only exits(124), without claiming cleanup. Request deadlines are
also checked while waiting for control and during partial output writes. Native
collectives may block until the hard process alarm; parent lifetime/deadline and
process-group fencing remain required. There is no control reader during initial
load; the outer deadline/fence covers cancellation at that stage. Event writes
hold the protocol lock, so the control reader can also wait behind a backpressured
write until its request/lifetime bound. The parent's independent fence must remain
available. SIGTERM/SIGINT use process termination, not a pretend clean retirement.

Input uses bounded Darwin.read/poll, not a fill-seeking FileHandle pipe read.
The frozen per-record bounds remain 512 KiB commands and 16 KiB events. Additional
worker totals are 32 MiB input and 8 MiB output, within the facade's 16-request
lifetime. Output is nonblocking with bounded polling; failed publication does
not commit event sequence/state or authorize a new request.

## Build distinction

The actual executable typechecked and linked on macOS 14, and eight focused
fake-owner/real-local-pipe tests passed (0.877 seconds; total build/test106.230s).
This linked binary is a TYPECHECK artifact with the JACCL stub. It was not run
against a model, GPU or another process. A subsequent narrow cleanup correction
tracks successful model release so a failed shutdownComplete write cannot call
the non-idempotent native shutdown again. Retry2 compiled that correction and
all nine focused tests passed in9.112s total; the first tested source is retained. Tests exercise both rank event paths,
clean stop before another token, token-credit cancellation, deadline while
waiting for a decision, failed publication preventing start, unexpected EOF,
CLI bounds, and a buffered start plus premature token decision.

`build-native-worker.sh` is the exact ROOT-OWNED native build entry, based on the
existing experimental build's explicit Swift and C++ deployment targets:

```sh
./build-native-worker.sh ASSEMBLED_PACKAGE MATCHED_METALLIB METALLIB_SHA256
```

It uses a separate `.build-native-worker` scratch directory, release/jobs2,
`--triple arm64-apple-macosx26.2 -Xcc -target -Xcc arm64-apple-macosx26.2`, checks
for the real JACCLGroup symbol, and copies only the explicitly supplied/pinned
source-matched metallib next to the worker. It does not run the worker or package
or deploy a release. No Python dependency bootstrap or TCP-ring manifest overlay
is needed for this JACCL-only worker. The provider's pure targets keep their
normal build. A matching file hash/symbol is not proof of loaded-library identity
or physical correctness; those remain root's actual execution checks.

The script passed bash syntax only and has not been executed. The root must
choose the actual matched metallib from its pinned build. This package does not
claim successful model loading, physical RDMA, numerical parity or external TTFT.
