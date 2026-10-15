# Larger-prompt admission successor (source only)

The shared qualified Gemma planner already accepts every cut1..<30 and maps exact global layers, full/sliding attention and tied embeddings. The benchmark had an independent explicit allowlist8/10. This successor adds only cuts6/7 and chunk64 to the existing benchmark admission sets. Existing cuts8/10 and chunk128 remain. No resource term, F32 ceiling, all-layer simultaneous charge, allocator bound, free floor, cache policy, AC/thermal/pressure/swap check, lifetime or cleanup gate is reduced. Production serving stays unchanged.

Two Runtime replacements are pinned against frozen9dc18. No candidate/workspace or frozen source is modified. Argument case generator now stages20 actual-entry cases, including positive cuts6/7 and chunks64/128; chunk32 remains refused. No compiler, metadata executable or native execution ran here. Root must apply exact preimages, rebuild the same product, run all20 cases and bind the new native hash before deployment.

`project_budget.py` reads retained config/header metadata only and independently reproduces36 reported values in six actual native P128 target descriptions (full/stage0/stage1 atcut8/10). It then computes the unchanged logical arithmetic for higher prompts. It is not actual allocator admission; every tensor still receives live native allocation rounding. `projection.json` and `chunk64-projection.json` are prospective byte totals, not physical measurements or source payload verification.

All numbers below are decimal GB (1GB=1,000,000,000B); resource floor units remain binary GiB (1GiB=1,073,741,824B). With capture=true:

| Prompt/chunk | Solo pre-load lower bound | Cut6 rank0 / rank1 lower bounds |
| --- | ---: | ---: |
| P1024/C128 |28.446GB|10.056 /23.871GB|
| P4096/C128 |31.604GB|10.687 /26.397GB|
| P8192/C128 |35.814GB|11.529 /29.765GB|
| P8192/C64 |32.274GB|10.818 /26.933GB|

Current root-reported fresh actual free12,925,632,512B /33,419,165,696B precedes pair JACCL allocation and is not a promise of later admission. In the observed cut8 failure, initial admission required11,280,046,277B versus a logical11,250,515,568B; allocator rounding alone accounted for29,530,709B of that difference. Do not discount JACCL/OS changes or compare a pre-group free sample to a post-group load gate.

Fastest supported qualification path: retain completedP128/cut8 evidence; try P1024/C128 at the largest described cut that still passes actual post-JACCL admission, withcut6 providing greater margin if8 is too tight. ForP4096/C128,cut6 has more margin than7/8. FullP8192/C128 requires35.814GB before rounding and cannot be assumed to fit the reported33.419GB free48GB Mac. P8192/C64 lowers real chunk-dependent allocation requirements while preserving the formula; its new solo/pair numbers are only comparable at the sameC64. Usecut6 initially for that cohort. These are workload/admission suggestions, not TPS or optimum-partition predictions.

Every new prompt/chunk/cut tuple needs the same actual solo-versus-pair qualification: all16 token IDs and exact final row plus all state component bytes for each fresh-state request, original source/build/Plan identity, original resource gates and actual process/lease cleanup. At8K sliding windows have wrapped; validation must use logical ranges/global layer IDs and all returned bytes. Capturefalse timing follows same-tuple numerical qualification. The existing300-second whole-job bound remains; a timeout is a failure, not authority to extend it.

Chunk64 remains inside all fixed protocol/evidence caps: atP8192 it has128 prefill+15 decode frames; the busiest direction remains below512 controls perrequest. Dynamic schedules, owner geometry, diagnostic binding and per-frame IDs already useactualC/P/O. Sidecar state capacity remains based onP+O, not chunk; no disk cap is raised. The old fixed P32 harness and its evidence remain untouched.
