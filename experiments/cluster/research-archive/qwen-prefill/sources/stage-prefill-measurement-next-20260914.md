# Next uncached stage-prefill measurement

Source-only design, 2026-09-14. No native/GPU execution, model payload read, or
performance estimate. This narrows the existing
`docs/design/distributed-inference-goal.md` measurement contract and the earlier
`qwen-tp-arithmetic-and-layer-pipeline-20260913.md` plan; it does not replace their
qualification requirements.

## First implementable milestone

Add a separate **noncapturing, bounded 128-token / chunk32 / one-output timing
smoke**, using the same verified 9B artifact and one final target-token receipt.
Keep the existing captured correctness modes and their throughput-invalid flags
unchanged. Its first local-loopback result is a timer/lifecycle check on one
shared GPU, not cluster TPS qualification. Reuse the actual CBv2 adapter, verified
full/stage loaders, owned state, byte transport and cohort cleanup. Avoid another
model forward implementation or a new serving framework.

The current drivers are unsuitable as timers even if their JSON is emitted
later. `QwenLayerStageLookaheadContext.capture` snapshots/hashes KV/conv/SSM at
every frame and copies full vocabulary logits; its action recorder adds callback
work. Split this observation from the completed forward so the timed path can
retain bounded scalar counters without calling capture. Preserve evaluated
output + recurrent + KV/device-offset roots, error checks before commit, fresh
ownership assertions, and final retirement. `QwenLayerStageSession.perform:145`
still hashes each outgoing native residual; boundary validation and transport
also read/hash it. Those remaining actual integrity/staging/fence costs must stay
inside the reported interval. Removing JSON alone does not remove these costs.

Current consumed ACKs contain no selected token. Introduce a separately admitted
bounded final-token receipt binding epoch, request, final prompt frontier,
vocabulary, selection policy, and token ordinal0. Rank1 evaluates the final
`[1,V]` target logits, argmax, scalar readback and all state roots, then returns
the selected token; rank0 validates it after draining the final consumed ACK.
Do not interpret that ACK or rank1's report-file arrival as token availability.
A later generated-token continuation needs the same checked receipt per step;
`QwenLayerStageOverlapDecodeAdmission` currently permits only prefill-only or
frozen-teacher diagnostics.

## Timer and comparison contract

Use rank0's monotonic clock as the request authority. After model loading,
artifact hashing and a completed warmup with retired caches, synchronize and
agree on a fresh request. Start immediately before submitting its prepared token
IDs and start command. Create **both ranks' fresh request state after this start**;
current ready-after-session-construction cannot silently exclude that cost.
Stop after rank0 has the validated first selected token and final consumed
completion, with every required GPU/transport operation complete. Thus the
interval includes state construction, every prompt chunk including a short last
chunk, pipeline fill/drain, hashing/staging/fences, final norm/head, selection,
readback and token return. It excludes tokenization, weights/loading/verification,
prior warmup, pre-request readiness/barriers, post-timing evidence serialization
and state teardown. Record teardown separately and require it to finish before
the next fresh request. `P / elapsed` counts exactly P uncached target input IDs.

Use `Benchmark.execute:62–74` for clock/selection semantics, not its TP token
collective. Its ordinary session creates cache metadata before that clock while
CBv2 creates state inside it (`RequestExecution.swift:69–84`); the new comparison
must place both paths' fresh state construction consistently. Preserve the
production CBv2 `.evaluationOnly` intermediate and `.lastPositionLogits` final
output narrowing. Never force full logits at every prompt position to simplify
timing.

Measure three plans with one frozen binary/artifact/numerical policy:

* **Matched solo:** full-model CBv2 with exactly the pipeline microchunks. This
  isolates the effect of stage placement and scheduling at the same shapes.
* **Serial stages and lookahead:** use the same measured transport/integrity and
  token-return protocol; serial drains consumed before preparing the next chunk,
  lookahead admits one next prompt preparation. Bind the scheduling policy in
  the request/report. Comparing old captured v1 serial directly to uncaptured v2
  lookahead confounds capture and the additional received ACK.
* **Fastest correct eligible solo:** separately screen the same binary's actually
  implemented ordinary and CBv2 solo paths and legal chunk sizes on development
  prompts; freeze the winning policy before the paired evaluation. Pipeline
  chunk size may be tuned independently. Publish this comparison as well as the
  matched-chunk control. A deliberately small-chunk solo is not the fastest-solo
  reference. Do not bypass existing artifact/backend eligibility to add a faster
  candidate, and do not claim unimplemented production backends were compared.

For a small repeated screen, keep model instances resident, warm the actual
shape/model fusion path, then retire all request state and use fresh caches for
each sample. Warm weights/kernels do not mean a cached prompt. Alternate or
balance plan order on fixed real prompt IDs, retain every sample/error and
resource observation, and report medians/tails rather than the best run. Do not
reuse advanced state or retry a failed request within its epoch. The goal's
held-out ten-prompt, three-repeat 8K qualification remains a later requirement.

Run correctness captures in separate executions of the same forward/chunk/
selection policy: final full logits plus controlled continuation and state
checks, then captured-vs-uncaptured output agreement. A teacher continuation
validates state under fixed history; it is not greedy generation. Before claiming
useful request acceleration, add checked generated-token return, actual
continuation agreement, committed decode latency/TPS and total request latency.
There is no current prefill-to-solo state migration to exclude from that cost.

## Expanding 128 → 512 → 8192

Do not raise one flag globally. New measurement admission must jointly bind
prompt/context, chunk, frame count, typed wire offsets, action/record allocation,
state capacities, output count and deadline, while old diagnostic bounds stay
unchanged. Current hard limits occur in `QwenLayerStageSchedule.swift:12`,
`QwenLayerStageBoundaryWireHeader.swift:133–134` (offset/sequence<132, chunk≤32),
`QwenLayerStageOverlapPlan.maximumFrames=132`, and the action cap4096. At8K with
chunk32, 256 prefill frames already exceed current frame/action admission.
Keep positive payload-size products within the explicit Cmlx P2P16MiB cap.

After the128 timing/selection smoke and its no-capture control pass, first admit
512 with bounded chunk32 to test a longer state chain without simultaneously
changing matrix shapes. Then qualify selected larger chunks and tune the solo
and pipeline screens. Proceed to2K and8K only after their own admission,
correctness and memory checks; do not infer 8K behavior from128/512. Chunk changes
can alter native quantized/GDN arithmetic and workspace, even with whole-layer
widths preserved.

Use the actual stage geometry for KV growth and three live recurrent generations,
plus bounded received/prepared residuals. The existing512MiB named-state/snapshot
formula is not whole-process memory; long KV can exceed it legitimately and
requires a new reviewed bound. Retain8GiB/6GiB/512MiB artifact/ canonical/source-
tensor caps for the 9B step. The primary27B artifact exceeds the current canonical
loader scope and needs separate verified resource admission. Record loading and
steady resident/peak MLX, process RSS, pressure and swap separately; no8GiB
reclaimable heuristic proves an arbitrary long-context fit. Keep fail-closed
pressure/swap gates, descriptor limits, no-user-process eviction and owned cleanup.

Within each rank, keep one serialized MLX model/state/eval caller. Lookahead is
across processes: rank0 prepares the next prompt chunk only after received ACK,
while rank1 consumes the prior one; it drains consumed before the next header.
Do not add a second same-process MLX/eval thread to hide blocking sends. Local
loopback shares one physical GPU and cannot establish a two-chip scaling gain.
Physical peer/transport validation and separate fastest eligible solos on the
actual machines must precede any hardware claim. Per-rank completed work/wait
intervals may diagnose imbalance, but do not sum overlapping intervals, subtract
unrelated host clocks, or infer GPU overlap from host action order. Keep equal
whole-layer placement fixed initially; later balancing is a measured plan change.
