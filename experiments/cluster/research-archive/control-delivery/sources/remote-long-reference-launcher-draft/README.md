# Guarded remote registered-9B long reference

Source draft for root-owned execution. This author ran only fake/CPU checks;
no SSH, native inference, model payload read or reference production occurred.
The old solo launcher and every repository source remain unchanged.

`launch_remote_long_reference.py` runs exactly one remote native process with
the registered Qwen3.5-9B aggregate and 8,192/512/output-one workload. It has no
teacher/decode forwards, stage models, transport protocol or timing claim. It
uses the existing pinned `rank_worker.py` and whole-owned-process cancellation.

## Root-only invocation

```bash
python3 launch_remote_long_reference.py \
  --release <frozen-release-directory> \
  --runtime <repository>/experiments/cluster/runtime \
  --output <new-private-run-directory> \
  --host <configured-SSH-alias> --remote-model-dir <existing-remote-model-directory> \
  --artifact-aggregate-sha256 127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b \
  --expected-native-sha256 <explicit-canonical-build-SHA256> \
  --prompt-file <pinned-prompt.json> --long-prompt-sha256 <raw-prompt-SHA256> \
  --prompt-origin-file <tokenization-receipt> --prompt-origin-sha256 <origin-file-SHA256> \
  --parent-timeout-seconds 330
```

The native and remote worker timeouts are fixed at 300 seconds. The parent
deadline is at most 330 seconds, covering worker startup and native execution;
source/bundle preparation and pre/post artifact hashing are separate bounded
control operations. Control calls have explicit SSH timeouts. A deadline or
failure cancels the owned remote worker and terminates/reaps its local SSH
client. Remote worker `finally` kills its native process group even if its
leader already exited. Saved remote PID observations are not remote waitpid
proof. A later independent postflight remains useful.

## Exact raw input and environment

The parent separately pins a raw prompt of at most 65,536 bytes and an opaque
tokenization receipt of at most 2 MiB. The prompt must be a strict JSON array of
exactly 8,192 in-vocabulary integer IDs. The tokenization receipt is archived
unchanged; its schema and referenced provenance are independently audited by
the caller, not inferred by this launcher. The input folder contains the exact
`prompt.json` and `prompt-origin.json` bytes. The receipt retains both raw pins
and the comma-separated logical token hash.

The raw prompt is SCP-copied to the exclusively created `native/prompt.json`.
The rank configuration has `input_files={}` and `environment_files={}` so the
unchanged worker cannot rewrite it with `json.dumps`. Remote controls verify
the exact file size/hash before and after native execution, seal the owned
copy read-only before execution, then retrieve the actual final bytes for
another local hash check. `--long-prompt-sha256` carries this same raw pin.

The worker strips inherited `MLX_`, `DARKBLOOM_` and `JACCL_` variables, then
sets exactly `DARKBLOOM_BF16_WEIGHTS=1`,
`DARKBLOOM_CBV2_ATTN_QUERY_BLOCK=128`, and `MLX_ENABLE_TF32=1`.
The native early environment admission independently requires those settings
and absence of `MLX_METAL_GPU_ARCH` / `MLX_SDPA_BLOCKS`. No native fallback,
model-content change or warmup bypass is introduced.

## Resource and output gates

Before remote bundle staging/model hashing, actual free memory must be at
least 6 GiB. After hashing, estimated reclaimable memory must be at least
8 GiB, descriptor headroom must pass, and disk free must be at least 4 GiB.
Saved post-hash, during-run and final samples require pressure at most 2 and
zero reported swap. This is deliberately stricter than allowing an unchanged
nonzero swap baseline. Neither initial free nor reclaimable memory is a
guarantee of memory at launch or a whole-process memory bound.

Exactly two complete JSONL records are admitted, with at most 8 MiB total
stdout. Stderr is bounded at 64 KiB and must be empty. Duplicate JSON keys,
nonfinite values, incomplete/extra records, unexpected outer fields and wrong
types are rejected. Oversized output receives size/cap metadata without being
hashed. The first `qwen_long_prefill_reference_ready` record has
`verifiedModelLoaded=false` and `freshRequestStateCreated=false`: it confirms
pre-load admission, not loaded readiness. The terminal
`qwen_long_prefill_reference_report` binds the same profile/raw prompt/request
and requires completed/retired/model-released flags plus exactly the two native
memory phases `before_full_model_load` and `full_model_released_cache_cleared`.

The nested producer evidence is retained, with only its launch identities
checked here. Its numerical rows, arithmetic receipt, state geometry, complete
fingerprints and selection require the separately frozen CPU oracle. Parent
success is an outer/resource/provenance result, not independent numerical
validation. No timing field or throughput result is added.

## Retained ownership and provenance

The launcher archives its own files, all integrated inference sources, runtime,
build/dependency identities, native bundle, exact rank configuration, raw
inputs and controls. It verifies the full existing remote model before and
after, copies only its bounded config/manifest metadata, and never writes model
files. It rechecks local/archived sources, bundle, launcher, controls and input
bytes after execution. Retained archives and owned remote directories are not
deleted. Cancellation touches only the owned run; no name-based process kill
or network/Thunderbolt configuration change exists.

Receipt fields preserve `primary_failure`, `cleanup_errors` and
`post_run_errors` separately. The execution record labels the reaped PID as the
local SSH client and explicitly declines independent remote reaping proof.
Resources, actual remote before/after prompt pins, retrieved metadata and
bounded native output hashes remain available for a separate provenance audit.

The three unchanged helper files are copied from the frozen solo launcher:
`prefill_compute_archive.py`, `prefill_compute_memory.py` and
`remote_prefill_paths.py`. Modified control/client/supervision files keep their
existing ownership mechanisms. Python 3.9 syntax is checked for every draft
file. The manifest records prospective tests and source pins; it does not
claim an actual remote run.
