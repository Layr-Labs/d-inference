# Gemma 4 expert and tensor parallel execution plan

Updated 2026-09-17. This is a working plan under the existing Darkbloom cluster
goal. The user's latest priority is a strong measured Gemma prefill result from
true expert parallelism, tensor parallelism, or their combination. The 27B work
remains part of the goal; its frozen compaction candidate is queued.

## Starting evidence

- The registered Gemma4 26B QAT4 artifact is installed on both M4 Pro Macs.
  The 32-prompt-token/two-output-token 10/20 layer split matches both full F32
  vocabulary rows and all 90 state components. It is not a throughput result.
- The experimental Gemma FFN tensor partition splits the intermediate width of
  every expert. It is not expert-ID parallelism. Tiny full-F32 cases pass; BF16
  whole-model cases retain numerical failures. Widening only a branch is not
  equivalent to the full-F32 oracle and is not qualified by it.
- The registered model has 128 routed experts/top-8, a shared dense branch,
  hidden size 2816 and 30 layers. Current expert optimizations include E=128
  eligibility; smaller local banks must not silently claim the same fast path.
- Both test Macs have the same 14 CPU/20 GPU core M4 Pro configuration but
  different memory capacities. Rank weight counts therefore cannot be selected
  from the RAM ratio alone. A 64/64 expert split is not assumed to fit.

## Implementation order

1. Add a reusable pure expert ownership/dispatch contract. Validate complete,
   disjoint global expert IDs; support unequal and noncontiguous ownership;
   describe compact axis-0 weight selections; preserve each token's original
   top-k slot and routing weight while mapping to rank/local expert. This step
   grants no native admission and invents no measured compute costs.
2. Bind those selections to the existing verified descriptor loader and
   `ModelPartitionPlan`/storage commitment. Keep whole expert inner dimensions
   and original quantization unchanged. Preserve global router semantics,
   learned expert scales, branch normalization order and tied embedding.
3. Build a one-layer numerical comparison with actual captured Gemma input and
   actual router selections. Use original expert operations first. Keep a
   reconstruction in original top-k order as the correctness reference;
   evaluate faster aggregation separately. Do not force teacher routes in a
   performance run or relax existing numerical acceptance to obtain a number.
4. Use the qualified generic window-aware CBv2 state owner for the full model.
   Reuse native lifetime, cancellation, request ordering, stream ownership and
   transport. Do not open the old Qwen-only CBv2 gate or create another owner.
   First compare short full rows/state, then cross a sliding-window wrap and
   verify fresh-request isolation and bilateral retirement.
5. Add an explicit Gemma resident benchmark adapter under a separately reviewed
   workload/resource admission. The existing short check remains bounded at
   P32/C16/O2; its flags must not be increased to bypass its resource contract.
   Begin with a real solo reference and one candidate; stage prompt lengths
   through 1K/4K/8K only when the larger shape is admitted and correct.
6. Compare whole-expert EP with replicated attention/dense work, FFN TP, and a
   selective hybrid. Attention TP requires Gemma-specific Q/K/V and quantized
   output-column selections plus original normalization/reduction boundaries.
   Treat it as a candidate, not a required addition to every layer.

## Performance decisions

Measure uncached prefill and request-send-to-first-content TTFT first. Record
decode, total latency, resident/load peaks, routing imbalance, dispatch/packing,
branch compute, collectives and numerical policy alongside the headline result.
Do not label host wait time as wire latency or compare clocks from two Macs.

Use the same artifact, prompts, output budget, precision, warmup convention and
cache state for solo and distributed controls. Screen candidates with one
warmup and three measured requests, then use the existing fixed ten-prompt,
three-measurement paired study for the chosen implementation. Include all
failures and deadline misses. At 8192 prompt tokens the specified external TTFT
deadline is 18.192 seconds; a single pass is not p95 compliance.

Select ownership from measured branch behavior and routed-token distributions,
subject to actual memory and transport costs. Account for loss of optimized
kernels, metadata widening, sorting overhead, hot experts, replication and
load transients. Static expert counts and modeled FLOPs alone cannot select
the fastest plan. Keep measurements keyed to artifact/runtime/hardware and
recheck current resource admission when a saved plan is used.

MTP off is the first matched comparison. Add MTP on only with genuine accepted
draft activity and separate draft/verification memory and timing. No Gemma TPS
target or M3 Ultra estimate is reported as measured before these runs exist.

## Current work and limits

Arithmetic agent: pure expert ownership and slot-preserving dispatch helper,
Foundation checks, and exact native expert integration gaps.
Transport agent: Gemma-specific tensor selection, collective/replication costs,
and numerical/state boundaries. Root: baseline/resource adapter planning and
review; schedules the sole compiler and any physical runs.

All current agent work is source-only. These helper checks do not establish
numerical or resource admission for a TP/EP model run. Native work retains the existing AC/pressure/zero-swap and
actual-free guards, one physical cohort at a time, and bounded TB alias cleanup.
No compiler or bulk I/O runs during physical measurements. The signed/attested
encrypted member path remains a separate qualification requirement; research
RDMA results do not establish encrypted product performance.
