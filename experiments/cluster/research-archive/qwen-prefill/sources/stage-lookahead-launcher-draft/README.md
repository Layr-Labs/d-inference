# Fixed real9B lookahead launcher draft

This separate root-run draft adapts the frozen stage-rank launcher. The original
P2P, sequential stage-rank, and public generic launcher drafts are unchanged.
Preparation runs only pure/fake-process CPU tests, with subprocess and socket
creation rejected. No model payload, native binary, build, GPU task, or cohort
has been executed by this draft.

After the final native build, root supplies its exact binary hash:

```sh
python3 /Users/developer/DarkbloomDev/cluster-research/stage-lookahead-launcher-draft/launch_stage_lookahead.py \
  --release /Users/developer/DarkbloomDev/d-inference/experiments/cluster/inference/.build/arm64-apple-macosx/release \
  --runtime /Users/developer/DarkbloomDev/d-inference/experiments/cluster/runtime \
  --model-dir /Users/developer/DarkbloomDev/models/Qwen3.5-9B \
  --artifact-aggregate-sha256 127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b \
  --expected-native-sha256 ROOT_FINAL_BINARY_SHA256 \
  --input-origin /Users/developer/DarkbloomDev/cluster-research/runs/qwen9-output-boundaries-20260913 \
  --expected-inventory /Users/developer/DarkbloomDev/cluster-research/qwen-layer-stage-real9b-expected-20260913.json \
  --output /Users/developer/DarkbloomDev/cluster-research/runs/qwen-layer-stage-lookahead-20260914 \
  --timeout-seconds 180
```

Output must be new and outside the repository/model. The pinned artifact,
configuration, prior natural-text origin receipt, and independent inventory are
the same as the sequential stage run. Prompt IDs are exactly the saved natural
65-token prefix, chunk size32, output count4, with teacher IDs4087/13/271. Each
rank receives `--mode qwen-layer-stage-lookahead-check`, the real model/pin,
`--transport loopback-test`, a new shared epoch, `--execution-path
cbv2-contiguous`, staged token files,65/32/4, repeat1, warmups0, and timeout1–180.
`MLX_RANK` selects rank0/1; the copied runtime generates two distinct literal
IPv4 loopback endpoints. `DARKBLOOM_BF16_WEIGHTS=1` preserves source conversion.
The native default precision policies remain unchanged.

The unchanged archive/inputs/resource/supervision mechanisms retain all current
inference Swift, package/build/dependency pins, runtime Python/docs, launcher
files, native executable/metallib/resources, exact source/configuration/token
metadata, generated rank configuration, and stdout/stderr. Only metadata is
copied from the model. The copied runtime verifies the full original registered
artifact before and after execution; rank supervisors and the native verified
stage loader retain their own artifact checks. Current and copied source,
bundle, rank inputs/configuration, and original model metadata are rechecked.
An explicit binary pin and source snapshot record provenance; they do not prove
a reproducible build from arbitrary supplied source.

Resource admission stays at least8GiB estimated reclaimable memory,4GiB output
disk, and descriptor headroom. This inherited screen is not a whole-process
allocation bound. Pressure must remain at level0–2 and reported swap-used must
not increase before/during/after execution. Raw observations preserve their
printed precision. The parent owns a monotonic active-cohort deadline; existing
rank supervisors own and retire native process groups. Peer failure, invalid
records, memory failure, signal, or deadline retires the cohort with no retry.
Snapshot/hash/preflight and bounded cleanup are outside that deadline. The
receipt distinguishes supervisor reaping from root's independent native PID
inventory, which must be collected separately.

Each rank emits `qwen_layer_stage_lookahead_ready` followed by
`qwen_layer_stage_lookahead_report`, both schemaVersion1, worldSize2, backend
ring, transport loopback-test, matching epoch, flow `prompt_lookahead_one_v1`,
and integer envelopeVersion2. Old sequential kinds/versions are rejected.
Terminal completion, request retirement, and model release must be true;
correctnessOnly true and throughputMeasurementValid, modelForwardCompared, and
physicalTransferQualified false. The terminal retains `sourceLoad`, `request`,
and `execution`. There are no legacy top-level `frames`.

`execution` is the native `qwen_layer_stage_lookahead_request` result. The
launcher binds its local identity to every capture, its recorded fingerprint
to the exact prompt/teacher history, the frozen-teacher decode policy, six
completions,68 committed tokens, six released-original-handle declarations,
and request retirement. `execution.completions` retain the existing CPU capture
schema and consumed-ACK completion strings. Peer common source/request identity
and residual/header hashes must agree; stage-local identities may differ.
Flow/version binding plus peer hash agreement is checked here; independently
reconstructing each v2 envelope hash remains the CPU auditor's responsibility.

The launcher checks finite bounded scalar action records, consecutive ordinals,
per-record slot bounds, and declared summary counters. Rank0 declares six
produced/received frames and two prompt lookaheads; its queue maxima are bounded
by1/1/2. Rank1 must omit sender-only fields. This does not replay the entire
native action protocol or establish physical GPU overlap. The independent
auditor must validate the full action trace, source inventory, state/logit
parity, queue lifecycle, and v2 envelopes against the separately pinned
baseline and sequential records. No timestamps or throughput inference are
introduced.

Rank1 retains four full-vocabulary native BF16 logit rows as Float32 JSON
values, with native dtype/logical byte hash unchanged. Stdout bounds remain
64MiB per rank and60MiB per line; stderr4MiB while polled. Signed zero is retained
and duplicate/nonfinite JSON rejected. The launcher does not truncate values.
A successful receipt means outer execution, declared bounded accounting,
identity, resource, and cleanup checks passed. It is not an independent model
parity, physical two-machine/TB5, scheduling-performance, or production result.

CPU recipe: `python3 -m unittest -v test_stage_lookahead_launcher.py` in this
folder. The separate draft manifest binds new source hashes and new test count;
old counts and evidence remain historical. `stage_lookahead_execution.py` owns
new nested-result validation; remaining modules preserve the existing divided
archive, input, argument/record, memory, supervision, and thin CLI roles.
