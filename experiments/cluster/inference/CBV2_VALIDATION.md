# Dense Qwen CBv2 integration — 2026-09-13

The experimental `cbv2-contiguous` execution path calls dense Qwen's actual
production CBv2 model adapter, prompt output narrowing and request-owned
KV/conv/SSM state transactions. The 108-run synthetic matrix completes in solo,
FFN-TP and full-TP modes. Float32 passes the strict numerical checks; BF16 has
unresolved solo/TP differences and a separate first-output difference between
ordinary and CBv2 execution for some final-chunk shapes.
**This is model/state integration evidence, not production
scheduler, paged-backend, real-artifact or target-hardware qualification.**

## Integration boundary

The source audit distinguishes ordinary dense CBv2 prefill/decode from the
specialized A3B captured-MTP verification path. Dense MTP-off CBv2 continues to
call the FFN down, attention output and GDN output `Linear` overrides. Retaining
the concrete `Qwen3NextMLP` permits the pinned decoder's typed dispatch, and
leaving GDN input projections unchanged preserves their eligible fusion.
Whole-MLP substitutes used by ordinary MoE/local oracles are rejected here.

The A3B verification helper instead reads packed arrays directly and can bypass
those overrides. Its fixed kernel geometry also requires revalidation after
partitioning. Neither execution path enables it. This finding narrows the
earlier broad concern about CBv2 fast paths: dense MTP-off integration does not
require a pinned model-source fork.

`RequestExecution.swift` separates request state from token selection and
transport coordination. The ordinary implementation retains the previous
prepare/forward calls. `CBv2RequestSession.swift` calls
`CBv2SteppableLanguageModelAdapter.recurrentPrefill` for intermediate/final
chunks and its recurrent `forward` for decode. It never delegates CBv2 work to
the ordinary model forward. Each rank creates cache and recurrent geometry from
its actual loaded model, including local head counts under the full plan.

Intermediate prefill evaluates a hidden handle and avoids discarded vocabulary
projections; the final chunk projects one vocabulary row. Each step evaluates
output plus KV/device-offset and recurrent roots, checks the MLX error handler,
validates ownership, shapes, dtypes and token advancement, and then commits the
recurrent generation. Cleanup releases bindings before rows and recurrent
ownership, with no reuse of a failed request. Native deadlines remain necessary
for stalled collectives.

Every CBv2 TP request checks its aggregate floating graph-construction hook count
against layer count, partition and number of forwards. Int32 control/token
collectives are excluded. This detects an incorrect total; it is not a per-layer
trace or independent proof of completed transport operations. Request construction and state
assertions, including device-offset host readback, are inside measured work;
these timings describe this synchronous path with those checks enabled.

## Identity and scope

`--execution-path ordinary|cbv2-contiguous` is required as `executionPath` in
schema-8 reports and protocol-4 worker identity; `ordinary` is the explicit
default. Peers agree on it before inference. Old reports/worker versions,
missing or mismatched path values, and unsupported families fail closed.
Native metadata preflight checks the promised path before worker readiness.

Support is restricted to dense Qwen and serialized text requests, with no MTP,
prefix reuse, padding, multimodal input or state handoff. CBv2 uses contiguous
KV; it does not run the production scheduler or segmented paged backend. The
source limit is prompt plus output count at most the lesser of declared context
and 32,768, and at most 4,096 output tokens. MoE/Gemma retain ordinary execution.

The initial six-run smoke uses `tiny`, Float32, seed 7, 65 prompt tokens in
chunks of 32, and eight teacher-aligned outputs. Its CBv2 solo/TP comparisons
have worst-row relative RMS below `8e-7`; both partition plans pass the unchanged
strict bounds and all paired argmax choices agree. Each CBv2 mode's logits equal
its ordinary counterpart exactly. The immutable local smoke directory is
`cbv2-smoke-20260913`.

The native protocol check passes 4,112 accepted fixtures and 95 rejections.
Its version-4 canonical request SHA-256 is
`168a6c912b4c38f111ef02b46d86a512a4132c604cb8f1dcda94b452cb186cd3`,
independently reproduced by Python. The 162-test Python suite covers execution
path identity, family/count restrictions, forwarding, request reuse, cancellation
and mismatch fencing. Numerical whole-model validation is separate from those
CPU protocol tests.

## Expanded native matrix

All cases run locally using synthetic weights. A cooperative run uses two
processes and the real TCP ring over loopback; it is not a two-machine or RDMA
measurement. The `qwen9-heads` and `qwen27-heads` fixtures preserve selected head
layouts at small hidden/layer sizes. They are not the real 9B/27B artifacts.
Each run captures eight logit rows with seven fixed teacher continuation inputs.
Both ranks return identical logits and agreed tokens in every completed pair.

The unchanged per-row gate requires max absolute error below `1e-3`, relative
RMS below `1e-4`, and equal argmax. Execution success does not imply numerical
acceptance. Counts below compare each TP plan with the same-path solo control.

| Matrix | Logical executions | Shapes | Float32 TP comparisons passing | BF16 TP comparisons passing |
|---|---:|---|---:|---:|
| Short, three profiles, two seeds | 72 | Prompt/chunk 65/32 and 97/16; final chunk 1 | 24/24 | 0/24 |
| Declared context boundary, 27B head layout | 12 | 8,184/512; final chunk 504 | 4/4 | 0/4 |
| Final-chunk shapes, 27B head layout | 24 | 66/32 and 96/32; final chunk 2 or 32 | 8/8 | 0/8 |

Across these matrices, Float32 TP worst-row relative RMS is below `8.6e-7`.
BF16 TP worst-row relative RMS is `0.0151321352`. All paired argmax choices
agree, but that does not override the failed BF16 logit gate or establish
real-model quality.

Ordinary/CBv2 path comparisons expose a different boundary. All 36 short
comparisons and all six two-token-final-chunk comparisons are exactly equal.
With 32- or 504-token final chunks, the first output differs; Float32 remains
within the gate, while BF16 first-output relative RMS ranges from `0.00317`
to `0.00362` and fails it. Every one of the seven subsequent teacher-controlled
decode rows is exactly equal between paths, and all first-output argmax choices
still agree. Overall, 48/54 path comparisons pass the strict gate, with 42/54
exact; the six failures are BF16 first-output cases.

The pinned `Qwen35TextModel.cbv2RecurrentPrefill` slices hidden state before
final RMSNorm and vocabulary projection, while ordinary forward processes all
final-chunk rows. This is a plausible shape-dependent arithmetic boundary,
not a proven projection-only cause. Exact later decode logits constrain the
observed difference but are not proof that every hidden state byte is equal.
Further isolation and real-artifact quality checks are required; tolerances
remain unchanged.

The first attempted long run used an 8,192-token prompt plus eight outputs and
was correctly rejected by CBv2 because the fixture declares an 8,192-token
context. Its failed receipt is retained. The successful boundary matrix uses
8,184 plus eight; it does not replace the goal's real-model 8,192-token prompt.

## Persistent requests and failures

Nine cohorts cover `tiny` Float32/BF16 and `qwen27-heads` BF16 across solo,
FFN TP and full TP. Each keeps one model load per rank and executes A/B/A plus
a one-token prompt with one output. All 36 requests complete. Every repeated A
matches exactly, and each cohort's A also matches a fresh one-shot control.
The single-output cases execute zero decode forwards. This checks fresh KV,
conv/SSM ownership and reuse of the loaded model across serialized requests.

An additional cross-partition comparison of these worker outputs finds a
stronger BF16 failure: `tiny` request B (37 prompt tokens, chunk 16, six outputs,
teacher inputs `[12,25,38,51,64]`) changes argmax at zero-based output positions
3 and 4 in both FFN and full TP relative to solo. Solo chooses 412 then 118;
both TP plans choose 310 then 79. Each pair of ranks still agrees, and A/B/A
isolation still passes. Thus the absence of argmax changes in the 108-run
matrix does not generalize even to all synthetic worker fixtures. BF16 needs
numerical qualification, not just successful lifecycle tests.

Native cancellation checks cover all three execution modes. Cancelling after
the first agreed token reaps workers and supervisors, marks the request failed,
retires the epoch and rejects reuse. Observed local cancellation-to-reaped time
is below 21 ms in these three cases; this is not a remote failure-latency claim.
Direct native peer-command mismatch fails before `accepted`; ordinary/CBv2
identity mismatch fails before `ready`. Gemma mixed/W8, Qwen MoE and an unknown
execution path are rejected at CLI validation, before worker readiness.

Six ordinary-path Gemma regressions replay archived synthetic BF16 solo/FFN
pairs across native, Float32-branch and Float32-through-norm policies. Every
per-rank logit value, token history and compared model/input identity matches
its historical reference exactly after the request-session refactor. The
successful `cbv2-ordinary-regression-20260913` receipt retains the original
inputs and all old/new hashes. An earlier attempt was rejected by the archived
launcher's output-directory guard before any native execution; that failed
driver receipt is retained separately.

## Evidence identity and remaining work

The expanded matrices, workers and failure checks use executable SHA-256
`1a1cb598a53d07fceb8a589b49c7ef7a93bade685e33f79fcc7c1ac9c53d02b1`,
metallib SHA-256
`2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2`,
and schema 8 / worker protocol 4. The final incremental release build passes
with Xcode 26.5 and Swift 6.3.2. The initial six-run smoke precedes the final
metadata-preflight addition and retains its separate executable receipt.

Local immutable directories are `cbv2-inference-20260913`,
`cbv2-context-bound-20260913`, `cbv2-tail-shapes-20260913`,
`cbv2-workers-20260913`, and `cbv2-failures-20260913`. Each preserves its driver,
source manifest, bundle identity and raw results. The main matrix's experiment
source-manifest SHA-256 is
`1283490fc23877e763323a63bb0a02746d3e42f900a6d954499d617a49a454f3`.
These experiment snapshots do not alone attest the entire dependency build;
the pinned submodules and generated dependency overlay need their own record.

BF16 numerical qualification, actual registered artifacts, production scheduler
and paged-backend integration, remote failure recovery, physical RDMA and M3
Ultra performance remain open. None of these synthetic measurements establishes
the 800/1,000 TPS goal or makes distributed execution release-ready.
