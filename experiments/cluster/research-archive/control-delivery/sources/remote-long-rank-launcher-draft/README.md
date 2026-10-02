# Guarded remote v4 long-prefill rank launcher

Private source/CPU draft, 2026-09-14. Root alone executes SSH and native work.
No candidate output, actual prompt, model payload, SSH or native process was read
or executed while preparing the draft. The 22 tests use generated tokens,
fabricated metadata, fake child handles and clocks; process/socket APIs are
blocked. Python 3.9 syntax checks pass.

Root supplies the final build pin explicitly:

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

The second policy is `prompt_lookahead_one_v1`; shortened spellings are rejected.
Each invocation creates a fresh epoch and a new remote UUID directory under the
default private run root, or an explicit nonoverlapping `--remote-run-root`.
Neither a model nor a remote Git checkout is copied. The two ranks share the
verified bundle/model path and use separate rank directories. Remote stdlib
sockets reserve two distinct IPv4 loopback ports simultaneously, then close;
the recorded race has no fallback. This is one host's loopback execution, not
a physical link or two-machine performance qualification.

Native mode is exactly `qwen-long-prefill-rank-check`, prompt8192/chunk512/output1,
seed7, native precision, CBv2 contiguous, no teacher, one repeat and zero warmups.
Native and unchanged rank-worker deadlines are 300 seconds; the parent bounds
the whole cohort to at most330 seconds, including worker verification/startup.
The parent cancels both owned paths on any peer loss, timeout, parse/resource
failure or partial launch. Primary, cohort cleanup and later verification errors
remain separate. Local SSH handle reaping is distinct from observed remote PID
absence; root still performs independent postflight. A process blocked in the
backend needs the external deadline and group cleanup, not a protocol retry.

The raw <=64KiB prompt and two loopback host files are copied and sealed before
native launch. Both before/after remote controls check their actual sizes and
SHA256 values. `input_files={}` prevents the worker from reencoding either file;
the only environment file is the staged `MLX_HOSTFILE`. Exactly three arithmetic
variables plus rank are configured after the worker strips inherited MLX/JACCL/
Darkbloom variables. Exact source-bound arithmetic receipt/hash is required in
the native records; no reference parser or tokenization replay is added here.

The remote initial actual-free screen requires6GiB before remote bundle/model
reads. After artifact hashing, the separate screen requires8GiB estimated
reclaimable memory, descriptor headroom and4GiB disk. Pressure must remain<=2
and all observed reported swap must be zero. The initial actual-free level is
not claimed to persist after hashing. Per-rank PID/PPID/PGID/RSS observations
retain their rank and exact owned command paths. Sampled RSS is not a peak;
unobserved processes do not contribute assumed zero RSS. These are admission
screens, not a proof of whole-process memory safety.

Only the exact one-line `Collective` loopback warning is admitted on each rank's
stderr, including its trailing newline. Prefixes are allowed while a write is
in progress; successful EOF requires the complete line exactly once. Any extra
byte fails the cohort. The archived `Collective.swift` branch and `Options.log`
body are checked before launch and their complete file hashes are retained in
`stderr_contract`. Stable runtime/rank source dependencies are frozen; complete
actual Options/Main and every Swift/runtime source remain archive-bound even
when a later reviewed build adds an independent mode.

Exactly two complete stdout records per rank, each within8MiB, are required:
`qwen_long_prefill_rank_ready` then `qwen_long_prefill_rank_report`. The launcher
checks closed outer schema1/flow`profiled_prefill_measurement_v1`/envelope4,
epoch/rank/world identity, exact shared agreement and fingerprint, raw/logical
prompt/history, source pins, arithmetic receipt and retirement flags. Nested
execution remains opaque. The independent oracle owns residual/frame/ACK/action,
final-state/logit digest, selection and timing validation. A successful launcher
receipt does not mean numerical parity, speedup, model quality or physical
transfer was qualified.

`receipt.json` preserves source/bundle/launcher/control/input pins, rank configs,
raw source metadata before/after, port allocation, both native output files,
memory samples, rank-tagged observed process summaries and separate error lists.
Oversized files are explicitly retained with omitted-hash markers and cannot
be passed off as verified output. The root must bind its completed receipt and
postflight before running the separately frozen CPU provenance/numerical audits.
