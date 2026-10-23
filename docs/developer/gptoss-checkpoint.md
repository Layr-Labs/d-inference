# Prepare A Publisher-Precision GPT-OSS Checkpoint

> Last updated: 2026-10-23

Use the offline GPT-OSS tools to preserve publisher MXFP4 expert bytes and BF16
non-expert tensors, then compare the candidate with the current serving artifact.
Conversion and CPU fixtures do not establish model quality or performance.

## Prerequisites

- A pinned local `openai/gpt-oss-20b` snapshot and an independently authenticated
  JSON manifest with `repo`, full `revision`, and `files` mapping filenames to
  SHA-256 digests. Include every indexed shard, config/index, prompt files,
  license, usage policy and publisher README. The tool does not download files.
- The immutable current checkpoint and its prior verified JSON receipt, an
  array of objects containing unique `file` and `sha256` entries for every
  indexed shard, config/index and prompt file. Conversion freshly hashes those
  files against the receipt, including Q8 rows outside the numeric sample.
- An allocated resource window for large reads, hashing and writes. Conversion
  uses bounded buffers but scans whole checkpoints. The output budget defaults
  to 1 GiB and the free-space reserve to 20 GiB. Provide separate staging for
  the source and candidate; never modify borrowed shards or caches.

## Steps

1. Plan with saved header dictionaries, without opening model payloads:

   ```bash
   python3 scripts/gptoss_checkpoint.py plan \
     --headers /evidence/publisher-tensor-headers.json \
     --config /evidence/publisher-config.json \
     --current-headers /evidence/current-tensor-headers.json \
     --output /evidence/conversion-plan.json
   ```

2. Run the CPU tests in [test.md](test.md#gpt-oss-checkpoint-and-replay-tools).
   After resource allocation, convert into a new directory:

   ```bash
   python3 scripts/gptoss_checkpoint.py convert \
     --source /staging/publisher --source-manifest /evidence/source-manifest.json \
     --current /models/current --current-receipt /evidence/current-receipt.json \
     --output /staging/candidate --receipt /evidence/conversion-receipt.json \
     --max-output-gib 14 --resource-window allocated-window-reference
   ```

   `make_plan` splits alternating gate/up rows and reinterprets four adjacent
   packed bytes as little-endian U32. It copies E8M0 scales and BF16 biases
   without numeric conversion. `candidate_config` declares MXFP4/group-32 and
   excludes BF16 modules from quantization. All trained values come from the
   publisher snapshot. Dequantization cannot recover unreleased BF16 experts.

   The tool validates publisher and current file hashes, tensor inventory/spans,
   output shapes and byte readback, and every preserved tensor against the
   current checkpoint. Unindexed safetensors files are rejected because the
   serving loader would also load them. For restored Q8 modules it reports
   three sampled rows per matrix against affine
   reconstruction; this is not exhaustive error measurement or a matmul oracle.
   The current prompt files are retained and verified against their receipt so
   the weight comparison does not also change prompt semantics.

   Current Q8 overrides must specify 8 bits and group size 64. An omitted
   per-layer `mode` means `affine`, matching the pinned SDK decoder even under
   a global MXFP4 policy. Explicit incompatible modes or precision remain
   errors; the current checkpoint and its authenticated config are not edited.

3. Prepare identical frozen HTTP request cohorts for both artifacts. Include
   cold misses, full/partial hits, mixed lengths, concurrency and independent
   quality tasks. Bind each launch to its actual native artifact hash, prompt
   identity, binary, metallib and config. Use fresh isolated cache namespaces
   per arm, native paged KV, prefix caching enabled and MTP off for GPT-OSS.

4. After an exclusive GPU allocation and model load, replay each arm:

   ```bash
   python3 scripts/gptoss_replay.py --base-url http://127.0.0.1:18241 \
     --suite /evidence/frozen-suite.json --identity /evidence/launch-identity.json \
     --output /evidence/new-run --resource-window allocated-window-reference
   ```

   Identity JSON requires `model_artifact_sha256`, `prompt_contract_sha256`,
   `binary_sha256`, `metallib_sha256`, and `config_sha256`. These are supplied
   launch evidence, not live attestation. Each suite has `cohorts` containing a
   unique safe `id` and 1–32 `cases`; each case has a unique safe `id`, streaming
   `payload`, a
   `cache` expectation (`miss`, `hit`, or `any`), and optional `fixed_tokens`.
   Hits require `minimum_cached_tokens`. GPQA cases can supply `answer_letter`.
   Every suite must contain an effective cache-hit case. Payloads require one
   completion, positive integer `max_tokens`, `stream: true`, and
   `stream_options.include_usage: true`. Preflight runs before any requests.

## Verify

Inspect the external conversion receipt and require absence of the output's
`INCOMPLETE` marker before loading. The marker is an operator warning; the
serving loader does not enforce it. Existing output directories and receipt
files are never overwritten; plan output files also require a new path.
A preserved-tensor mismatch records `status: validation_failed` in the receipt
and retains the marker. Preserve failures for investigation.

The packed layout uses the existing SDK `GPTOSSModel.sanitize` and
`GPTOSSModel.fuseGateUpWeights`; `loadWeights` quantizes only modules with scale
tensors. Raw publisher import is a different path and is not exercised by this
converter. Do not layer BF16 files beside the old Q8 shards: `loadWeights`
enumerates all safetensors files, so a new index alone cannot exclude old tensors.

Replay refuses absent paged/cache-ready telemetry, active MTP, incomplete SSE,
ineffective hits, warm data mislabeled cold, or early stops in fixed-token work.
Token usage must contain nonnegative integers within prompt/output bounds.
It retains raw streams before checking bounded request drain; a cohort receives
throughput only after response and drain checks pass. Require `complete.json`
for a completed suite. Aggregate end-to-end timing includes thread startup,
stream parsing and local result writes; it is not isolated engine throughput.
Capture is limited to 1 MiB per SSE line and 16 MiB per response; exceeding a
limit fails the trial. Redirects and environment HTTP proxies are disabled.
Quality scores and truncation remain separate. Runtime telemetry proves the reported backend;
individual shader dispatch, persistent-cache restoration, memory peaks and
hardware support still require native evidence.

Use paired/interleaved repeats, identical sampling and full request hashes.
Retain failures and new quality regressions; a shorter completion is not a
speedup. Five trials are descriptive and do not qualify p95/p99. No reproducible
regression is accepted automatically. See [serving qualification](serving-performance-qualification.md)
for independent release gates, using paged/cache-enabled paths for this comparison.

## Troubleshooting

- Insufficient disk or default output budget: allocate staging; retain the cache
  reserve and do not place multi-gigabyte candidates on a shared benchmark SSD.
- Preserved-tensor mismatch: inspect the receipt. The candidate remains marked
  incomplete; sampled prior equality is not a full-checkpoint proof.
- Missing source hash: authenticate that file at the pinned source revision.
  A byte-range hash does not establish the SHA-256 of a whole publisher shard.
- Cache status ready but hit fails: inspect actual reuse and SSD headroom.
  Preserve the failed trial; do not silently retry it as a cold measurement.

## Related

- [Build and resource ownership](build.md)
- [Test the tools](test.md#gpt-oss-checkpoint-and-replay-tools)
- [Publish an existing model revision](../operations/model-revisions.md)
