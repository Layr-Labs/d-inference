# Gemma26B tensor-parallel source map — 2026-09-17

This is a source-only inventory and unintegrated metadata-helper draft. No compiler, model payload, native process, GPU, remote or MAIN/vendor mutation was used. Small retained JSON arithmetic was recomputed. Source-byte totals, numerical qualification and measured performance are separate claims. Applicable instructions are MAIN `AGENTS.md`: small modules, original ownership/state invariants, no build artifacts. No nested instruction file was found in the inspected experiment/library paths.

The shortest correctness path is arithmetic's [whole-expert ownership/dispatch proposal](../gemma4-expert-id-dispatch-draft-20260917/REPORT.md), initially keeping attention and the always-active dense branch unchanged. It preserves each expert's full inner products and global top-k slot ordering. Existing FFN TP is implemented, but its BF16 whole-model results are explicitly unqualified. Attention head TP is a later independent candidate: its stored-weight saving is modest and it adds another collective per layer. None establishes a speedup or 24 GB fit.

## Exact existing code

Paths below are relative to `/Users/developer/DarkbloomDev/d-inference`; hashes are in `source-pins.json`.

| Existing source | Relevant behavior and reusable seam |
|---|---|
| `experiments/cluster/inference/Sources/ClusterInference/GemmaPartitionPlan.swift` | FFN only; dense2112→1024/1088, every expert704→320/384. The global128 experts, router, attention, norms and embedding remain replicated. Source layout, rank construction and numerical policy enter the plan fingerprint. |
| `GemmaPartitionLayout.swift`, `GemmaCheckpointLoading.swift`, `PartitionStorage.swift` in that directory | Original full stored shapes; affine W4/W8 G64 policy; selected row/packed-column reads, independent compact storage, disjoint coverage and exact selected-byte commitments. Reuse these checks rather than a full-model view/slice. |
| `GemmaReductions.swift`, `FeedForwardReduction.swift`, `FFNBranchPrecision.swift` | Dense then sparse reduction dependency, at their **separate RMSNorm inputs**. Summing after norms, summing dense twice, or summing both branches before their separate norms changes the model. The precision modes are explicit policies. |
| `libs/mlx-swift-lm/Libraries/MLXLLM/Models/Gemma4Text.swift` | Actual Q/K/V, RoPE, grouped attention, router and expert arithmetic; decoder post-attention norm is the missing attention reduction boundary. The always-active dense GeGLU is not a ninth routed expert. |
| experiment `Collective.swift` and `libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/Collective.swift` | Raw lazy `sum` uses CPU-stream `mlx_distributed_all_sum`; completed P2P validates exact geometry/size and fences transfer ownership. Raw sums do not provide AEAD. |
| experiment `WorkerSession.swift` / `RequestExecution.swift` | Existing persistent experimental load/request ordering, fresh request state and retire-on-error. This is not permission to bypass the qualified canonical owner/resource/lease path. |
| shared and experiment `CBv2RequestGeometry.swift` | Explicitly dense-Qwen/full-attention/uniform-KV-dtype only. Gemma must reuse its separately qualified windowed state/probe composition; do not broaden this guard to make an old worker run. |

The experiment is its own executable package, not an imported shared runtime module. Port only the selected layout/reduction/EP adapters into the current Gemma owned-forward composition. Do not introduce a parallel serving owner or state implementation. Earlier private `gemma4-registered-forward-draft-20260916` identifies concrete model/selection/owned-session seams; root's current qualified Gemma source snapshot and corrections, not that initial freeze, must be the integration baseline.

## Quantized attention and head TP

The actual retained text configuration is H2816,30 layers,Q16;25 sliding layers have KV8,D256,W1024, and layers5/11/17/23/29 have KV2,D512. There is no shared-KV tail or PLE. Full attention has K=V projection reuse, not cache storage aliasing: raw K goes through different K and V normalization and both states still exist. Full RoPE retains dimension512 and partial factor0.25; sliding dimension256/theta10000 remains unchanged. The attention scale is1.0.

For two ranks, select whole contiguous GQA groups: sliding Q8/KV4 per rank, full Q8/KV1. Gemma q_proj has Q*D rows; the Qwen helper's paired query+gate rows are wrong here. Select q/k/v output rows (axis0), with all input columns. Select o_proj input columns (axis1), preserving all H output rows. Packed weight divisors are8 for W4 or4 for W8; scales/offsets use64. Replicate q/k norm vectors of lengthD, not Q*D. Full K=V must reject any v_proj tensor. The per-head projections/normalizations/RoPE stay local; add the two o_proj partials **before post_attention_layernorm and residual addition**.

`proposed/GemmaAttentionPartition.swift` implements only that stored-selection and rank-config metadata, reusing `TensorSelection`, `ProbeError` and decoded Gemma config/policy. It rejects odd/incompatible heads, partial G64 boundaries, shared-KV configurations, unknown names, unexpected v_proj, invalid rank/layer and overflow. `Tests/GemmaAttentionPartitionChecks.swift` stages explicit original-shape/rank-range cases and refusals. They have not been compiled or executed. No plan kind, model module, flag, admission or reduction has been enabled. A future caller must retain the original plan's complete source/layout and policy validation.

## Stored bytes and live memory

`metadata-costs.json` comes from all1700 retained tensor headers/config; its metadata provenance still says payload hashes were pending at capture. This arithmetic did not reverify model payloads. Text weights total14,467,688,508 B; excluded vision/nontext1,140,925,536 B. Text comprises expert banks12,846,366,720 B, dense MLP568,719,360 B, attention624,512,000 B, router11,665,920 B, tied embedding415,236,096 B and other norms/scalars1,188,412 B.

GB below means10^9 bytes; GiB means2^30 bytes. Placement rows are source arithmetic, not measured admitted peaks.

| Algorithm | Rank0 bytes (GB / GiB) | Rank1 bytes (GB / GiB) |
|---|---:|---:|
| Existing FFN width TP |7,167,602,748 (7.168 /6.675)|8,352,688,188 (8.353 /7.779)|
| Prospective head+FFN width TP |6,855,364,668 (6.855 /6.385)|8,040,450,108 (8.040 /7.488)|
| Whole-expert EP64/64; nonexpert replicated |8,044,505,148 (8.045 /7.492)|8,044,505,148 (8.045 /7.492)|
| Whole-expert EP48/80; nonexpert replicated |6,438,709,308 (6.439 /5.997)|9,650,300,988 (9.650 /8.988)|

Attention head TP saves312,238,080 B/rank;35,840 B of q/k norm vectors still replicate. Dense TP additionally saves292,976,640 B on rank0 and275,742,720 B on rank1 versus dense replication, but introduces its own30 width-split dot products/reductions and numerical-policy obligation. Whole-expert EP has428,212,224 B/layer,3,345,408 B/expert/layer. Expert counts are not compute weights: both Macs have14 CPU/20 GPU cores;48 GB does not mean twice the compute. Actual routing, local assignment batch sizes and selected kernels determine balance.

At root's reported roughly13.5 decimal GB free before load, subtracting6 GiB (6,442,450,944 B) leaves about7.06 GB before guards or any other allocations. Even existing rank0 FFN weights alone are above that arithmetic envelope; EP48/80 is not a fit proof. Replicated KV, attention/FFN scratch, allocator slack, expanded quantization metadata, dispatch/gather rows, native registered buffers, authenticated-record copies, and evidence retention must all enter actual admission. Do not sum unrelated memory counters or subtract cached allocations speculatively.

FFN TP and EP with replicated attention replicate **all30 layers' KV** per rank; a layer pipeline keeps only its owned layers' state. Head TP halves KV heads per rank, not retained token capacity. For measured per-layer K/V byte widths `k_l,v_l`, physical capacity is `sum(capacity_l * KVheads_l * D_l * (k_l+v_l))`. Preserve each layer's measured dtypes, absolute frontier and sliding retention/physical-ring capacity. K=V does not remove the V term.

The retained MAIN [short Gemma correctness report](/Users/developer/DarkbloomDev/d-inference/docs/reports/2026-09-17-gemma4-26b-short-distributed-correctness.md) and its pinned evidence review establish actual BF16 K/V and int32 positions for native4fa7, P32/C16/O2. All90 state components total7,434,360 B at frontier33 and compare exactly with the full reference. The actual cut10 selected weight totals were5,093,977,620 /9,788,946,984 B; that is a different ownership shape from either TP or EP. Its observed minimum actual free on24 GiB was7,099,547,648 B, not a prospective EP admission bound. For longer-shape arithmetic only, keeping the observed2-byte KV types and supposing sliding physical capacity exactly1024, full-attention capacity8192 gives377,487,360 B/rank. The short run does not establish a real window wrap, long-shape peak, physical ring/chunk transient bound or a changed head-TP dtype. Bind a fresh probe and actual reservation for that candidate.

## Communication and numerical policy

Let `C` be rows actually processed at a boundary, `H=2816`, `d` the actual scalar width and `B=C*H*d`. One BF16 hidden row is5,632 B. Counts below cover a full30-layer forward with unpruned row geometry; CBv2's final-layer tail/last-query specialization can change actual shapes, so collect real counts instead of substituting this table into a throughput claim.

| Algorithm | Logical data, excluding controls |
|---|---|
| Current layer pipeline | One main B-byte residual across its cut, plus request/ACK/token/readiness traffic. |
| Existing dense+expert-width TP |60 reductions; for two ranks each direction sends60B. Bidirectional total120B. |
| Head+dense+expert-width TP |90 reductions; each direction90B when all three boundaries use the same d. Mixed precision must be counted per boundary. |
| First EP owner gather + result replication | Per layer remote returns `A_remote*H*d` unweighted assignment bytes (0…8C assignments); owner sends B-byte combined result when required. Authoritative routes and any needed input dispatch are additional. |
| Later symmetric EP assignment exchange |Each rank sends its owned assignment rows; bidirectional total8B/layer, unequal direction counts. Requires authoritative routing/agreement. Both reconstruct original slots before the unchanged weighted sum. |
| Weighted-partial EP allreduce |One B-byte reduction/layer, but a different BF16 reduction tree. Not the first EP correctness candidate. |

At C256/BF16, B=1,441,792 B (1.375 MiB). FFN TP sends86,507,520 B (82.5 MiB) **per direction**,165 MiB both ways. F32 doubles those payloads. At decodeC1, FFN TP sends337,920 B/direction before60 collective latencies. First EP's worst remote-assignment gather is11,534,336 B/layer at C256, plus1,441,792 B result replication when needed; measured routing may be much lower. These formulas do not assume half of top-8 is remote.

In the actual Cmlx source, two-rank JACCL selects deterministic fully connected allreduce (rank0 thenrank1); reduce-scatter/gather is selected only above two ranks. It posts rounded native frame lengths, not necessarily logical payload lengths. The Cmlx `stage_send` path clears unused tails; the separate `libs/mlx` source copy differs and cannot be substituted silently. Preserve actual dependency pins. The completed-transfer wrapper and native buffer ownership must cover the entire send lifetime. Ciphertext cannot be reduced: a protected reduction needs exact expected context/shape, authenticated P2P open followed by the prescribed plaintext arithmetic. Existing raw `Collective.sum` is not encrypted, and the fixed9B protected record/profile budgets do not authorize these Gemma volumes.

`GEMMA_RUNTIME_VALIDATION.md` records full-F32-parameter tiny-model agreement, but material BF16 FFN TP errors and a changed argmax. `FFN_THROUGH_NORM.md` records BF16 float32-branch9/12 exact and through-norm8/12 exact; all nonzero cases fail its stated limits, with through-norm4/96 argmax differences versus ordinaryBF16. Rank-to-rank agreement is not solo equivalence. Full-F32 model, BF16 with widened branches and nativeBF16 are separate policies. Widening adds activation/communication/cached-scale cost; it is not an automatic fix. EP avoids deliberate inner-product splitting but local banks/assignment batches can select different kernels; it still requires the first-divergence/full-row proof in the companion proposal.
