# Private27B lookahead policy adapter

The sole runtime change removes the three-line serial-only rejection from the
actual989f private NativeWorkerRuntime wrapper. The existing closed policy parser,
immutable prefillPolicy, recording readiness/reserve/start, evidence publication
and retirement checks are exact. Omitted policy remains serial; unknown policy
strings still refuse. No model allowlist, product capability or MLX option changes.

The explicit native27B load configuration still selects the same registered model,
cut16 and base serial load. The benchmark recording SPI independently computes
its maximum/actual lookahead capacity and preserves policy in the reservation,
then derives/rechecks additional native and host charges at execution. This is
the same existing9B lookahead path; no scheduler/math/transport implementation is
copied. Only rank0 prepares ahead, bounded to one next prefill chunk. The source
check proves the exact three-line inverse and unchanged policy/retirement calls.
No compiler or actual lookahead request has run from this candidate.

After root review, build a new isolated worker from exact989f source/cache plus
this one-file overlay, jobs2 and owned-group bounds. Existing model/resources
stay unchanged. Bind the actual new worker SHA into both Ready templates and
prospective agreement; retain exact owner6f6c/cut16/controller/lease semantics.
Set DARKBLOOM_BENCHMARK_PREFILL_POLICY=one_chunk_lookahead_v1 in both private owner
configs. Do not replace or relabel the serial989f bundle or advertise MTP on.

First compare one P8192/C512/O128 request to the new matching full27B reference.
The numerical gate must add the existing explicit lookahead-policy/summary
checks prospectively: matching agreement policy; rank0 prepared15/max1;
rank1 prepared0/max0; no pending boundary at completion; no decode prefetch.
The current serial-only gate intentionally refuses that added evidence. Full
128-ID/final BF16 row/144-state checks stay unchanged. Once correctness passes,
reuse the model-generic timing cohort with one warmup/three measurements and
fresh identities, preserving300/120-second bounds and all failures/cleanup.

Existing resource arithmetic adds10584063B actual-free charge on rank0 and65536B
on rank1 at8K, already derived from H5120/BF16/chunk512 and actual allocator bounds.
Live admission remains authoritative. No guard or accounting term is reduced.
Encrypted-RDMA qualification and external product readiness are separate work.
