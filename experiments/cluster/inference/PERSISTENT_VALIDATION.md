# Persistent worker validation — 2026-09-13

The experimental workers retain loaded weights across serialized requests while
creating fresh KV, convolution and recurrent state. Six native synthetic
configurations passed exact A/B/A state-isolation and one-shot equivalence
checks. This validates worker behavior on one development Mac; it does not
qualify real-model numerics, physical RDMA, M3 Ultra throughput or provider
integration.

## Bound execution and source identity

- Native executable SHA-256:
  `21e609cf5205ce72c49679e04200c3e670db6330539e5ca875936dec28aff9ed`.
- Shared runtime bundle manifest SHA-256:
  `aef0a2693a264d74b0692f7beb1b4528023c150821c2bccd5139a369e898b2dd`.
- Source snapshot manifest SHA-256:
  `6488444d6222a041b80ee31cdadd836857038756805727609f5c082072d7e0ba`.
- Pinned dependencies: MLX `3fa8f25e6451174d7b06be372c3a24272b77d88e`,
  MLX-Swift `6d6796d7a81b656d2749d39067e0a6bea2bc2986`, and
  MLX-Swift-LM `ce446cc5f76e013855fe0bde9002b6db1ac091b7`.

The source archive contains 96 experiment files as they stood at launch, before
this report was added. The two final run directories outside the repository are
`persistent-workers-20260913-verified` and
`persistent-native-failures-20260913-verified`. Each retains its driver, source
snapshot and receipt. The worker runs also retain per-rank events and verified
runtime snapshots. Private machine/process details remain in those local
records. Earlier non-verified-suffix directories record preliminary executions;
the final runs bind the client after its lifecycle refactor and idle-poll fix.

## Native model checks

All fixtures use seed 7, W4/G64 packed weights and native attention-output
precision. Each row was run solo and with two local ranks using the full FFN,
attention and recurrent-head partition over explicit loopback-test transport.

| Fixture | Floating parameter policy | A/B/A logits and tokens | Fresh one-shot control |
|---|---|---|---|
| `tiny`, dense hybrid Qwen | Float32 | Exact in both plans | Exact in both plans |
| `qwen-moe`, 16 experts/top-4 | Float32 | Exact in both plans | Exact in both plans |
| `qwen27-heads`, dense hybrid Qwen | BF16 | Exact in both plans | Exact in both plans |

Each of the six cohorts served three requests without replacing its native PID
or model-load ID. A uses 65 prompt tokens, chunk size 32 and six unforced greedy
outputs. B uses a different 37-token prompt, chunk size 16 and five prescribed
continuation inputs for six outputs. The last request repeats A under a fresh
request ID. Both ranks' logits match exactly within each cooperative request;
the callback receives one event per agreed token. All six cohorts close through
the agreed shutdown protocol.

The six additional one-shot executions use the same plan, artifact fixture,
prompt and numerical settings as their persistent counterparts. This checks
that introducing the token callback and persistent request loop preserves the
one-shot behavior. It does **not** establish numerical equivalence between
different partition plans, and does not resolve the BF16 MoE routing differences
documented in [the numerical investigation](ATTENTION_PRECISION.md).

## Native failure checks

- Cancelling from the first token callback permanently retires both a solo
  cohort and a two-rank cohort. Each delivers only that first callback, all
  native PIDs are gone before the test cleanup, and request reuse is rejected.
  These tiny local executions finish cancellation in approximately 28 ms and
  27 ms respectively; those observations are not remote cancellation bounds.
- Bypassing the controller and sending different prompt IDs to two real native
  ranks makes both exit with the workload-agreement error. Neither emits an
  `accepted` event or token for the mismatched request.
- The native CPU protocol check accepts 4,112 fixtures and rejects 89 malformed
  or invalid cases. It covers duplicate/escaped keys, exact integer syntax,
  canonical cross-language hashes, state mutation, request/epoch bounds and
  framing. Its real-pipe regression keeps the writer open and proves a short
  complete command returns without waiting for more bytes or EOF.

The first live pipe smoke exposed Foundation reads waiting for more data.
`WorkerLineReader` now uses bounded `Darwin.read` calls with EINTR handling.
The new pipe regression and subsequent live native tests verify that correction.

## Python checks and remaining work

All 126 experiment Python tests pass on the final sources. The 17 persistent
lifecycle tests launch real CPU fixture supervisors, workers and descendants.
They cover cancellation during startup and active work, peer identity/token
faults, crashes, missing completion, deadlines, unresponsive shutdown, callback
failure and permanent retirement. Pipe/contract checks also cover backpressure,
frame/byte bounds, fast final-frame delivery before EOF and idle polling without
a spurious request deadline.

An already admitted Python callback can finish after cancellation. The tests
verify that its eventual return cannot start another callback or request; they
cannot revoke arbitrary user-code side effects. The native process lifetime and
the caller's callback/output accounting are separate responsibilities.

The [worker contract](../runtime/PERSISTENT_WORKERS.md) remains serialized,
text-only, fixed-count greedy inference. Its timing fields include instrumentation
effects and are diagnostic. Target-hardware qualification, real artifact checks,
Gemma whole-model integration, production engine admission/accounting and opt-in
setup/recovery remain open under the
[active distributed-inference goal](../../../docs/design/distributed-inference-goal.md).
