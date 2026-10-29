# Guarded remote rank-phase launcher

Private source/CPU adaptation, 2026-09-14. Root alone executes SSH and native
work. It requests separate phase sidecars for the existing two-rank registered
9B 8192/512/output1 check on one host's loopback backend. No candidate output,
actual prompt, model payload, SSH, or native execution was accessed while
preparing this adaptation.

Exactly two upstream runtime files change:

- `long_rank_configuration.py` appends the fixed pair
  `--prefill-phase-trace-file @rank/phase-trace.json` to each rank's arguments.
- `launch_remote_long_ranks.py` emits launcher kind
  `remote_qwen_long_prefill_rank_phase_launcher` and
  `phase_timing_requested: true` (plus a descriptive docstring change).

The remaining seventeen upstream Python files are byte-identical, including
all three inherited test modules. The manifest binds the frozen upstream source
review and every copied file. A separate test module covers both ranks and both
policies, exact equality to the upstream configuration after the single flag
pair is appended, rejection of absent/wrong sidecar arguments, and the fake
launcher receipt/archive scope. All 24 tests use generated tokens, fabricated
metadata, fake process handles, and clocks; subprocess/socket creation is
blocked. Python3.9 syntax checks cover all twenty Python files.

Root supplies the reviewed current executable pin explicitly:

```sh
python3 launch_remote_long_ranks.py \
  --release RELEASE_BUNDLE_DIRECTORY --runtime REPOSITORY/experiments/cluster/runtime \
  --output NEW_OUTPUT_DIRECTORY --host REVIEWED_SSH_ALIAS \
  --remote-model-dir REMOTE_REGISTERED_MODEL_DIRECTORY \
  --artifact-aggregate-sha256 REGISTERED_ARTIFACT_SHA256 \
  --expected-native-sha256 FINAL_NATIVE_SHA256 \
  --prompt-file PINNED_PROMPT_JSON --long-prompt-sha256 RAW_PROMPT_SHA256 \
  --prompt-origin-file TOKENIZATION_RECEIPT_JSON --prompt-origin-sha256 ORIGIN_FILE_SHA256 \
  --stage-prefill-policy serial_v1 --stage-logits-dtype bfloat16 \
  --parent-timeout-seconds 330
```

Native mode remains `qwen-long-prefill-rank-check`, seed7, native precision,
CBv2 contiguous, no teacher, one repeat, zero warmups. Policies remain explicit
`serial_v1` or `prompt_lookahead_one_v1`; root's first planned diagnostic uses
serial. Per-invocation epoch, separate rank directories, source/bundle/model
pins, byte-preserving raw prompt and host-file seals, required arithmetic
environment, readiness/closed outer records, and exact source-bound loopback
stderr warning are unchanged.

Native/worker alarms remain300 seconds and the parent cohort deadline at most330
seconds. The initial remote screen requires6GiB actual free before remote
bundle/model reads; the post-hash screen requires8GiB estimated reclaimable.
Pressure must stay<=2 and every observed reported swap value must be zero.
Both owned rank paths are cancelled after any peer loss, timeout, parse/resource
failure, or partial launch. Primary, cleanup, and post-run errors stay separate.
Local SSH client reaping is not remote waitpid proof; sampled RSS is not a peak.

Native ready/report schemas and their nested execution remain unchanged.
The recorder adds local diagnostic observations and overhead; this launcher
does not compare phase traces or qualify throughput, physical transfer, clock
alignment, or GPU overlap. The independent numerical/action oracle stays
separate.

Sidecars are **not retrieved or verified here**. Each remains at that rank's
owned remote directory plus `/phase-trace.json`. `rank_files` still contains the
ten original configuration/input/stdout/stderr files, and remote metadata
collection is unchanged. A successful launcher receipt records that tracing was
requested, not that either sidecar was retrieved or independently audited.
The solo-only sidecar reader must not be used for this rank namespace; a
separate bounded rank reader is needed. Old provenance helpers likewise need an
explicit namespace/configuration adaptation before auditing this new launcher.
