# Registered 8K local prefill checks

> Last updated: 2026-09-14 · commit `e4df336bc`

The optional `long-prefill-ranks` and `long-prefill-solo` commands run one fresh
local diagnostic cohort. Their native admission is exactly the registered dense
Qwen 9B artifact, `long_prefill_8k_v1`, 8192 input tokens, chunks of 512, one
output, seed 7, native precision and `cbv2-contiguous`. Paths are supplied by
the caller; this does not extend native admission to other artifacts or lengths.
There is no teacher token, remote host, persistent worker, or warmup option.

```sh
python3 experiments/cluster/run_stage_checks.py long-prefill-ranks \
  --release RELEASE --runtime experiments/cluster/runtime --output NEW_OUTPUT \
  --expected-binary-sha256 BINARY_SHA256 \
  --model-dir REGISTERED_MODEL --artifact-aggregate-sha256 ARTIFACT_SHA256 \
  --tokens-file PROMPT_8192_IDS_JSON --tokens-sha256 RAW_PROMPT_SHA256 \
  --prompt-origin-file ORIGIN_FILE --prompt-origin-sha256 ORIGIN_FILE_SHA256 \
  --stage-prefill-policy serial_v1 --stage-logits-dtype bfloat16 \
  --parent-timeout-seconds 330

python3 experiments/cluster/run_stage_checks.py long-prefill-solo \
  --release RELEASE --runtime experiments/cluster/runtime --output NEW_OUTPUT \
  --expected-binary-sha256 BINARY_SHA256 \
  --model-dir REGISTERED_MODEL --artifact-aggregate-sha256 ARTIFACT_SHA256 \
  --tokens-file PROMPT_8192_IDS_JSON --tokens-sha256 RAW_PROMPT_SHA256 \
  --prompt-origin-file ORIGIN_FILE --prompt-origin-sha256 ORIGIN_FILE_SHA256 \
  --parent-timeout-seconds 330
```

Rank policy is explicitly `serial_v1` or `prompt_lookahead_one_v1`; logits dtype
must be `bfloat16`. Two local processes use a fresh epoch and the MLX ring
`loopback-test` backend. Loopback addresses are reserved and released before
startup; a bind race fails without fallback. Solo creates one full-model owner,
uses no transport or stage flags, and admits its native request UUID separately
from the launcher's archive UUID. Neither command changes older command caps.

For the rank command, `--stage-cut 12` selects layers 0–11 and 12–31 and
requires `serial_v1`. Omission retains the default 16+16 split and both policies.
Other explicit long cuts, explicit 16 and a cut on long solo are refused.
The [tested 12+20 plan](../../inference/QWEN_LONG_PREFILL_UNEQUAL_VALIDATION.md)
uses the same request and arithmetic contract. A shared registered descriptor
supplies its Plan/stage/configuration identities to the existing source checks;
the launcher does not implement a separate Plan serializer.

Only an explicit cut adds `stage_cut` to retained context, one native argument
pair and `selected_layer_plan` to the receipt. That receipt still leaves the
independent numerical/action/timing audit unperformed. Direct helper calls also
check the selected mode, source and policy before input or process work.

Either long command accepts the explicit optional `--prefill-phase-trace`
switch. It requests `rank-0/phase-trace.json` under the new owned output, plus
`rank-1/phase-trace.json` for the rank pair; arbitrary sidecar paths are not
accepted. The fixed native `--prefill-phase-trace-file @rank/phase-trace.json`
argument uses the unchanged supervisor's per-owner path substitution. This
adds local recorder observations and overhead while preserving the native
stdout schema, stderr contract and request admission. The default does not request tracing.

When enabled, the pinned context contains `prefill_phase_trace: true`, and the
launcher receipt adds `phase_trace_request` with expected owned paths. Its
`included_in_rank_files`, `sidecars_verified`, and `phase_semantics_audited`
fields remain false. The existing four solo or ten pair configuration/input/
stdout/stderr file receipts are unchanged. The launcher neither reads sidecar
bytes nor confirms their existence; a successful run does not establish phase
timing, GPU overlap or clock alignment. Retain and audit the sidecars separately.
No phase switch is added to the older `p2p`, `ranks`, or `prefill-ranks` commands.

The prompt must be a regular file of at most 64 KiB containing exactly 8192
integer IDs in the registered vocabulary. Floats, booleans and negative-zero
integer lexemes are rejected. Exact raw bytes, including whitespace, are
retained and staged for every owner. `input_files={}` prevents the unchanged
rank supervisor from re-encoding them. The origin file is required, bounded to
2 MiB and independently hash-pinned; its bytes are retained as opaque provenance.
The launcher does not recreate or validate tokenization semantics.

The initial screen requires 6 GiB actual free memory before source/bundle
snapshots and artifact hashing. Hashing can reduce actual free memory through
file caching. A separate post-hash screen requires at least 8 GiB estimated
reclaimable memory, 4 GiB output disk space and descriptor headroom.
`--minimum-reclaimable-gib` may raise that screen. Pressure must remain at 0–2
and reported swap must be zero at every observation. These screens do not
guarantee complete model/workspace residency or establish an RSS peak.

Each unchanged native process and rank supervisor has a fixed 300-second
bound. The parent active-cohort deadline is 1–330 seconds and covers startup
through terminal records. Artifact hashing and bounded cleanup are outside
that active interval. Any partial startup, peer failure, invalid output,
memory failure, signal or deadline cancels every admitted owner and reaps all
started supervisors. Primary and cleanup failures are retained separately.
Native process-group cleanup is delegated to the pinned `rank_worker` finally
path; a separate native PID inventory is not invented by this launcher.

Each owner must emit exactly ready plus terminal in at most 8 MiB of stdout.
Solo stderr must be empty. Each rank must emit exactly the archived
`Collective` loopback warning once, with no additional stderr. Validation checks
closed namespaces, profile/source/raw prompt/arithmetic identity, ready/final
stability, exact rank peer agreement, loaded stage identities, retirement and
model-release assertions. Raw logs, exact argv/environment, staged files and
source/bundle/artifact identities are retained and rechecked after execution.
The caller's executable pin is not a reproducible-build proof; retain its build
receipt and device provenance separately.

The native `execution` payload remains opaque to this launcher. Numerical
comparison, native payload hashes, state/logit digests, action ordering and
timing arithmetic require a separate independent audit with a separately
pinned full-model reference. Candidate final logits are digest-only; no full
candidate row is exported. `baseline_audit.performed` and
`independent_numerical_action_timing_audit.performed` remain false even on a
successful launcher run. Success establishes outer execution/identity checks,
not model quality, qualified throughput or physical two-machine transfer.

These public commands are a source and fake-CPU-tested promotion of bounded
guarded execution. Existing archived native records keep their original
launcher/source identities; they are not retroactively attributed to this entry.
The integrated cluster suite passed 259 Python tests. Saved-output replay
accepted all ten records from the serial, lookahead and solo native runs
without changing the validators. This checks actual output compatibility;
execution through these public commands remains unqualified.
The later optional phase-forwarding change passed 81 integrated CPU/fake
stage-check tests, including nine new option/configuration/failure cases.
The selected-cut extension subsequently passed all 109 integrated stage tests,
including 13 new cases, and 21 saved-default configuration/context comparisons.
Its actual public model entry remains unqualified until run and independently
audited through this command.
