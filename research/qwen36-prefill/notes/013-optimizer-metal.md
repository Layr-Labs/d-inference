# 013 — Optimizer: hardware / Metal / MLX overlap (M3 Max)

Status: code-verified analysis, zero new Mac measurements taken by this note.
Everything below is either (a) read directly from files in this checkout with
line/path citations, or (b) explicitly marked as public-knowledge inference
because the underlying source is **not present in this sandbox** (see §0).
No speedup number in this note is a promise — every one is gated on a Mac run
that has not happened yet.

Role: hardware/Metal/MLX overlap. I do not re-litigate scheduler/packing
(`014`, `017`), the tile-allowlist roofline (`018`), or the merge gate
(`016`) — I build on them and answer the five hardware questions the GOAL
assigned.

---

## 0. What I could and could not read (say this up front)

`libs/mlx-swift` is checked out, but it is **not** a full MLX checkout:

- `Source/Cmlx/mlx/` and `Source/Cmlx/mlx-c/` — the actual `mlx` and `mlx-c`
  C++ sources that `mlx/backend/metal/{device,eval,metal}.cpp` live in — are
  **empty directories** in this sandbox (`ls` shows 0 files). `CMakeLists.txt`
  (`libs/mlx-swift/CMakeLists.txt:30-34`) pulls `mlx-c` via
  `FetchContent_Declare(... GIT_REPOSITORY ".../mlx-c.git" GIT_TAG "v0.6.0")`
  at configure time; SwiftPM's `Package.swift` target list
  (`libs/mlx-swift/Package.swift:236-314`) references
  `mlx/mlx/backend/metal/*.cpp` by path, confirming that's where the real
  scheduler/command-buffer code belongs, but the bytes are not here because
  nothing has run `cmake`/`swift build` in this environment (GOAL.md: "Cloud
  VM ... cannot compile Metal").
- What **is** present and real: the Swift bindings (`Source/MLX/*.swift`),
  the mlx-c **headers** (`Source/Cmlx/include/mlx/c/*.h`), Apple's
  `metal-cpp` headers, and a small set of **Eigen-Labs-authored** files
  (`EvalProbe.swift`, the Gemma4/Qwen expert-tile classifier header, custom
  test files) that this fork added on top of upstream mlx-swift.
- Net effect: I can prove things about the **Swift-level submission
  contract** (one process, one lock, one stream) with high confidence from
  primary source. I **cannot** show you the literal C++ that builds Metal
  command encoders — anything about encoder-level concurrency inside a
  single `eval()` is flagged as inference from public MLX architecture, not
  a fact read from this repo.

---

## 1. Can MLX overlap independent kernels today? — **No, and the reason is architectural, not incidental**

Two independent, compounding facts, both read directly from vendored source:

### 1a. One process-global GPU stream, on purpose

`libs/mlx-swift/Source/MLX/Stream.swift:82-114`:

```swift
public static var gpu: Stream { _globalGPUStream }
private static let _globalGPUStream = Stream(mlx_thread_unsafe_gpu_stream_new())
```

The doc comment on `Stream.gpu` (lines 86-106) is this fork's own explanation
for why, and it is worth quoting because it is the whole answer to "can MLX
run two independent graphs concurrently":

> "MLX 0.32 made the *default* stream's command encoder thread-local
> (`get_command_encoders()` is `thread_local`). The moment GPU work hops
> threads ... eval can no longer find the encoder and aborts ... A single
> global stream restores the MLX 0.31 single-default-stream semantics the
> engine was built around. The 'thread-unsafe' caveat (no synchronization for
> concurrent multi-thread submission) is satisfied because **the engine
> serializes GPU submission** (the scheduler is an actor; the B=1 fast path
> runs exclusively)."

MLX's own API supports multiple streams — `Stream(Device)` calls
`mlx_stream_new_device` (`Stream.swift:156-160`) and any op takes a
`stream:` parameter (`StreamOrDevice`, `Stream.swift:25-66`). That mechanism
is real. Nobody uses it: a full-repo grep for `Stream(Device`, `Stream(device:`,
`Stream(.gpu)`, `withNewDefaultStream` across `provider-swift/` and
`libs/mlx-swift-lm/` returns **zero matches**. Every op in Qwen/CBv2 runs on
the one global GPU stream, always.

### 1b. One process-global lock around every eval

`libs/mlx-swift/Source/MLX/Transforms+Eval.swift:9,15-26`:

```swift
let evalLock = NSRecursiveLock()
public func eval(_ arrays: MLXArray...) {
    ...
    _ = evalLock.withLock {
        EvalProbe.beginEval(); defer { EvalProbe.endEval() }
        return mlx_eval(vector_array)
    }
}
```

`asyncEval` takes the same `evalLock` (lines 48-54), just for the (short)
submission call rather than for the blocking wait. Every `Stream` mutation
(`init`, `deinit`, `synchronize`, `description`) also takes `evalLock`
(`Stream.swift:148,157,163,170,192`). This is a single, recursive,
process-wide mutex around all MLX C-API entry points that touch scheduling.

### Conclusion for Q1

**Confirmed by code, not refuted:** on this stack, two independent forward
passes cannot be "in eval" concurrently from Swift's perspective — they
serialize on `evalLock` before either one's kernels ever reach Metal. This
is on top of, not the same fact as, the single GPU stream: even if the lock
were per-stream, there is only one stream to be per. Both restrictions
are deliberate (documented) engineering choices to make the actor-based
`EngineLoopV2` correct across `await` thread-hops, not oversights.

This directly explains **why B=2/B=4 concurrent *solo* forwards would never
overlap** even before CBv2 packs them into one `[B,L]` graph. It does **not**
by itself explain the "busy-union == sum" observation inside a *single*
`asyncEval` call, because that's one call, one stream, one lock acquisition —
the lock is irrelevant once you're inside the one call. That is a
kernel-encoding question (§2), which this sandbox cannot verify from source.

---

## 2. What would "wavefront / concurrent dispatch" actually change? (files, not slogans)

Given §1, "concurrent dispatch" can only mean one of three concretely
different code changes. I list them with the exact files each would touch
and why the Synthesizer queue (`012`) already ranks all three below the
tile-allowlist lever.

### (a) Multiple MLX streams for independent request graphs — dead on arrival without a bigger refactor

Files: `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/EngineLoopV2.swift`
(every `asyncEval` call site: lines ~1529, 1545, 1595, 1903),
`libs/mlx-swift/Source/MLX/Stream.swift` (would need a second
`Stream(Device.gpu)`, not the shared global).

This requires **reverting** the fix in §1a's own comment (thread-local
encoders broke under Swift's actor/await hops) or building a second,
carefully-thread-pinned stream. It also fights the actor model directly:
`EngineLoopV2` already serializes all graph-building onto one `engineQueue`
(note `014` §4.1) — two streams would mean two Metal command queues issuing
work that the *scheduler* still produces on one queue, so the win only
exists if the **rows are already independent at the scheduler level**, which
for equal-length text bursts they are not — CBv2 already merges them into
one packed `[B,L]` graph on **one** stream before this would even apply
(note `012` §"Deliberate exclusions": "packed execution already forms one
layer-major graph and one `asyncEval`"). The only place independent-stream
work would have distinct graphs to run is genuinely **ragged** arrivals
(ununiform prompt lengths that can't form a packed cohort) — a real but
narrow case, matching note `015` Card 6's own scoping ("wavefront is for
ragged arrivals ... not Card 1's packed path").

### (b) Intra-graph concurrent kernel encoding (the literal "busy-union == sum" fix)

Files: none in this repo. This is a change to whether MLX's Metal backend
requests `MTL::DispatchType::Concurrent` on the compute command encoder it
builds per command buffer — `mlx/backend/metal/device.cpp` /
`mlx/backend/metal/eval.cpp` inside the **unfetched** `mlx` submodule
(§0). `MTLCommandBuffer::computeCommandEncoder(MTL::DispatchType)`
(`libs/mlx-swift/Source/Cmlx/metal-cpp/Metal/MTLCommandBuffer.hpp:152`) and
`MTLComputePassDescriptor::setDispatchType`
(`.../MTLComputePass.hpp:77`) prove the *capability* exists in the Metal
binding MLX links against. Whether MLX's C++ core actually calls the
concurrent variant anywhere is **not verifiable in this sandbox** — public
MLX architecture (outside this repo) uses the default serial/hazard-tracked
encoder, which is consistent with the observed zero-overlap signature, but
I have not read the .cpp to confirm it for this pinned version. **This is
the only lever that would touch upstream mlx, not Darkbloom code** — it
would mean patching `ml-explore/mlx` (or `Layr-Labs/mlx`, the `darkbloom-base`
fork target per `.gitmodules`) and re-vendoring, which is a different order
of effort than anything else on the roadmap.

### (c) CPU/GPU pipelining across scheduler steps — already shipped, not a gap

Files: already `EngineLoopV2.swift`. `asyncEval` (not blocking `eval`) is
already the step-submission primitive at every call site listed in (a), and
`scheduleNextStep` immediately queues the next `engineStep()` while the GPU
chews on the previous step's `asyncEval` (note `014` §4.2, Y5: "pipelining
at most 2 deep"). This is the CPU-graph-build/GPU-execution overlap that
"wavefront" sometimes informally means. **It is not a missing feature.**
Any wavefront proposal that claims this overlap as new value is re-describing
existing code.

### Conclusion for Q2

Concretely, "wavefront" is not one lever, it's three, with wildly different
cost/blast-radius:

| Variant | Files touched | Cost | Already blocked by |
|---|---|---|---|
| (a) multi-stream ragged cohorts | `EngineLoopV2.swift`, new `Stream` | High — actor/thread-hop hazard `Stream.gpu`'s own comment describes | Packed path already covers the equal-length case |
| (b) concurrent MTLDispatchType | unvendored `mlx/backend/metal/*.cpp` | Very high — upstream/fork MLX C++ patch + re-vendor + re-verify every kernel's hazard assumptions | Source not even present to patch from this environment |
| (c) CPU/GPU step pipelining | none | Zero — already shipped | N/A |

Synthesizer `012` ranks general wavefront **last** among live bets and gates
it behind exhausting wide packed cohorts first. Nothing in this investigation
contradicts that; it reinforces it with a concrete reason (a) is hard and
(b) is out of this repo's reach without an upstream patch.

---

## 3. Expert-tile occupancy: time lever or ALU vanity metric?

Verified independently (not just trusting note `018`) from two files:

- `libs/mlx-swift/Source/Cmlx/include-framework/mlx-backend-common-gemma4_expert_qmm.h:147-149` —
  the CPU-side route classifier:
  ```cpp
  if (input.assignments != 4096 && input.assignments != 8192 &&
      input.assignments != 16384) {
    return Gemma4ExpertQMMRoute::fallback_assignment_count;
  }
  ```
  This is a **closed allowlist**, not a soft heuristic. Qwen top-8 over
  E=256 ⇒ tokens-per-tile-hit-forward = assignments/8 ∈ {512, 1024, **2048**}.
  Anything else silently falls back to the (slower, unmeasured-here) legacy
  gather.
- `libs/mlx-swift/Tests/MLXTests/SortedGatherQuantizedMMTests.swift` —
  independently confirms tile granularity (`BM16`/`BM32` boundary tests,
  lines ~82-176) and re-asserts the same three-value allowlist
  (`XCTAssertTrue([4096, 8192, 16384].contains(rowCount))`, lines 92, 275).
- `CBv2Contracts.swift:693-703` (already cited by `018`, re-verified here):
  512-token chunk ⇒ 16 assignment-rows/expert on a 32-row tile (~50%
  occupancy); 2048-token stripe ⇒ 64 rows/expert = exactly 2 full tiles
  (~100% occupancy, no partial-tile waste).

### The physics, stated precisely

Occupancy (tile-fill ratio) and weight-stream-count (chunks needed to cover
a prompt) are **mathematically coupled but causally distinct**:

- Occupancy governs how many ALU cycles a tile-launch wastes on empty rows.
  This kernel is **weight-bandwidth-bound** (confirmed independently by the
  2026-08-19 report's measured stripe-alone wash and by
  `QwenExpertTilePerfTests.swift`'s own GB/s instrumentation, which exists
  precisely because the authors expected this kernel to be memory-bound, not
  ALU-bound). On a BW-bound kernel, idle ALU lanes during a half-empty tile
  are not "wasted time" — the memory system was never going to feed them
  faster regardless.
- Weight-stream-count governs how many times the **same** ~21 GiB of expert
  weights gets re-read from unified memory. That total is what the roofline
  (`003`) prices in bytes/token, and it is a real wall-clock lever because
  DRAM bandwidth is the actual bottleneck resource.

At L=512 vs L=2048 solo, occupancy visibly changes (50%→100%) **and** the
weight-stream-count changes (16 streams→4 streams for an 8K prompt) in the
same direction, so it is easy to misattribute the measured win to
occupancy. The 2026-08-19 report's own falsification nails this: stripe
alone (with expert-descriptor drains still on) was a **wash**, even though
occupancy went from 57.6%→~100%, because the drain bubbles — not ALU
idle time — were the actual bottleneck at that point. Once drains were
removed (trust), the stripe's real win showed up as ~9%, explained in that
report as "per-chunk fixed cost" (dispatch/launch/graph-build), not as ALU
utilization.

**Packed B=4 @ effective L=2048/step is not a new occupancy data point.**
Per `009`/`018`: `maxBatchedTokensPerStep=2048` caps a packed `[4,512]` step
at exactly 2048 total tokens = 16,384 assignments — the *same* tile-hit
geometry, same ~100% occupancy, as a solo 2048-token stripe. Occupancy is
therefore **saturated in both the packed and solo cases today** — it cannot
be the reason aggregate throughput is stuck at ≈1.0× solo. The only lever
left is reducing the **number of separate weight streams per total token
processed**, i.e. raising the assignment ceiling past 16,384 (note `018`'s
proposal, already coded as of `020` and awaiting a Mac A/B) so one launch
covers more total tokens without ever exceeding ~100% occupancy (which is
a ceiling, not something you can "improve" past).

### Conclusion for Q3

**Occupancy is a vanity metric here, confirmed independently, and this
generalizes cleanly to the packed case:** at L≥2048 (solo or packed-to-cap),
tile occupancy is already maxed and provides zero further discriminating
signal. The 2026-08-19 report's verdict on this exact question stands and
is not contradicted by anything in the packed-path evidence. The real,
measurable lever is assignment-ceiling extension (`018`/`020`), which is a
weight-stream-count change wearing an occupancy-shaped explanation. Do not
sell a future occupancy chart as the win; sell the streams-per-token number.

---

## 4. Measuring GPU busy vs wall on macOS, without lying

### What exists in this repo today: **nothing that measures actual GPU busy time**

- `EvalProbe` (`libs/mlx-swift/Source/MLX/EvalProbe.swift`) times how long a
  thread was **blocked inside `mlx_eval`** (host wall-clock around a call).
  It cannot distinguish "GPU was saturated the whole time" from "GPU was
  idle waiting on CPU-side graph construction, buffer allocation stalls, or
  serialized encoder submission." Its own doc comment is explicit that it
  is a *wedge* detector, not a utilization metric.
- `WedgeMonitor` (`provider-swift/Sources/ProviderCore/Inference/WedgeMonitor.swift`)
  is admits-vs-first-tokens bookkeeping — no timing granularity at all.
- The `X-Timing` header (`coordinator/api/dispatch.go:487-3006`) decomposes
  **coordinator-side** request latency (parse/reserve/route/dispatch/
  provider-wire time) — it has no visibility inside the provider process,
  let alone inside one `eval()` call.
- `GPU.startCapture(url:)` / `GPU.stopCapture(url:)`
  (`libs/mlx-swift/Source/MLX/GPU+Metal.swift:174-194`) wrap
  `mlx_metal_start_capture`/`mlx_metal_stop_capture` — **this is real and
  already wired**, but is not called anywhere in `provider-swift` or
  `darkbloom`'s CLI (grep for `startCapture`/`MTL_CAPTURE_ENABLED` across
  `provider-swift/` returns nothing). It requires `mlx` built with
  `MLX_METAL_DEBUG` and `MTL_CAPTURE_ENABLED=1` at runtime.
- The vendored `metal-cpp` headers expose the real ground truth —
  `MTL::CommandBuffer::GPUStartTime()`/`GPUEndTime()`
  (`libs/mlx-swift/Source/Cmlx/metal-cpp/Metal/MTLCommandBuffer.hpp:130-132,259-266`)
  — but nothing in this Swift stack reads them; they are only reachable
  from inside MLX's own (unvendored) C++ command-buffer completion handler.

### The honest measurement plan (for the Executor, on the Mac)

Ranked by how hard it is to lie to yourself with each one:

1. **Metal System Trace via Instruments, capturing a real prefill call.**
   This is the only ground-truth source in this list — it reads the actual
   GPU hardware timeline, not a host-side proxy. Two ways to get a trace:
   - Attach Instruments' "Metal System Trace" template to the running
     `darkbloom` process during a benchmark run (no code change).
   - Or use the already-wired `GPU.startCapture(url:)`/`stopCapture` API
     with `MTL_CAPTURE_ENABLED=1` bracketing exactly the prefill call under
     test — this needs a rebuild with `MLX_METAL_DEBUG` defined
     (`GPU+Metal.swift:178-179` documents the exact `Package.swift` edit),
     which is a Mac-side build change, not a Darkbloom serving change.
   Read the busy-union directly off the GPU track: sum each visible kernel's
   duration, compare to the union of their time intervals. This is the only
   way to honestly confirm or refute "busy-union == sum" for **this** M3 Max
   at **this** shape — the 24% figure in `GOAL.md`/`015` is inherited from
   an earlier report on different hardware and has not been re-measured
   here (note `015` itself calls it "prior profiling," not new evidence).
2. **`powermetrics --samplers gpu_power -i <ms>`**, sampled for the wall
   duration of a benchmark run. This gives system-wide GPU active-residency
   %, correlated against the benchmark's own wall-clock window. It is
   coarse (whole-GPU, not per-kernel) and cannot prove or disprove overlap
   between two specific kernels, but it is a real, hard-to-fake number for
   "was the GPU actually busy the whole time" at the process level, and it
   is the tool GOAL.md already mandates recording for power posture
   (`pmset -g batt` / `powermode`) — extend the same discipline to
   `gpu_power`.
3. **`QwenExpertTilePerfTests.swift`'s existing GB/s instrumentation**
   (`libs/mlx-swift/Tests/MLXTests/QwenExpertTilePerfTests.swift:106-119`)
   is a real, already-checked-in microbenchmark that computes
   weight-bytes-moved / wall-time for the exact expert-tile kernel, at exact
   Qwen shapes (`T512`/`T1024` gate_up/down). It is not a GPU-busy counter,
   but it is a **non-lying, code-grounded, already-runnable** bytes/sec
   number the Executor can get today with:
   ```
   MLX_EXPERT_TILES_PERF=1 MLX_GATHER_QMM_EXPERT_SLICES=1 \
     swift test --filter QwenExpertTilePerfTests
   ```
   (requires a source-matched `mlx.metallib` staged via
   `scripts/fetch-metallib.sh`, per the test's own skip guard,
   `SortedGatherQuantizedMMTests.swift:765-772`). Comparing this against the
   400 GB/s roofline (`GOAL.md` machine table) is a real, falsifiable
   "how close to the wall are we" number, and it composes with (1)/(2)
   rather than replacing them.
4. **Do not use `EvalProbe`/host wall-clock deltas as a GPU-busy proxy.**
   It is explicitly a wedge detector; using it to claim GPU utilization
   would be exactly the kind of unmeasured claim this note is told not to
   make.

### Conclusion for Q4

There is currently no non-lying GPU-busy counter anywhere in this codebase.
The Metal-trace route (via Instruments or the already-present but unwired
`GPU.startCapture`) is the only ground truth; `powermetrics` is a legitimate
coarse cross-check; the expert-tile GB/s test is the best already-runnable
proxy for the specific weight-bandwidth claim this GOAL depends on. Any
future note that states a GPU busy % or an overlap ratio for **this** M3 Max
must cite which of these three it used, or it is not measured — it is a
restatement of the 2026-08-19 M4 Max number.

---

## 5. The 164,783,923,200-byte fatalError — root cause found, and (probably) already fixed

### The arithmetic is exact, not approximate

`164,783,923,200 = 2 × 287,040²`, exactly (verified: `287040*287040*2 ==
164783923200`). This is **not** a clean fit for a vocab-width fp32 tensor —
`164783923200 / (248320×4) = 165,898.76` (note `000`'s guess), which is
*close* but not exact, and a real single-buffer Metal allocation size is
never a non-integer count of a dtype's element width. The exact factorization
into `N² × elementBytes` is the signature of a **square attention-shaped
buffer**, not a logits tensor.

### This is the vision-tower N×N intermediate, and the code already documents the exact same crash shape

`provider-swift/Sources/ProviderCore/Inference/VisionTowerBudget.swift:56-64`:

```swift
/// They are built at `queries.dtype`, i.e. the vision tower's activation
/// dtype, which is 16-bit (bf16/fp16) in every shipping checkpoint...
/// Verified against [REDACTED] crash reports: a
/// 298,090,824,192-byte refusal is exactly 386,064² × 2 (mask, factor 1)
/// or 96,516² × 16 × 2 (scores, factor 16).
static let attentionElementBytes = 2
```

Same file's header comment explains the mechanism: `Qwen3VLVision.Attention`
**always** materializes a dense additive mask `ones([1, N, N])` regardless
of which SDPA kernel MLX picks; if MLX falls back off the fused kernel
(head dim not in `{64, 80, 128}`), it *additionally* materializes a
`[1, H, N, N]` score tensor, H times larger. This is precisely the same
`N² × bytesPerElement × headFactor` shape documented for a **different**
prior crash (298 GB) right there in the file.

Solving the same equation for our number:

| headFactor | N | Note |
|---:|---:|---|
| **1** (mask, always present) | **287,040** | Most likely: the mask fires unconditionally, before any SDPA kernel choice is even made |
| 16 (fallback score tensor, 16-head tower) | 71,760 | Also an exact fit — `287,040 = 71,760 × 4`, so this is the same equation re-scaled, not independent evidence |
| 4 / 64 | 143,520 / 35,880 | Same caveat — clean only because 287,040 factors through small squares |

I cannot distinguish which of these fired from the byte count alone (any
perfect-square `headFactor` re-derives the identical total from this one
factorization) — that needs the actual crash's stack trace or log context,
which is not in this repo (only referenced secondhand in `notes/000`).
What is not ambiguous: **this is the vision-tower N² allocation family**,
not a text-prefill logits/attention shape, and not related to the
`E=256`/expert-tile/MoE path this GOAL is actually optimizing.

### The fix already exists, and its date lines up

```
$ git log --diff-filter=A -- provider-swift/.../VisionTowerBudget.swift
232911ca fix(provider): stop one oversized vision request from killing the daemon (#660)
$ git log -1 --format=%ad 232911ca
Sat Aug 22 00:22:11 2026 -0700
```

The crash in `notes/000` is dated 2026-08-21. This fix landed 2026-08-22 —
**one day later**. More importantly:

```
$ git rev-list -n1 v0.8.10
232911ca690b78cbd3c8f65668d69f75a8f6bef0
```

**The `v0.8.10` release tag points at the exact commit that added this
guard.** The Mac has `Darkbloom 0.8.10` installed (`notes/000`). If the
installed binary was built from the tagged `v0.8.10` release (the normal
release path — this is what `install.sh`/CI would produce), it already
contains `VisionTowerBudget.admit()`, which pre-flight-rejects an
over-budget vision request with a 4xx **before** attempting the Metal
allocation, instead of `fatalError`-ing the daemon.

**What I cannot confirm from the repo alone, and the Executor must check
on the Mac before relying on this:** whether the specific binary at
`~/.darkbloom/bin/darkbloom` was actually built from commit `232911ca`
(the tag) versus an earlier or different `0.8.10`-labeled build. Version
strings are manually bumped (`ProviderCore.version`, `ProviderCore.swift:243`)
and are not a cryptographic proof of provenance. Do not skip this check —
it is a one-command verification (compare install timestamp/build metadata,
or re-run `darkbloom update`) and it is exactly the kind of thing this GOAL
says never to assume.

### Why this matters for the actual 2.5x work, not just as trivia

`VisionTowerBudget` only guards the **vision** path. The GOAL is text
prefill, but the **same physics** — an unblocked `[1, H, L, L]` (or `[1,1,L,L]`
mask) score tensor materializing for a large L — applies to the **10
full-attention text layers**, and is exactly what
`DARKBLOOM_CBV2_ATTN_QUERY_BLOCK` (default 128,
`AttentionV1.swift:35-49`) exists to prevent, by bounding every score
tensor to `[1, H, blockSize, historyCount]` instead of `[1, H, L, L]`. This
is not a hypothetical: reviewer gate `016` (line 165) already lists "the
prior 164,783,923,200-byte allocation shape... must never be used as an
on-device crash probe" as a hard merge gate. Any experiment in this GOAL
that (a) tries a large one-shot prefill chunk (the `018`/`020` roadmap item
after tile-allowlist extension) or (b) touches query-block width (Synthesizer
queue item 3) must keep `shouldBlockQueries` active and budget the resulting
score-tensor shape against `MTLDevice.maxBufferLength`
(`GPU+Metal.swift:203-247`, `deviceInfo().maxBufferSize`) **before** running
it on the Mac — the same discipline `VisionTowerBudget` encodes for images,
applied to text attention instead of vision patches.

### Conclusion for Q5

Root cause: `Qwen3VLVision.Attention`'s mandatory `[1, N, N]` bf16 additive
mask (or, less likely by the same arithmetic, its `[1, H, N, N]` fallback
score tensor) for a vision-tower call handed ~287,040 (or ~71,760) total
patches in one call — not anything in the MoE/expert-tile/GDN/logits path
this GOAL is optimizing. Very likely already closed by the exact commit
tagged `v0.8.10` (pending a one-command confirmation that the installed
binary matches that tag). The generalizable lesson for this GOAL: any
unblocked `L×L`-shaped tensor is the recurring failure family on this Mac,
and the text-side analog (full-attention prefill without query blocking)
is one config flip away from recreating it — budget every new shape against
`maxBufferLength` before it runs, exactly as `016`'s merge gate requires.

---

## Summary table

| Q | Verdict | Confidence |
|---|---|---|
| 1. Can MLX overlap independent kernels today? | **No.** One process-global `evalLock` + one process-global GPU `Stream`, both deliberate (documented) design choices tied to the actor/await threading model. | High — read directly from `Stream.swift`/`Transforms+Eval.swift`, corroborated by zero second-stream usage anywhere in the served path. |
| 2. What would wavefront actually change? | Three distinct levers, not one: (a) multi-stream ragged cohorts — high cost, narrow applicability, fights the actor model; (b) intra-graph concurrent MTLDispatchType — requires patching unvendored upstream MLX C++, not verifiable or actionable from this repo; (c) CPU/GPU step pipelining — already shipped via `asyncEval`+`scheduleNextStep`. | High for (a)/(c) (read from source); (b) is architecture-capability-only, not confirmed present or absent in the actual MLX build. |
| 3. Occupancy: time lever or vanity? | **Vanity, confirmed independently**, and it stays vanity at packed B=4 — occupancy is already saturated (~100%) at both solo-2048 and packed-[4,512]-to-2048-cap; the real lever is assignment-ceiling extension (streams-per-token), which only wears an occupancy costume. | High — classifier header + test file cross-verified; physics matches the 2026-08-19 report's own stripe-alone-was-a-wash falsification. |
| 4. How to measure GPU busy vs wall honestly? | Nothing in-repo measures it today. Use Metal System Trace (Instruments or the already-wired but unused `GPU.startCapture`) for ground truth; `powermetrics --samplers gpu_power` as a coarse cross-check; the checked-in `QwenExpertTilePerfTests` GB/s harness as a non-lying BW proxy. Do not use `EvalProbe`/wall-clock as a utilization stand-in. | High that nothing better exists here; the recommended tools are standard macOS/Metal instrumentation, not exotic. |
| 5. The 164 GB fatalError | Vision-tower `[1,N,N]` (or `[1,H,N,N]`) mandatory attention buffer at N≈287,040 (or ≈71,760) patches in one tower call — exact byte-for-byte match, same family as a documented prior crash in `VisionTowerBudget.swift`. Fix (`232911ca`) is dated one day after the incident and **is** the `v0.8.10` tag commit — likely already closed on the installed binary, unconfirmed without a Mac-side check. Not related to the MoE/expert-tile path. | High on root cause (exact arithmetic + code citation); medium on "already fixed on the Mac" (depends on install provenance I cannot see from here). |

## What this means for the GOAL

Nothing here raises aggregate prefill tok/s by itself. This note's job was
to confirm/refute hardware claims and stop the GOAL from spending effort on
a lever that is either already-shipped (CPU/GPU pipelining), out of reach
from this environment (patching MLX's C++ scheduler), or a restatement of a
metric that was already falsified as non-causal on this exact kernel
(occupancy). The one item here with near-term payoff is methodological:
wire up Metal System Trace or `powermetrics` before the next round of Mac
measurements, so the GOAL's own "GPU busy vs wall" open question (`003`,
`005`) gets a real answer instead of a re-cited 24% from different hardware.
The tile-allowlist extension (`018`/`020`) remains, independent of anything
in this note, the correct next A/B — it is a weight-stream-count fix, not
an occupancy or overlap fix, and it is the only lever on this page with
code already written and awaiting a Mac run.
