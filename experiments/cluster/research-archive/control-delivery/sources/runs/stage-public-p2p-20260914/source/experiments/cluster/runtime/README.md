# Reproducible inference launcher

`run_inference.py` stages one runtime snapshot, validates its identity on every
rank, and supervises the cohort. This experimental launcher supports solo runs,
independent replicas, two-machine JACCL and an explicitly selected synthetic
loopback test. It does not configure networking or integrate with the provider.

Build the [native inference harness](../inference/README.md) first. From the
repository root, these examples run one tiny synthetic model and the same model
partitioned between two local processes:

```sh
python3 experiments/cluster/run_inference.py \
  --spec experiments/cluster/examples/solo-synthetic.json \
  --bundle experiments/cluster/inference/.build/arm64-apple-macosx/release \
  --output "$HOME/DarkbloomDev/cluster-research/runs/solo-example"

python3 experiments/cluster/run_inference.py \
  --spec experiments/cluster/examples/loopback-synthetic.json \
  --bundle experiments/cluster/inference/.build/arm64-apple-macosx/release \
  --output "$HOME/DarkbloomDev/cluster-research/runs/loopback-example"
```

Use `examples/loopback-full-synthetic.json` with a new output directory to
exercise the broader FFN, attention and recurrent-head partition on the same
tiny model.

Output directories must be new and outside the repository, including after
symlink resolution. They contain a manifest, an immutable runtime snapshot and
per-rank stdout, stderr, configuration and optional logits. Treat these as
private: real run specifications can contain host aliases, addresses and prompt
tokens. Remote runs retain a unique directory beneath
`~/DarkbloomDev/cluster-runs/` on each selected SSH host.

## Run specification

The JSON schema is deliberately small and rejects unknown fields. See
`configuration.py` (`validate`, `rank_configuration`) for accepted values and
bounds. `backend` selects one of:

| Value | Execution |
|---|---|
| `solo` | One local or SSH process with an unpartitioned model |
| `replicas` | Two to eight independent unpartitioned model processes |
| `jaccl` | Two distinct SSH aliases using the configured RDMA devices and coordinator address |
| `loopback-test` | Two local processes using the TCP ring; synthetic fixtures or explicitly bounded real-model correctness; timings cannot qualify cluster performance |

The top-level `partition` defaults to `ffn`. Cooperative backends also accept
`full` for Qwen, which partitions attention and recurrent heads along with FFNs. Solo
and replica runs keep the unpartitioned model and reject `full`. Native reports use
schema version 9: cooperative reports must name the requested partition and
agree on its plan hash; baseline reports use `partition: "none"` and omit a plan.
Saved schema version 1/2/3/4/5/6/7/8 reports remain tied to their original launcher snapshot.
Native router capture/replay and Gemma boundary diagnostics are outside this run
specification; reports carrying `routingTraceEnabled`, `routingReplayEnabled`,
`gemmaDiagnosticScheduleEnabled` or `gemmaBoundaryTraceEnabled` are rejected
even when their timing flags otherwise appear valid.

The workload's `execution_path` is explicitly `ordinary` by default.
`cbv2-contiguous` selects dense Qwen's production model/state interfaces through
the native [CBv2 request path](../inference/README.md#execution-paths). Synthetic
support is limited to `tiny`, `qwen9-heads` and `qwen27-heads`; real reports and
worker readiness must identify dense Qwen. Prompt plus output count is at most
32,768, output count at most 4,096, and the actual model context may be smaller.
Both paths require the same explicit value across every rank, report and worker
identity. This is separate from transport and partition selection. It does not
enable the production scheduler or paged backend.

Each rank declares `location` (`local` or `ssh`), plus `host` for SSH and
`model_directory` for real weights. Real runs also require the expected
`artifact_aggregate_sha256`; each rank freshly checks its model manifest and
every listed file before inference. SSH must already work noninteractively.
The launcher does not install credentials or enable RDMA.

Top-level `local_correctness: true` explicitly permits real dense Qwen on the
local loopback backend under the native
[bounded correctness contract](../inference/README.md#bounded-real-model-local-correctness).
It requires exact prompt IDs, teacher history for multiple outputs, full logit
capture and the expected artifact aggregate. Metadata is checked before staging,
every artifact file before native launch, and native storage bounds before
selected tensor reads. The report validator also requires complete finite logit
files with the admitted shape and reported local argmax. A capture or identity
failure invalidates execution verification. This option cannot be used by
`PersistentCohort`; absence preserves the real-loopback rejection.

The workload specifies prompt length, chunk size, output length, warmups,
repetitions and seed. Optional `prompt_ids` supplies the same exact token IDs to
every rank, derives the prompt length when omitted and rejects an explicit
length mismatch. Without it, the harness generates deterministic synthetic IDs,
even when model weights are real. Representative-text qualification requires
tokenized prompts, not those generated IDs.

Synthetic workloads accept `synthetic_dtype: "float32"` (default) or
`"bfloat16"`. The choice is passed identically to both ranks and bound to the
fixture configuration, parameter layout, and actual embedding/FFN scale dtypes.
BF16 floating parameters coexist with U32 packed weights and FP32 recurrent
state. `synthetic_profile` selects `tiny` (default), `qwen9-heads`,
`qwen27-heads`, `qwen-moe`, `gemma-moe`, or `gemma-moe-w8`. The head profiles retain small hidden/FFN widths
but use the corresponding artifact's attention and recurrent head counts; the
Qwen MoE profile uses 16 experts with top-4 routing. The Gemma profiles use
four small MoE layers and vocabulary 512; `gemma-moe` selects mixed W4/W8
quantization and `gemma-moe-w8` selects W8 throughout. Both use G64 groups,
accept Float32 or BF16 floating parameters, and support FFN partitioning with
native attention output precision. Their distinct model labels bind the
quantization profile. See the native harness's
[profile geometry](../inference/README.md#synthetic-profiles). Each rank receives
the same explicit profile. Reports must match the requested profile and its
`feedForwardKind` (`dense` or `moe`); configuration hashes bind the geometry.
Real-model workloads reject both fixture-only options.

Qwen workloads accept `attention_output_precision: "native"` (default) or
`"float32"`, forwarded explicitly as `--attention-output-precision` to every
rank. The Float32 candidate computes attention and GatedDeltaNet output
projections and their reductions in Float32 before casting back to the original
activation dtype. It preserves FFN and router semantics. This experimental
policy applies to synthetic and real weights; it is not a numerical-quality
qualification. Compare solo and partitioned runs with the same explicit policy.
Every schema-9 report must include `attentionOutputPrecision`, match the
requested workload, and agree across ranks. Existing logit acceptance bounds
remain unchanged.

Dense Qwen workloads also accept `ffn_output_precision: "native"` (default) or
`"float32"`, forwarded explicitly as `--ffn-output-precision`. This widens only
the FFN down projection and its reduction before one cast back. Gate/up
projections and SILU remain unchanged. Every schema-9 report and protocol-5
worker identity requires `ffnOutputPrecision`; peers and workload must match.
Gemma and Qwen MoE reject the nonnative value, including native model validation
for real checkpoints. The option works with ordinary and `cbv2-contiguous`
dense execution, separately from attention precision. Compare matched solo/TP
policies and also quantify departure from native arithmetic; the
[numerical record](../inference/QWEN_OUTPUT_PRECISION.md) does not qualify quality
or throughput from synthetic agreement.

Gemma workloads additionally accept `ffn_branch_precision: "native"` (default)
or the experimental values `"float32"` and `"float32-through-norm"`, passed
explicitly as `--ffn-branch-precision` in both one-shot and persistent modes.
The `"float32"` candidate widens each FFN branch after its
ordinary input norm, retains Float32 through projections, expert weighting and
branch reduction, then casts before the original branch output norm.
The `"float32-through-norm"` candidate also retains Float32 through each
branch's own output RMSNorm, then casts back to the incoming activation dtype.
For MoE, this cast precedes the dense-plus-routed branch addition; the common
FFN norm and residual retain their existing dtype. Both candidates preserve
separate branch reductions and norms, stored parameters, and the existing
attention and router selection policy. The existing `"native"` and `"float32"`
semantics are unchanged.

Use the same explicit FFN branch policy for solo and partitioned comparisons.
These are experimental Gemma candidates for synthetic or real weights, not
numerical-quality qualifications. Qwen synthetic workloads reject both
nonnative choices before launch; for real
weights, native loading and report/ready family checks enforce that restriction.
Schema-9 reports and protocol-5 worker identities require `ffnBranchPrecision`
to match the workload and every peer. Its default remains explicit `native`
for Qwen as well. Parameter storage commitments and logit acceptance bounds
are unchanged. Clients that do not recognize a policy reject it rather than
substituting another policy.

Cooperative runs select rank zero's argmax through an explicit collective, then
feed that same token into both ranks. Optional `teacher_tokens` contains exactly
`decode_tokens - 1` IDs and overrides continuation inputs for controlled logit
comparisons. Selection remains coordinated in teacher mode. The benchmark uses
a fixed output count, including after EOS; it does not implement production
sampling or streaming. A prefill-only run uses `decode_tokens: 1`.

Use `capture_logits: true` for correctness comparisons and compare each
partitioned run with a matching solo run through the native harness's
`check_logits.py`. A successful process exit or a complete report alone does
not prove numerical correctness or acceleration.

## Identity, cancellation and evidence

The separate [persistent worker prototype](PERSISTENT_WORKERS.md) reuses loaded
rank models across serialized requests, with an explicit epoch and request
protocol. Its streamed timing fields are diagnostic; use this one-shot launcher
for the controlled measurement path.

The snapshot contains the executable, Metal library, SwiftPM resources and
supervisor code. Every rank checks the same snapshot hash before starting. Real
models additionally undergo full manifest verification. The worker clears
inherited MLX/JACCL/Darkbloom backend variables before applying the explicit
configuration. Inputs and reports must agree across ranks.
Reports require `rank0-greedy` selection for cooperative runs and `local-greedy`
for independent runs. Selected tokens must agree across cooperative ranks, while
local argmax disagreements are counted separately. Every recorded decode input
must match the agreed teacher history or the previous selected output.
Direct-load receipts separately count all FFN bytes (`sourceFFNTensorBytes`),
the FFN tensors actually sharded (`sourceShardedFFNTensorBytes`), and all
partitioned source tensors (`sourceShardedTensorBytes`). MoE routers remain
replicated, so their bytes contribute only to the first FFN count. FFN plans
shard exactly the FFN subset; full plans also shard attention/recurrent tensors.
Every cooperative schema-9 report includes the same `partitionStorage`
commitment, also embedded in a real model's verified direct-load receipt. It
binds the source tensor manifest hash, source byte counts and an ordered entry
for each rank's parameter layout, selected sharded bytes and total loaded bytes.
Each rank must load `sourceModelTensorBytes - sourceShardedTensorBytes +
selectedShardedTensorBytes`; the two selected counts must sum to the source
sharded count. This permits Gemma's unequal G64-aligned intervals, including
320/384, without exempting its byte accounting or layout from validation.
Largest host tensor size is checked against that rank's loaded total. These are
checkpoint copy counts, independent of process-wide memory measurements.
Solo reports omit the commitment. `modelFamily` must be `qwen35` or `gemma4`,
match the requested synthetic profile when present, and agree across ranks.
The validator binds native metadata and selections; it does not independently
reconstruct a partition plan from the checkpoint or certify numerical quality.
`sourceTensorCount` counts checkpoint tensors and must cover `tensorCount`, the
materialized canonical tensors. MoE checkpoint gate/up pairs can become fewer
fused runtime tensors without dropping their selected bytes from the receipt.

Each rank owns its child process group and enforces a deadline. The cohort
cancels peers on failure or its own deadline; the native executable has an
additional alarm. A broken remote connection can delay cleanup until a remote
deadline. No mechanism claims instantaneous cancellation after a network loss.

The receipt's `verified_execution` means that the selected ranks exited
successfully and produced consistent, complete reports. It does not certify
logit parity. `hardware_throughput_candidate` only identifies reports eligible
for further review; qualification still requires the
[governing benchmark conditions](../../../docs/design/distributed-inference-goal.md).
Synthetic model runs, loopback runs and logit-capture runs cannot satisfy the
hardware performance goal.

The process and validation tests use temporary fixtures without models, GPU
work or SSH:

The separate [local stage correctness launcher](stage_checks/README.md) runs
the fixed native P2P matrix or a bounded verified whole-layer stage pair. It
accepts explicit artifact/token/binary pins and optionally compares a separately
pinned baseline. Its receipts remain ineligible as throughput evidence.

```sh
mise exec -- python -m unittest discover -s experiments/cluster -p 'test_runtime*.py' -v
```
