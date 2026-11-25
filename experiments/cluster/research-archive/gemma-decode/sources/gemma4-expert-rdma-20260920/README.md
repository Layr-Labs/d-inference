# Registered Gemma one-layer expert RDMA check — 2026-09-20

This is a new source-only executable path over the existing whole-expert primitive. It has not been compiled or run. It changes no MAIN, vendor, resident benchmark, or frozen expert source. No two-Mac EP correctness or performance is claimed.

Apply the ten required `gemma4-expert-native-20260920/Runtime` additions, then this directory's eight Runtime additions and Entry according to `integration.json`. The only replacement is an additive Package product/target insertion for `GemmaExpertRDMACheck`. The package beforeimage currently contains `GemmaResidentBenchmark`; if the separate `GemmaExpertAxisCheck` target is applied first, compose both additive insertions explicitly instead of overwriting its changed Package. Preserve exact proposed bytes and the root-owned full compiler source/dependency inventory. The existing primitive is reused unchanged; its prior source readiness is not treated as native qualification.

## Actual algorithm

The two ranks use the same registered checkpoint, global layer0..<30, epoch, request UUID, native build identity, token-count list, ownership map and original300-second-or-shorter lifetime. Scope agreement binds all shared values before source loading. Rank0 is authoritative for route replay and the unsplit numerical reference. Each rank loads only its own increasing expert IDs using the existing axis-zero selected reader. Rank0 additionally loads the full128-expert reference bank and the actual router/sparse pre/post-norm weights; rank1 does not. This extra one-layer reference is diagnostic and must never become a model-serving replication claim.

For each token count in a nonempty sorted subset of1,7,8,9,33:

1. Rank0 creates the exact existing deterministic residual fixture, executes the actual checkpoint router replay, and explicitly reads selected IDs back to CPU. The existing learned scaling/precise selected-logit softmax and weights are unchanged. This is a qualification fixture, not a device-only routing implementation or a full decoder activation.
2. Both ranks admit the same bounded token-major top8 IDs and their ownership through the existing ExpertDispatchPlan. Source/job/route identities, exact rows, original slot order and weights hash are agreed. Rank0 transfers the actual BF16 normalized expert input over completed JACCL send/receive.
3. Each rank gathers its own token rows and calls its unchanged full-width quantized SwitchGLU bank. The rank1 result is an unweighted `[assignmentCount,2816]` tensor. Empty local work creates no expert projection or zero-sized transfer.
4. Rank1 transfers those rows back. Rank0 joins rank-major results, gathers the existing plan's permutation, and restores `[tokens,8,2816]` in the original top-k slot order. It calls the exact unchanged weightedExpertSum and checkpoint sparse post-norm. It never sums rank-weighted partials.
5. Compare exact bytes at raw per-expert output, weighted boundary and sparse post-norm. Preserve hashes, maximum absolute error and relative RMS as diagnostics. A mismatch still completes bounded cleanup and produces a failed report; no tolerance widening or token-only acceptance is built in. Rank1 records the exact rank0 result digest and outcome as a peer observation, not as its own independent comparison.

The wrapper `ExpertAxisRDMADispatch` uses the original PreparedDispatch/plan public interface; no existing dispatch file changes. It constructs only its local row/local-ID tensors plus original-slot gather indices. Projection/reassembly themselves contain no host tensor read, eval, I/O, synchronization or normalization. The surrounding numerical fixture evaluates, checks and reads results explicitly.

## Contract and resource limits

`job-template.json` is illustrative. Root must replace its example UUIDs and zero build hash with fresh/observed values. Rank-specific model paths may differ; exact registered source content remains independently verified at both endpoints. Allowed maps are contiguous48/80 and strided43/85. Both preserve full2816→704→2816 projections and affine W4/G64 expert leaves. All shared fields except rank/path enter the scope hash. Runtime additionally requires the actual JACCL group to be exactly two ranks and match the selected rank.

Controls are strict Codable/unknown-field-reject packets with exact sender, original scope and monotonically increasing ordinal; cap128 records per direction and32KiB per record. All expected tensor geometry is derived locally from the admitted route before receive allocation. Each tensor is BF16 and capped at2MiB; the largest possible output is264×2816×2=1,486,848 bytes. It receives an exact payload digest and a completed send/receive/consumed handshake. Source output is copied into owned compact native storage and retained through the peer's consumed acknowledgment. No ciphertext/authentication claim is made: this reuses the existing raw checksummed layer-test transport on the controlled testbed.

The existing one-layer resource checker conservatively charges full reference plus BOTH local banks on each rank, even though actual rank storage is smaller. Add16MiB native and16MiB host staging allowance without taking a bank discount. MiB=1,048,576 bytes, GiB=1,073,741,824 bytes. The original6GiB actual-free floor,4GiB loading/workspace reserve,2GiB allocator headroom, pressure1, zero swap, AC, normal power and nominal/fair thermal gates remain. The freed-buffer cache is disabled and observed zero. Actual group allocation is followed by another resource check before checkpoint reading. This is diagnostic admission, not a measured serving floor or whole-process bound.

One collective is reused for the entire job; source/model and case arrays stay inside the original autorelease scopes. On successful completion all weak ExpertAxisBank references must be nil before the bilateral banks-released checkpoint. The collective must then be weakly released, streams synchronized, native errors checked and cache zero before final report. SIGALRM remains active through stdout. Any execution/native/deadline error fails closed and leaves the original root-owned supervisor responsible for peer cancellation, process-group fencing/reaping and canonical lease cleanup. A Swift report alone never establishes physical cleanup.

## Smallest qualification sequence

Use the existing root-owned cloned build/cache and compiler flags, not another model/request framework:

```
swift build --package-path /Users/developer/DarkbloomDev/cluster-research/gemma4-execution-20260920/build/workspace/libs/darkbloom-cluster-worker --scratch-path /Users/developer/DarkbloomDev/cluster-research/gemma4-execution-20260920/build/workspace/libs/darkbloom-cluster-worker/.build-native-worker -c release --jobs 2 --disable-automatic-resolution --skip-update --disable-build-manifest-caching --triple arm64-apple-macosx26.2 -Xcc -target -Xcc arm64-apple-macosx26.2 --product GemmaExpertRDMACheck
GemmaExpertRDMACheck --check-local
GemmaExpertRDMACheck --describe /absolute/job.json
GemmaExpertRDMACheck --check-arguments /absolute/job.json
```

The seven local groups call the actual job/packet/route decoder and pure ownership plan. They cover both maps/common scope, unknown/bounded job fields, empty ranks/mixed-slot permutation,264-assignment envelope, duplicate/out-of-range/stale route, wrong direction/scope/replayed/exhausted ordinal, malformed/truncated/oversized packets. They execute no MLX tensor, source payload read or collective. They are staged, not yet run.

After root source review, successful native compilation, actual resource-bundle pins and the local controls, use its existing strict-key two-Mac/canonical-lease/process-group supervisor to run identical source-bound jobs differing only in rank/local path. Add the new executable name to exact native process inventories. Reuse the known JACCL configuration/rendezvous setup. Root must inspect the real registered one-layer primitive comparison before accepting the distributed result. First use layer0/contiguous48_80 and small token counts, then all five sizes/strided map and representative sliding/global layers if admitted. No broad kernel/backend switch follows automatically.

Both terminals must exit0, preserve one bounded JSON report (maximum2MiB), match original job/scope/build/source/maps/case indices, and prove banks/group/cache cleanup locally plus actual parent process/lease/resource cleanup. Cross-join rank0 send bytes with rank1 receive bytes and vice versa, input/route/weights/result/returned-output digests, and local selected-byte counts against exact128-expert source conservation. Rank0's actual three numerical comparisons must pass every case. A rank1 peer-success observation cannot substitute for that report. Failed numerical reports exit2; execution failures exit1; the alarm exits124.

No request/model lifetime framework, saved cluster attachment, native production approval, public route, encrypted transport, full-decoder EP, device-only dispatch or throughput claim is added. Those follow from measured numerical outcomes and an explicit later expert-call integration.
