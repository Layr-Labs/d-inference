Private full-model Gemma expert adapter, source only
=================================================

Implemented
-----------

The original decoder body is shared through a rethrowing expert operation. Its attention, original global router and scales, dense branch, all normalization, residual, PLE and layer-scalar operations are unchanged. The ordinary public forward remains nonthrowing and calls the original expert operation. The original constructor signature remains callable; its implementation now delegates to a common designated initializer. No existing decoder subclasses were found. Only the explicit SPI constructor reduces the expert count; its ordinary forward refuses misuse. The EP hook returns unweighted original top-k slots. The SDK, holding the actual router weights, calls the existing `weightedExpertSum` before the original post-expert normalization. No rank-weighted partial sum is introduced.

The new SPI full-model wrapper has 30 original decoder layers, original mixed-window caches, embedding and tied head/final norm on BOTH ranks. It reuses `gemma4LayerPrefillPolicy`, original decoder attention/cache and final norm/head/softcap ordering. It never constructs another request owner, group, stream, checkpoint reader, or admission permit. The loader continues through `Gemma4RegisteredSource` and `materializeRegisteredGemma4`: existing source identity/cache bypass, per-tensor pre/post callbacks, compact ownership/read accounting, and final inventory checks. The selected descriptor now carries axis selection, selected shape and bytes. Exactly270 expert tensors are read as axis0 packed ranges; the remaining1069 text tensors are replicated unchanged. Ordered-load matching now includes selection/shape/bytes so a whole bank cannot substitute for an authorized selected bank.

`Gemma4ForwardModel`, the actual probe, and `Gemma4OwnedForwardSession` accept explicit EP operation objects. Probe and request purpose are distinct. The session joins the operation to the actual request UUID/fingerprint, loaded artifact/configuration and exact partition before reserving state. Errors thrown after a decoder cache write propagate through the same `state.run` and unchanged failed-retirement body. No successful frontier commit follows a thrown operation. The outer native fault check remains authoritative.

`Gemma4ExpertCollectiveOperation` is concrete route/readback, local projection, returned-row validation and original-slot reassembly code. It uses actual evaluated router IDs/input/weights, the existing pure ownership/dispatch mapping and exact shared projection policy. It computes only owned experts, strips padding before exchange, and retains local output through the synchronous exchange/consumed-ACK boundary. This correctness-first CPU readback is explicitly not device-only or a performance claim. The supplied exchange receives an exact rank-independent request/epoch/build/ownership/frame/layer/route/input/weight scope; peer output scope/rank/shape/type must match. SDK weighting remains outside that exchange.

Not activated
-------------

This is a coherent constructor/selection/hook/owned-session slice, not a completed physical EP runtime. Both existing operational budgets explicitly REFUSE the EP target. No CLI or job mode enables it. The `Gemma4ExpertUnweightedExchange` still needs a concrete implementation on the already-owned Collective; this draft intentionally creates no alternative wire, group or owner. Full-model EP has not compiled, run or been numerically qualified, and no throughput/fit claim follows from the one-layer results.

The remaining work is specific:

1. Extend the existing resource owner/budget for both full30-layer KV replicas and all selected-weight F32 cast retention, constructor/probe/high-water, kernel padding, router readback, assignment arrays, local and received unweighted rows, compact sender/receiver buffers and reassembly graph. Charge actual selected shape/bytes throughout ordered loading (the present owners still use source bytes and refuse EP). Max1024 assignments is not a byte ledger. Preserve existing6/4/2GiB/zero-cache/pressure/AC/native-fault/deadline inequalities and the independent physical supervisor.
2. Implement the narrow exchange using the same Collective and exception/poison path. Both ranks compare scopes before accepting rows; deterministic rank0-send-first/rank1-receive-first, completed send/receive, bounded payload, consumed ACK and retained buffers are mandatory. A failure must poison that owned group and reach the original request retirement. Probe uses a distinct purpose; build/epoch trust still comes from the existing owner/handshake, never from these supplied scalar fields alone.
3. Use separately bound probe operations for actual prefill2/decode1. Then a single request operation per admitted session; authenticate both rank builds/epoch/partition and ensure all layer/frame ordering and terminal bilateral ACKs before owner release. Existing control/schema must distinguish every replicated full state from pipeline rank-union evidence.
4. Qualify the already-staged root C64/128 projection extension independently before using long chunks. First full-model comparison should be P32/C16/O2 against an ordinary full reference, both48/80 and43/85. Compare all selected tokens, both final full rows and every full90-component state for EACH rank, not a union of partial stage states. Inject wrong scope, missing peer, mid-layer thrown exchange, native error and deadline; prove no successful commit/report and actual original cleanup. Only then matched longer correctness and timing.

Selection arithmetic (stored bytes only)
--------------------------------------

All1339 selected parameter names remain present on each rank. Expert bytes per owned ID across30 layers are100,362,240. Replicated text bytes are1,621,321,788. Thus48/80 stored totals are6,438,709,308 /9,650,300,988;43/85 are5,936,898,108 /10,152,112,188. These are metadata sums, excluding cast/cache/KV/workspace/host/transport allocations. Neither map is a memory admission or measured placement recommendation.

Composition and controls
------------------------

`source-inputs.json` gives17 overlays and exact preimages; `runtime.patch` is the complete delta. No ExpertAxis file is changed. The required root projection-limit source is `gemma4-expert-prefill-bound-20260920` manifest96b09205616dc075d0efb09c6962a630f7e88ba14ee8a7b76e6613fe34b44a06. Its new bounds are source dependencies, not an asserted physical PASS. A later describe-only successor can be composed independently.

IMPORTANT: the saved BenchmarkResourceBudget is the prior qualified pre-metrics preimage. Apply ONLY its3-line EP refusal case onto the metrics/consolidation budget; do not overwrite the32768-byte guard reserve or any newer reviewed work. The ShortResourceBudget refusal and common ordered-load match are otherwise disjoint. Runtime/native sources and binaries in the applied workspace remain untouched by the author.

`Tests/check_source.py` executes only source/pin comparisons and proves the decoder math inverse, unchanged ordinary router/trunk/full-model bodies, unchanged final session retirement, unchanged loader callback/sync/error checks, and exact3-line budget refusal deltas. That check was run by the author. No compiler, Swift control, GPU, native, model, remote or physical execution was performed.

`Tests/PartitionChecks.swift` stages10 Foundation groups for both unequal maps, global/local inversion, original slot restoration at1/33/64/128 tokens, duplicate/missing/out-of-range/unsorted owners, assignment cap and substituted returned mapping. It uses actual existing ownership/dispatch files, no MLX mock.

`GemmaExpertModelCheck --metadata <retained-metadata-directory>` stages actual retained config/manifest/header admission, all1339 names/shapes/dtypes/bytes for four ranks, exact expert-selection versus replicated arrays, selection-substitution rejection in the actual ordered loader, and explicit existing budget refusal. This mode creates no model or tensors. Compile and run commands are in `commands.json`; root must apply source with preimages and use its existing bounded compiler wrapper first. No future native SHA is guessed.
