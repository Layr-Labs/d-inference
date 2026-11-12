# Local owner bootstrap attachment

This private overlay implements the local channel between a direct native child and its Darkbloom owner. It depends on the frozen `jaccl-owner-bootstrap-draft` manifest `327e8acc417e508c907ecb11fae546c0a1d1f4046117397de8ffa9d943c7fffe`. It supplies the actual facade/worker hook for that callback. The authenticated cross-host relay remains a separate dependency; this package does not establish remote trust or qualify physical JACCL execution.

## Launch contract

The owner creates `ClusterBootstrapListener(deadlineUptimeNanoseconds:)` before launching its child. The listener creates a fresh directory with mode 0700 under `/private/tmp` and a Unix socket with mode 0600. No arbitrary descriptor inheritance through Foundation.Process is assumed. The existing stdin/stdout generation protocol, diagnostics pump, process deadline, direct-child signals and observed retirement stay unchanged.

Worker startup accepts the existing twelve pairs plus this **complete optional triple**:

```
--bootstrap-socket-path /private/tmp/darkbloom-bootstrap-.../channel
--bootstrap-owner-pid <actual local owner PID>
--bootstrap-deadline-uptime-nanoseconds <once-installed local startup deadline>
```

The triple is all-or-none. Its canonical positive PID and absolute local deadline are checked before connection; the deadline must be later than admission and no later than the existing worker lifetime. Socket operations also cap their initial lifetime at 300 seconds. These uptime values only cross the local process boundary. A remote owner derives its own deadline from a bounded remaining duration; it must never forward another Mac's uptime number.

The native worker connects explicitly before facade loading. It checks the private directory/socket metadata and requires both `LOCAL_PEERPID == configured owner PID == getppid()` and the kernel peer UID to match its effective UID. The listener admits only the actual PID supplied after successful `Process.run`, also with matching kernel UID. PID and UID come from the socket kernel interface, not a claimed JSON field. These checks bind a direct local child, not a sandbox against a hostile same-UID process or root. The worker must not spawn untracked descendants.

Pipeline's separate Process change exposes `launchedProcessIdentifier` and actual termination reason/status after `waitUntilExit`. This overlay does not edit Process or synthesize an exit status. Retain the listener through connection admission. After successful admission the accepted connection owns its descriptor independently; the listener can be released to unlink its private path. Listener/connection cancellation interrupts their bounded operations, but neither socket EOF nor descriptor release is native cleanup proof.

## Relay API

The new `DarkbloomClusterBootstrap` product depends only on Foundation and Darwin and retains macOS 14 as the shared package floor.

```swift
let identity = try ClusterBootstrapIdentity(membershipEpoch: epoch, rank: rank)
let connection = try listener.accept(
    processID: child.launchedProcessIdentifier!, identity: identity,
    deadlineUptimeNanoseconds: startupDeadline)
let round = try connection.receiveRound()
// Validate the authenticated route, native topology/round and both contributions.
try connection.reply(to: round, gathered: rankOrderedNativeBytes)
```

The attachment task runs independently of the owner's generation pump and invalidation callbacks. It must have an independently enforced owner deadline/fence. Receive and reply allow exactly one pending round. Every error poisons the connection; there is no reconnect or retry in a native epoch. The worker's `exchange` requires the next sequence and waits synchronously only until its fixed local deadline. Cancellation uses socket shutdown; the descriptor itself closes only at final object release so concurrent IO cannot access a recycled descriptor.

The 40-byte binary header binds magic `DBJB`, version 1, request/reply kind, rank, world size 2, membership UUID, sequence, contribution length and payload length. Header integers use big endian. Native payload bytes are unchanged. Contributions are 1...65,536 bytes; a reply is exactly twice the contribution and must echo the local rank's original slice. Sequence is 0..<6, with no wrap/replay. Headers are validated before payload allocation; fragmented reads/writes are bounded. Public `Data` slices need not start at index zero.

The outer authenticated owner relay must additionally bind owner incarnation/lease, both configured peers/builds, source/configuration and selected topology. It must collect exactly one contribution per rank and return rank-ordered concatenation. The local module cannot establish those peer claims by itself.

## Native serialization and readiness

The source-bound mesh sequence has four callbacks: native container length, destination bytes, then two native integer barriers. Ring uses six: left length/data, right length/data, two barriers. The relay must admit the exact selected schedule and validate native scalar lengths/barrier values **before returning them**, including nonnegative bounded compatible lengths. The native `SideChannel` interprets those scalars before allocating its next container; local frame byte caps alone do not bound an allocation induced by a malicious returned scalar. Do not copy a Swift RDMA struct layout or treat authenticated host identity as proof of valid native bytes. This upstream limitation is unchanged from the frozen shim.

`QwenResidentBootstrap` binds the connection epoch/rank/lifetime to the load configuration. `QwenResidentRuntime.load(_:bootstrap:)` creates the one-shot native callback and passes it to the first `Collective` construction. Existing source, actual resource, allocator policy, load agreement, model loading, loaded agreement and error/cleanup order remain intact. The callback goes through the C++ factory-priority path, avoiding native TCPAllGather for that selected initialization. Cached prior JACCL initialization is rejected by the prerequisite shim. Use a fresh native process per owner epoch.

The nil facade argument and absent worker triple retain **legacy experimental native TCP bootstrap** for compatibility. A physical authenticated factory must require the attachment; it must not label the nil path authenticated. No new readiness field or different loaded/source agreement is introduced. The C++ group cache can retain the callback/channel past local group-handle release. Closing the bootstrap socket after the source-defined initialization rounds does not establish readiness, peer consumption or worker retirement, and does not encrypt RDMA data traffic.

## Checks and integration

Run `bash Tests/run.sh <fresh-build-directory>` for direct Swift 6 checks with warnings as errors. The module and test executables are Foundation/Darwin only; no SwiftPM, MLX, Metal, model files, TCP, SSH or RDMA execution is involved.

The socket checks cover five groups with twelve actual direct child processes: both rank orderings, four/six rounds, full byte bound, fragmented headers, malformed/oversized/stale/rank-mismatched frames, EOF, slow partial input, actual peer-PID refusal, replay/in-flight refusal, wrong echo, nonzero Data indices, cancellation, shorter accept deadline, and private-path cleanup. The UID predicate is source-checked; tests do not create another-UID process. The worker parser checks five accepted configurations and twenty refusals, compiling the actual parser against a mechanically extracted load-configuration value and a stated allocator enum stand-in. The facade adapter is typechecked against an explicit native callback API stand-in; it is not a real Cmlx/MLX integration build.

The first test build failed only because a throwing semaphore-result read appeared inside a nonthrowing assertion autoclosure. It is retained under `history`; the result is now read before the assertion. Subsequent runtime source review corrected public Data-slice indexing and added the same 300-second socket cap; final checks use those bytes. No native candidate output was accessed.

Apply `runtime.patch` only after the frozen shim's native and Collective changes. Package manifest hunks are additive and should be merged with pipeline's independent SSH/Process changes, not replace those manifests wholesale. Root owns full native compilation, integration and actual two-host bootstrap validation. The local socket tests do not qualify the not-yet-wired authenticated relay.
