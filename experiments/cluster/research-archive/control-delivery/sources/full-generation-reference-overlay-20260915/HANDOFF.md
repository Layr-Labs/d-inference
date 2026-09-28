# Full-model greedy generation reference

`runQwenGenerationReference(loaded:admission:admitResources:check:)` is an internal
request helper on the existing, already owned `LoadedModel`. Five additive Swift
files and one small `CBv2RequestSession` change live in `Sources/`; `runtime.patch`
targets the frozen experimental harness. There is no new CLI, model loader,
provider interface, transport or generated expected output.

The admission binds the actual generation request to the existing registered 9B
configuration/artifact/arithmetic/8192-ID prompt admission and its selected Plan.
It permits 1...128 requested target tokens at the existing chunk 512 geometry.
For output 128, capacity is 8320; sixteen prefill frames and 127 decode frames end
at committed frontier 8319. The final selected token is not consumed. EOS takes
precedence over length and stops without a further decode. An actual failed
request uses cancellation; EOS uses the new typed clean completion before the
unchanged retirement body. Existing fixed-output session callers retain their
exact close condition and forward implementation.

The helper uses full-model `CBv2RequestSession.prefillChunk/decode`, independently
from the staged driver. Every target row is finite native argmax, copied through
existing `QwenRecordedLogits`, then cross-checked against the first maximum of
the complete CPU row. Results contain selected IDs and their token hash,
per-token frame/frontier/shape/dtype/native-row hash/argmax evidence, one final
complete row, and one existing `QwenRecordedState` snapshot at the actual final
frontier. No MLX array/session/model/FD escapes. Only the request is retired;
the passed model remains owned by the caller.

Loading, exact source revalidation and the mandatory live `admitResources`
callback precede the request clock. First selection time precedes the first CPU
row capture. Later selection times include prior evidence work; final retirement
time also includes the final row/state capture and request cleanup. These are
correctness-run diagnostic clocks, not external TTFT or comparable decode TPS.

For registered 9B/O128, the existing conservative named tensor formula is
recomputed at 8320: 754,188,320 B, below the unchanged 768 MiB ceiling. The old O1
745,345,056 B receipt is provenance only. Additional named capture terms are at
most two CPU rows (2,979,840 B) and one temporary Float32 conversion row of 993,280 B.
These are logical terms, not allocator/RSS bounds. The owner must still derive
actual allocator bounds and allow active weights, first-use GDN fusion, unknown
native workspace, process overhead and its existing headroom. Apply real OS,
zero-swap, AC/thermal and absolute-deadline checks before allocation and during
`check`; retain the existing 6 GiB minimum. The callback has no permissive default.

## Existing launcher hookup

At `QwenLongPrefillReferenceProducer.swift:17`, retain the existing scoped
`loadVerifiedQwenLayerStageBaseline` call, its verified aggregate/raw config,
outer synchronization/weak-model release/error cleanup and hard parent deadline.
Inside that loaded-model scope, construct `QwenGenerationReferenceAdmission`
from the exact same `QwenLayerStageGenerationRequest` used for the physical
driver and its source admission, then invoke this helper instead of the old
output-one request helper. Keep the new result schema; do not encode it as the
old `QwenLongPrefillReferenceEvidence`. The existing cached full-reference loader
is unchanged; aligned selected-stage IO is not claimed for this full load.

The native helper takes the actual harness `LoadedModel`; the shared resident
facade currently owns only stage models. No public arbitrary model callback or
new shared full-model ownership is implied. Root should integrate the six files
with the existing generation contract files, then add the bounded launcher call
in its isolated build and supply the actual resource callback.

The current physical `QwenLayerStageGenerationResult` supports exact comparison
of the request/agreement identity, selected IDs, finish reason, completed frames
and committed frontier. Its token-chain hash has a different, agreement-bound
recipe and is not compared to the reference's plain token-ID hash. Full state
and logit parity additionally requires a candidate capture hook before stage
retirement; this helper does not invent those missing observations. Per-token
digests permit exact comparison if captured later; only the final complete row
supports numerical tolerance analysis from this result alone.

`foundation-source-list.json` pins 24 CPU-only sources and the existing retained
3118-byte config. `Tests/ReferenceCheck.swift` tests real pure admissions and
completion logic with invented token histories, not model outputs. Native
forward, resource checks and physical comparisons remain unexecuted here.

Validation: Swift6 `-warnings-as-errors` compiled those 24 sources in 3.692 s;
the fixture passed 7 positives/24 rejections in 0.377 s, all stderr empty and
source/input pins unchanged (`cpu-v1/execution.json`). All six runtime sources
also passed syntax parsing; native typechecking remains pending. The mechanical
source check restores the complete old `CBv2RequestSession` bytes by removing
only the completion flag, typed finish method and added close-condition term.
