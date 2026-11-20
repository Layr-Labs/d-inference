# Persistent workers — progress, 2026-09-13

The active goal remains incomplete. The canonical target and opt-in product
criteria are in `d-inference/docs/design/distributed-inference-goal.md`:
two M3 Ultra 256 GB machines, dense Qwen3.8 27B registered W4 artifact, at least
800 uncached prefill TPS for the primary 8192-token batch-one workload, with
1000 TPS as stretch, correct continuation and an advantage over the best
eligible solo implementation. Reusable Qwen3.5 9B/35B and Gemma4 26B support
remain in scope. No target-hardware performance claim has been made.

This turn added experimental native `worker`/`worker-tp` modes and a Python
PersistentCohort client. Models load once per process; requests are serialized
and receive fresh KV/convolution/recurrent state. Epoch, sequence, model/plan,
numerical identity and full commands are agreed before cooperative execution.
Tokens are delivered once after rank agreement. Cancellation/deadline/protocol
failure retires the entire cohort. Reuse requires a new cohort and epoch.

Native binary SHA256:
`21e609cf5205ce72c49679e04200c3e670db6330539e5ca875936dec28aff9ed`.
Runtime bundle manifest SHA256:
`aef0a2693a264d74b0692f7beb1b4528023c150821c2bccd5139a369e898b2dd`.
Final 96-file experiment source snapshot SHA256:
`6488444d6222a041b80ee31cdadd836857038756805727609f5c082072d7e0ba`.
The snapshot precedes the subsequently added validation report/document links.

Evidence under `runs/persistent-workers-20260913-verified`: six native cohorts,
18 requests and six one-shot controls. Tiny Float32 dense, Float32 MoE and BF16
Qwen27 head-geometry fixtures each ran solo and full two-rank local TP. A/B/A
logits and tokens exactly repeat; each plan matches its own fresh one-shot
control. This is state/lifecycle parity, not new cross-plan numerical evidence.

Evidence under `runs/persistent-native-failures-20260913-verified`: solo and full
cohorts cancel after the first callback, native PIDs are gone before fallback
cleanup, and epoch reuse is rejected. Direct mismatched commands to two native
ranks produce exit1 on both before accepted/token events. The native CPU
protocol check passes 4112 accepted and89 rejected fixtures, including a genuine
short pipe frame with the writer kept open. The first live test revealed
Foundation read buffering; Darwin.read and the pipe regression fixed it.

All126 Python tests pass on final source (17 real-process lifecycle methods plus
protocol/pipe and prior harness tests); see persistent-client-python-final-
20260913.log/json. Relevant module hashes are recorded there. The refactor
separates staging/spawn, protocol, pipeIO, request stream/callback and lifecycle.
No submodule edits, commits, pushes, provider starts or deployments occurred.

Boundaries: fixed-count greedy text only; no EOS/sampling serving semantics,
continuous batching, MTP, multimodal, cache handoff or product engine bridge.
An already admitted Python callback may finish after cancellation; native work
is retired and later admissions stop, but arbitrary user side effects cannot
be undone. Worker timing is diagnostic. The prior BF16 MoE router divergence
remains unresolved; native attention-output precision remains the default.

Latest read-only hardware check: 48 GB peer still offline in Tailscale, unchanged
LastSeen 2026-09-13T23:40:00.1Z; SSH timed out. The24 GB peer is reachable and its
Thunderbolt interface is inactive. No network changes or sustained real-model
benchmarks were made. Cause of the outage remains unknown.

Next useful software work: define the production text-generation/termination
contract and lifecycle/admission seam for a distributed CBv2Engine before
loading full weights. Preserve cancellation, release-once and model/execution
identity isolation. Actual remote worker/JACCL transfer, real-model quality,
M3 Ultra performance and opt-in setup/rollback still need hardware qualification.
