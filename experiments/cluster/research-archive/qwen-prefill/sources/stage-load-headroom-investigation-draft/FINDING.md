# Selected 9B stage-0 loading: source and headroom finding

> Recorded: 2026-09-14 · source head `e4df336bc`

The original starting headroom was insufficient to retain the ordinary selected
weights while preserving the all-sample 6 GiB free floor, absent compensating OS
reclaim. No hidden full-model evaluation or file-cache explanation is needed.
The source supports normal resident parameter allocation plus a transient host
copy; the interrupted run does not locate the exact tensor or execution phase.

The original receipt remains failed: native was terminated with exit -15, reaped,
and produced zero stdout/stderr bytes. In 0.272345917 seconds between saved samples
10 and 11, RSS increased 2,332,409,856 bytes; free memory fell 2,330,116,096 bytes;
anonymous-page bytes rose 2,330,591,232. File-backed bytes fell 3,571,712. These
observations support allocation into process/anonymous memory rather than new
file-cache occupancy dominating this interval. They do not identify the call
site or prove every byte's owner. Earlier 23 MB RSS samples carry no native phase
marker; their attribution to checksum work comes from root's investigation.

| Source-derived term | Bytes |
|---|---:|
| Stage-0 active tensors: 463 entries, embedding plus layers 0..<16 | 2,519,016,704 |
| Largest host tensor: packed embedding weight | 508,559,360 |
| Lazy inert logical allowance: head and norm | 16,384 |
| Initial `R + 2H + 4 GiB`, using logical bytes plus inert allowance | 7,831,119,104 |
| Active resident weights plus the retained 6 GiB free floor | 8,961,467,648 |

Prelaunch free bytes were 8,486,846,464; the last low-RSS sample reported
8,427,945,984. Both exceed the logical initial gate but fall respectively
474,621,184 and 533,521,664 bytes below active weights plus the free floor.
Actual allocator rounding, host copies and other process costs add uncertainty.
These are planning comparisons under a no-compensating-reclaim assumption,
not measured allocation bounds or guaranteed memory-fit thresholds.

`QwenDenseStageLoadPolicy.evaluate` deliberately uses
`max(6 GiB, remaining R + 2H + 4 GiB)` at each ordinal. Its initial pass does not
promise later samples can pass. While weights become resident, `R` shrinks and
the fixed floor eventually dominates. All limits correctly remain enforced.
If avoiding such early admissions becomes necessary, a prospective stricter
screen can also reserve `R + 6 GiB`; it would be an earlier refusal policy,
not a memory-safety proof. No gate change is proposed for the improved-headroom run.

The relevant source mechanisms are:

- `TensorDescriptor.read` creates one `Data(count:)`, fills it from the verified
  descriptor, and calls `MLXArray(Data, shape, dtype:)`. The C bridge reaches
  `array::init`, which allocates separate MLX storage and copies exactly the typed
  elements. The Metal allocator uses shared buffers. Data and native storage
  overlap during copying; the returned array does not retain the Data or file.
- `materializeVerifiedQwenLayerStage` evaluates and synchronizes each active
  array, checks its exact owned allocation, then installs it in the model. Active
  arrays therefore accumulate until owner release. Exact 9B U32/BF16/F32 storage
  is preserved; its F16 conversion branch is unused. It never calls `eval(model)`.
- The full source constructor and unselected compact constructor leave their
  weak-checked scopes before selected payload loading. Inactive selected head/norm
  defaults are replaced before quantization. `QuantizedEmbedding` and
  `QuantizedLinear` construct lazy quantization graphs; `affine_quantize` creates
  unscheduled multi-output arrays. `Module.update` reaches `_updateInternal` and
  `mlx_array_set`, which replaces array descriptors without evaluating the old
  defaults. Random-state scope exit also adds no evaluation. The reviewed path
  contains no source trigger for evaluating a hidden full default model.

Root subsequently reported an unchanged-native retry after materially improving
free memory: native exit 0, all 463 weights loaded, MLX active 2,519,019,796 bytes,
MLX peak 2,519,019,800, released active 2,016. That is consistent with ordinary
selected residency; this investigation did not read or independently audit that
new report. Its separate parent `<defunct>` exit-sampling failure remains a
different issue. No loading fix, allocator-copy change or further OS profiling
is justified by this finding. Existing native numerical/ownership qualification
and the parent race correction retain their own evidence.

`evidence-and-arithmetic.json` binds the original failed receipt, retained metadata
and extracted sample arithmetic. `source-pins.json` binds 11 archived application
files and 14 dependency files checked against the run's exact submodule Git
objects. No repository mutation, compiler, native/SSH invocation, model payload
read or new retry candidate access occurred.
