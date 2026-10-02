# Isolated cluster inference probe

This executable runs Qwen3.5-family and Gemma 4 text inference on local model files. It
does not connect to the coordinator or start a provider. It supports a single
device baseline and two-rank tensor parallelism. `--partition ffn` splits
feed-forward networks; Qwen's `--partition full` also splits attention and recurrent
heads. Gemma currently accepts only the FFN plan and native attention-output
precision. Embedding and output head remain replicated. MTP is disabled. These are
experimental execution plans, not qualified real-model distributed support.

The [persistent worker modes](../runtime/PERSISTENT_WORKERS.md) keep these model
loads alive across serialized JSONL requests with fresh state for each request.
Their protocol and lifecycle are separate from the one-shot benchmark reports;
streamed worker timings are diagnostic.

## Build

From this directory, run `./build.sh`. It uses the checked-out MLX dependencies
and copies the source-matched provider metallib into the executable directory.
Override `CLUSTER_METALLIB` if that library is stored elsewhere.

The script first generates an ignored SwiftPM manifest overlay under
`.generated-dependencies`. Its one manifest change enables the real MLX TCP
ring backend instead of the stub, for explicit local multiprocess correctness
tests. Sources/resources link to the pinned checkout; submodule files remain
unchanged. The overlay records both manifest hashes. Use `build.sh` so that this
generated dependency exists before SwiftPM resolves the package.

The script overrides clang's target to macOS 26.2, checks for the real JACCL
implementation in the binary, then calls its availability API. Setting only the
root package minimum or `--triple` is insufficient: SwiftPM otherwise compiles
Cmlx against its own macOS 14 minimum and silently builds the JACCL stub.

The resulting executable is `.build/arm64-apple-macosx/release/cluster-inference`.
Copy that executable, its adjacent `mlx.metallib`, and the adjacent SwiftPM
resource bundles together to another Mac. Both ranks must use the same build.

## Correctness first

```sh
.build/release/cluster-inference --mode local-parity --synthetic \
  --prompt-tokens 65 --chunk-size 32 --decode-tokens 8
```

This creates a small seeded hybrid Qwen model, computes complete output logits,
replaces its FFNs with locally executed two-part sums, and compares full-model
prefill plus teacher-forced continuation logits. It checks the actual quantized
weight slicing and recurrent cache path without requiring downloaded weights or
RDMA. It is a correctness test, not a distributed throughput measurement.

For two-device correctness, run the same synthetic prompt on a single device
with `--mode baseline --logits-file baseline.json`, then run two ranks with
`--mode ffn-tp --logits-file rank-N.json`. Use `--teacher-tokens-file` for aligned
continuation logits if comparing different numerical paths. Both ranks must
enable logit capture together and use distinct output paths. Asymmetric capture
fails the rank agreement check before timed execution.

`--synthetic-dtype bfloat16` selects a BF16 fixture; the default is `float32`.
Packed weights stay U32. BF16 converts floating parameters, including scales,
offsets, norms and A_log. The harness checks every parameter's storage dtype and
the embedding activation dtype.
The model still computes its recurrent state in FP32. This resembles the 27B
parameter dtype policy; it is not an exact artifact or a 9B dtype profile.
Fixture dtype is included in the configuration identity and report.

### Synthetic profiles

`--synthetic-profile` selects a bounded fixture. All profiles have four layers,
hidden width 128 and vocabulary 512. Qwen profiles use affine W4/G64 projections.

| Profile | Attention Q/KV heads; head dimension | GDN key/value heads; dimensions | Feed-forward geometry |
|---|---|---|---|
| `tiny` (default) | 4/2; 64 | 2/2; 128/128 | Dense intermediate 256 |
| `qwen9-heads` | 16/4; 256 | 16/32; 128/128 | Dense intermediate 256 |
| `qwen27-heads` | 24/4; 256 | 16/48; 128/128 | Dense intermediate 256 |
| `qwen-moe` | 4/2; 64 | 2/2; 128/128 | 16 experts, top-4 routing, expert intermediate 512, shared intermediate 256 |

Gemma profiles `gemma-moe` and `gemma-moe-w8` use alternating sliding/full
attention, shared KV in two tail layers, PLE width 64, and four experts with
top-2 routing. Dense and expert intermediates are 704; the shared-KV tail
doubles the dense intermediate. The mixed profile uses W4/G64 by default with
W8/G64 dense projections and routers; the other profile uses W8/G64 throughout.
These fixtures exercise family features beyond the registered 26B artifact,
whose PLE and shared-KV counts are zero. Neither fixture reproduces its complete
geometry or weights.

The 9B/27B head profiles use three recurrent layers followed by one full
attention layer. Tiny and MoE alternate recurrent/full attention. MoE routing
is present in every layer and normalizes selected top-k probabilities. Head
profiles exercise real head grouping with reduced model widths; they do not
reproduce a registered model's weights, complete shape, or quality.

The Qwen seed-only model label remains unchanged. Reports carry `syntheticProfile`
and `feedForwardKind`; non-tiny profiles also add their name to the configuration
hash. The default tiny configuration bytes retain their previous identity.
All profiles accept the same F32/BF16 floating-parameter policy described above,
including uniform BF16 A_log for Qwen. The `qwen9-heads` name does not imply exact 9B dtype matching.
Operator checks are separate fixed fixtures; use baseline/TP execution to run
the selected profile as a complete model.

```sh
.build/release/cluster-inference --mode loader-parity --synthetic \
  --prompt-tokens 65 --chunk-size 32 --decode-tokens 8
```

The loader check writes a small hybrid-Qwen checkpoint into two safetensors
files with an index and manifest. It compares directly loaded tensors with an
in-memory slicing oracle, checks compact owned buffers and source byte counts,
and repeats the checks after corrupting and deleting the source files. The
second fixture converts FP16 layer quantization metadata to BF16. The default
FFN case additionally compares complete teacher-forced model logits; adding
`--partition full` checks full-plan storage/tensors and explicitly omits that
FFN-only model oracle. Peak MLX load allocation is checked separately from
steady-state tensor bytes; it is not a process RSS bound.

For Gemma, run the metadata/coverage checks and the separate direct-loader check:

```sh
.build/release/cluster-inference --mode adapter-check
.build/release/cluster-inference --mode gemma-loader-check --synthetic \
  --synthetic-profile gemma-moe --partition ffn
.build/release/cluster-inference --mode gemma-loader-check --synthetic \
  --synthetic-profile gemma-moe-w8 --partition ffn
```

The adapter check uses constructed production-shaped metadata without allocating
model arrays. The loader check verifies both unequal rank shards against an
independent tensor oracle, their owned buffers, FP16-to-BF16 metadata conversion,
and rejection of corrupt sources. It does not compare model logits. See the
[Gemma runtime validation](GEMMA_RUNTIME_VALIDATION.md) for whole-model results
and the unresolved BF16 numerical gap.

```sh
.build/release/cluster-inference --mode operator-parity --synthetic \
  --timeout-seconds 60
```

The operator suite tests the shared file-range reader, then captures the actual
Qwen attention and GDN implementations through their output projections. It
compares summed local contributions and reassembled KV/conv/SSM state over
chunked continuation, including BF16 and masked batches. A failed numerical
bound remains a failed check; a source-level argument about rounding does not
replace runtime qualification. Use the launcher examples to test complete
two-process models separately.

The suite also checks synthetic quantized expert partitions and actual Qwen/Gemma
MoE branch boundaries. These operator checks do not establish distributed MoE
model support.
Split checkpoint composition is checked independently against CPU byte values,
including both rank selections, source deletion, and malformed gate/up pairs.
See [MoE partition boundaries](MOE_PARTITIONING.md) for the expert primitive
contract, model-specific reduction points, and current correctness-check scope.

[GDN numerical controls](GDN_NUMERICS.md) records why the synthetic BF16 checks
use separate, explicit error budgets for convolution and recurrent state.
These bounds do not qualify a real artifact or its long-context quality.
The [synthetic validation record](SYNTHETIC_VALIDATION.md) identifies the tested
build, observed complete-model logit differences, coordination checks and limits.
The later [MoE runtime record](MOE_RUNTIME_VALIDATION.md) adds whole-model F32
evidence and an unresolved BF16 routing-amplification case with controlled replay.

### Router diagnostics

`--routing-file PATH` captures actual Qwen MoE router inputs and logits and
replays the stock top-k selection and score normalization. It is limited to
synthetic `qwen-moe` baseline or TP runs with zero warmups, one repetition, at
most 512 actual prompt tokens and 32 output tokens. Supply distinct routing and
logits files plus a teacher-token file. Both ranks must enable capture together.

The trace retains lazy arrays from each layer and call, including prefill chunks
and continuation. Its output binds configuration, prompt, teacher history and
partition identity. Compare identical teacher histories and verify both ranks'
routes before interpreting differences against the baseline. Capture changes
memory lifetime and can affect scheduling; it is a diagnostic experiment.

Traced reports carry `routingTraceEnabled: true`, `correctnessOnly: true` and
`throughputMeasurementValid: false`. The normal benchmark launcher rejects
these reports. No routing trace can qualify throughput or establish a numerical
acceptance budget by itself.

The mutually exclusive `--routing-replay-file BASELINE_TRACE` applies the same
workload bounds and deliberately substitutes recorded baseline router logits.
The actual partitioned hidden states still enter the experts. This isolates
routing amplification; it changes inference semantics and is never a fix or
qualification run. The replay validates baseline/workload identity, original
F32/BF16 value hashes, complete call order and live shapes. Both ranks agree on
the parsed reference's hash. Replay reports use `routingReplayEnabled: true`
and are also rejected by the benchmark launcher.

### Gemma boundary diagnostics

`--gemma-diagnostic` selects explicit chunk-by-chunk full-logit evaluation for
synthetic Gemma baseline or FFN-TP runs. Add `--gemma-boundary-file PATH` to
capture branch inputs, normalization boundaries, local/reduced FFN outputs and
router inputs/logits. Use zero warmups, one repetition, at most 128 actual
prompt tokens and 16 output tokens, a logits file and a teacher-token file.
Capture and logits paths must differ. The diagnostic is unavailable in workers.
Both ranks must agree on the schedule and whether capture is enabled before
inference; their output paths may differ.

Each forward evaluates full logits and pending captures, checks the MLX error
handler, then drains evaluated values before advancing the cache. Ordinary
cache-only preparation can prune FFN branches; retaining such lazy captures
until after the request could execute old collectives in a later forward.
The explicit schedule avoids that hazard. Captures carry native-value hashes,
complete token/call coverage and workload/partition identities. Expert IDs are
reconstructed with the stock selection operation on captured router logits;
they are not intercepted private router outputs or forced routing decisions.

Diagnostic reports set `gemmaDiagnosticScheduleEnabled: true`, optionally
`gemmaBoundaryTraceEnabled: true`, `correctnessOnly: true`, and
`throughputMeasurementValid: false`. The normal launcher rejects either Gemma
diagnostic field by presence. These optional fields leave ordinary schema-7
reports and protocol-3 workers unchanged. The
[boundary diagnostic record](GEMMA_BOUNDARY_DIAGNOSTICS.md) documents schedule
controls and observed BF16 cast amplification; it does not qualify model quality.

## Real-model baseline

```sh
.build/release/cluster-inference --mode baseline \
  --model-dir "$HOME/DarkbloomDev/models/Qwen3.5-9B" \
  --prompt-tokens 2048 --chunk-size 512 --decode-tokens 65 \
  --warmups 1 --repeats 3
```

`--tokens-file prompt.json` accepts exact token IDs and uses the file's length.
Without it, prompt IDs are deterministic synthetic IDs, not tokenized natural
language. `--teacher-tokens-file continuation.json` contains exactly
`decode-tokens - 1` input IDs. Baseline mode otherwise continues greedily for the
requested number of tokens, including after EOS; this is a fixed-work benchmark.
TP always synchronizes rank zero's argmax token. Without teacher tokens, that
selected token becomes both ranks' next input. Teacher tokens instead fix the
next inputs for numerical comparisons while output selection stays coordinated.
Local argmax choices and disagreement counts remain separate diagnostics. This
is fixed-count greedy generation, with no production sampling, streaming or EOS
termination policy.

For a bounded coordination check, launch two local ranks with the same loopback
hostfile and `--mode token-selection-check --synthetic --transport loopback-test`.
It forces divergent local logits, verifies the common selected history and
sequence reset, and rejects malformed selection frames and an invalid rank-zero
token. It does not load a model or measure throughput.

## Two-rank tensor parallelism

Launch one process on each Mac with the same command and model artifact. Set
`MLX_RANK` to 0 or 1, `MLX_IBV_DEVICES` to a JSON matrix file identifying the active
RDMA devices, and `MLX_JACCL_COORDINATOR` to the rank-zero control address and port.
The launcher must start both ranks concurrently and impose a joint timeout.
Each process additionally arms a native alarm before JACCL initialization
(`--timeout-seconds`, default 300), covering missing-peer startup hangs.
Choose `--mode ffn-tp` and `--partition ffn` or `--partition full`. The mode name
is retained for compatibility with the initial harness. The probe refuses a missing JACCL backend or a group size
other than two; it does not fall back to a socket backend or a single rank.

The explicitly selected `--transport loopback-test` is a separate correctness
mode restricted to synthetic weights. It requires `MLX_RANK` and `MLX_HOSTFILE`
with exactly two single-address ranks using distinct `127.0.0.1` ports. It does
not fall back from JACCL, and its report marks all timing as unsuitable for
cluster-throughput claims.

For Qwen dense FFNs, each rank keeps half the intermediate channels. Gate/up rows, packed down
projection columns, and corresponding quantization metadata are sliced on
aligned group boundaries. The down projection performs an all-sum on the CPU
communication stream between GPU operations. This includes the real Metal to
CPU to Metal dependencies in timing. Shard tensors are copied and materialized
so a view cannot retain the unsharded allocation.

The Qwen MoE plan retains every expert and replicates the router, while each
rank owns half of each routed expert's and shared expert's intermediate
channels. It sums the local MoE branch output before the residual. Expert
assignment is unchanged; this is intermediate-channel tensor parallelism.

The full plan preserves complete query/gate pairs and matching KV groups. GDN
uses matching key/value head groups and three separate ranges within Q/K/V
projections and convolution channels; its per-head norm remains replicated.
It reduces each local attention/GDN output projection before the residual, in
addition to the FFN reduction. Head counts change during construction; head
dimensions, grouping and quantization alignment must remain valid. Request
caches are created with each partition's local head geometry.

`ModelPartitionPlan` dispatches Qwen and Gemma adapters for construction,
tensor selection and reduction boundaries. `TensorSelection` and `SafeTensorReader` operate on physical
stored axes independently of model semantics. Their range representation also
supports disjoint segments and unequal extents on 3D expert tensors. Qwen's
separate MoE adapter specifies router replication, expert slices, and the
branch reduction boundary. Each execution binds the selected plan
into rank agreement and a schema-7 report fingerprint.

Gemma retains the global router/expert count and splits intermediate channels.
The actual 26B widths require unequal aligned splits: dense 2,112 becomes
1,024/1,088, and expert 704 becomes 320/384. Each dense and sparse branch is
reduced before its separate post-FFN normalization. An explicit per-layer
`MLX.depends` dependency orders the dense collective before the sparse one.
Attention, KV sharing, PLE, expert scales and normalization parameters remain
replicated. A common storage commitment binds both ordered rank layouts and
byte counts, with disjoint complete source coverage checked before loading.

`--attention-output-precision float32` widens attention and GDN output projection
inputs and their affine arithmetic to Float32. A full TP plan also retains
Float32 through the corresponding all-sum, then casts once to the projection's
incoming activation dtype. Baseline and FFN-only plans apply the same arithmetic
policy to their unpartitioned attention outputs. The default `native` retains
the ordinary dtype promotion and rounding. Packed weights and stored metadata
remain unchanged; existing quantized-linear caches may retain wider metadata.

FFN, router, attention score, convolution and recurrent-state arithmetic retain
their ordinary policies. This option does not force expert selections. Compare
solo/TP runs under the same numerical policy and separately measure changes
against the native baseline. Both plan fingerprints and `attentionOutputPrecision`
report fields bind the policy. Wider arithmetic and communication can cost
latency/memory; synthetic correctness alone does not justify selecting it for
real models or the M3 Ultra target.
The [attention precision experiment](ATTENTION_PRECISION.md) records improved
isolated matrix accuracy but worse whole-model agreement in two MoE seeds;
the option remains unqualified and is not selected automatically.

`--ffn-branch-precision float32` is a separate Gemma-only candidate. It preserves
the ordinary input normalization, promotes its output to Float32, and retains
Float32 through all dense/expert projections, GELU, expert weighting and the
branch collective. Each branch casts once to its incoming activation dtype
before its original output normalization. Router arithmetic is unchanged;
later expert choices can still change as preceding layer outputs change.
The solo path applies the same policy without a collective. This is whole-FFN
precision, not a down-projection-only change. Qwen currently accepts only
`--ffn-branch-precision native`.

The default remains `native`. Both the plan fingerprint and the required
`ffnBranchPrecision` report/worker identity field bind the policy. Stored weight
arrays and parameter layouts remain unchanged, but the pinned quantized layers
cache widened metadata; resident memory can increase. Float32 communication and
arithmetic may also cost latency. Compare matched solo/TP policies and quantify
the change from ordinary BF16 before considering this for a real artifact.
The [FFN precision experiment](FFN_BRANCH_PRECISION.md) records its measured
synthetic scope and remaining numerical gaps.

Real-model TP uses direct partition loading. Its constructor already has the
selected FFN and head dimensions. The loader reads only the selected ranges
into independently owned buffers, one tensor at a time, and
materializes each array before releasing that tensor's temporary host data.
There are no full-checkpoint MLX arrays or mapped-file views retaining the
unselected weights. Peak loading includes the retained local model and one
tensor's temporary copies; replicated tensors can still be large.

Direct loading requires `manifest.json`. Every declared file is freshly hashed
with a bounded streaming buffer, and the aggregate must match the manifest.
Open verified file descriptors remain pinned through loading, and file metadata
is checked for changes. Tensor shapes, bounds, duplicate names, and the optional
safetensors index are checked before use. The report records the verified
aggregate, selected/source byte counts, and largest temporary host tensor.
FFN totals include replicated routers, while `sourceShardedFFNTensorBytes`
counts only the FFN tensors selected for two-way partitioning. Loaded source
bytes equal all source bytes minus half `sourceShardedTensorBytes` for Qwen.
Gemma uses the common commitment's rank-specific selected byte count instead:
replicated source bytes plus that rank's sharded bytes. Layout hashes can differ
between ranks only as declared in this commitment.

For split expert gate/up projections, both selected pieces can coexist with
their fused local array. `largestHostTensorBytes` measures the largest individual
host read, not that combined MLX allocation or process RSS. The synthetic loader
checks do not establish the actual 35B artifact's peak loading memory.
`sourceTensorCount` additionally preserves the checkpoint tensor count when
separate MoE gate/up projections become fewer canonical runtime tensors.
All ranks must agree on that aggregate. This verifies the local manifest; the
caller must still pin it to the intended registry or other trusted artifact.

The direct loader accepts already-converted MLX `qwen3_5` / `qwen3_5_text` and
their `qwen3_5_moe` / `qwen3_5_moe_text` variants, with affine W4/G64 partitioned
projections and U32/F32/F16/BF16 tensor storage. Split MoE gate/up tensors are
read as local slices before fusion into the runtime layout. It rejects
raw HF convolution layouts that would require the whole-checkpoint norm shift.
Vision/MTP tensors are verified but omitted using the existing Qwen sanitizer.
Gemma's direct loader accepts converted `gemma4` wrapper checkpoints with
canonical `language_model.model.*` text tensor names, split expert gate/up/down
projections, and validated affine W4/W8 G64 policies. It verifies the complete
manifest while omitting sanitized non-text tensors from model loading. Raw
fused expert layouts requiring multi-tensor sanitization are rejected.
The ordinary single-device baseline continues to use the existing `loadWeights`
implementation. Synthetic TP constructs the complete tiny fixture and copies
its local partition; its transient allocation is not a direct-loader memory claim.
It uses the ordinary language-model path. The production CBv2 exact-target/MTP
kernels can bypass `Linear.callAsFunction`; they require explicit collective
integration before this adapter could be used there.

## Metrics

Standard output contains a JSON report; progress goes to standard error. Each
run has fresh attention and recurrent caches. Prefill time includes every
prompt token through the first generated token. Decode throughput counts
exactly the following `N-1` forwards, with per-token completion synchronized.
Both intervals include scalar token readback and the token-selection collective.
Each selection carries the sequence, step, vocabulary, output count and validity
alongside rank zero's token, so no extra validation collective is needed.
There is no speculative decoding, prefix reuse, or hidden extra forward.
Weight loading, warmups, rank barriers, and optional CPU logit serialization are
excluded. The reported peak MLX allocation is reset for each run and does not
include the earlier load transient. These measurements describe a synchronous
single-sequence harness, not production continuous-batching throughput.

TP runs that dump logits set `throughputMeasurementValid` to false. CPU copies
on one rank delay the peer's next collective, even though local serialization
is outside the timers. Use separate correctness and throughput runs. The
`check_logits.py` report separates numerical tolerance from greedy agreement;
add `--require-greedy-agreement` when token equality is a requirement.
Thresholds must be positive and finite and are included in its result. Logits
must be finite JSON numbers; booleans and other value types are rejected.

Compare the slowest rank's measured time with the single-device baseline for
the same model bytes, prompt IDs, dtype, chunk size, continuation, and thermal
state. Reports include timestamp, seed, prompt/teacher hashes, the effective
embedding activation dtype, FFN scale dtypes, and a hash of every parameter's
dtype and shape. Both ranks must agree on these effective dtypes and the weight
conversion policy before sharding. The configuration and parameter-layout
hashes do not verify weight bytes. Real-model direct TP additionally performs
the manifest verification above; validate baseline artifacts before comparison.
Native report schema 7 records model family, the TP storage commitment, profile,
feed-forward kind, selection policy,
selected output tokens, local argmax tokens/disagreement counts, and the actual
decode input tokens.
Teacher-forced input histories are not autoregressive generation histories.
