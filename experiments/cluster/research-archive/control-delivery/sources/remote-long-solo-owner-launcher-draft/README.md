# Guarded solo owner-trace launcher

Private source/CPU adaptation, 2026-09-14. Root alone executes SSH/native work.
The frozen solo-phase launcher's resource, source, raw-input, model verification,
process cleanup and native two-record contracts are retained. Two runtime files
change: the receipt kind becomes `remote_qwen_long_prefill_solo_owner_launcher`
with `owner_timing_requested: true`, and configuration appends the fixed pair
`--prefill-owner-trace-file @rank/owner-trace.json` after the existing phase pair.

Both `--prefill-phase-trace-file @rank/phase-trace.json` and the owner flag are
requested for the same owned native directory. Paths cannot be overridden by
the caller. Native mode remains `qwen-long-prefill-solo-check`: one registered
9B full-model 8192/chunk512/output1 request, native CBv2, no teacher, no warmup or
repeated request. The native stdout schema and empty-stderr contract stay the
same; this does not mean actual timing values or output bytes are unchanged.

Root supplies the reviewed executable pin explicitly:

```sh
python3 launch_remote_long_solo.py \
  --release RELEASE_BUNDLE_DIRECTORY --runtime REPOSITORY/experiments/cluster/runtime \
  --output NEW_OUTPUT_DIRECTORY --host REVIEWED_SSH_ALIAS \
  --remote-model-dir REMOTE_REGISTERED_MODEL_DIRECTORY \
  --artifact-aggregate-sha256 REGISTERED_ARTIFACT_SHA256 \
  --expected-native-sha256 FINAL_NATIVE_SHA256 \
  --prompt-file PINNED_PROMPT_JSON --long-prompt-sha256 RAW_PROMPT_SHA256 \
  --prompt-origin-file ORIGIN_FILE --prompt-origin-sha256 ORIGIN_FILE_SHA256 \
  --parent-timeout-seconds 330
```

The remote initial actual-free screen remains 6GiB before bundle/model reads;
post-hash estimated reclaimable remains 8GiB, pressure<=2 and every observed
reported swap value zero. Native/worker deadlines remain 300 seconds and the
local parent at most 330 seconds. Raw prompt bytes are staged unchanged with
`input_files={}`. Arithmetic environment, explicit model/config/binary pins,
output bounds, readiness checks and source rechecks are unchanged. Owned remote
cancellation and local SSH reaping retain separate primary/cleanup/post-run
errors; no independent remote waitpid claim is added.

Neither sidecar is retrieved, hashed, or semantically checked by this launcher.
`native_files` retains the original configuration/stdout/stderr scope, and the
six-file remote metadata collection stays unchanged. Existing readers/auditors
must be explicitly adapted to the new owner namespace and owner file; do not
weaken or relabel their prior evidence. The launcher merely records both trace
requests and does not establish phase balance, lifecycle timing, GPU overlap,
model quality, physical transfer or throughput gains.

The 21 CPU/fake tests comprise 18 unchanged earlier tests, two phase tests with
only exact configuration/receipt expectations updated, and one new owner test.
The new test proves exact equality with the frozen phase configuration plus the
single owner argument pair, rejection of absent/wrong/duplicate owner flags,
and the fake entry's request-versus-retrieval distinction. All process/socket
creation is blocked; no real prompt, model payload, native output or sidecar
was accessed. Python3.9 syntax checks cover sixteen Python files. Twelve of the
fifteen upstream Python files are byte-identical; only two runtime files and
the phase expectation test file differ, with one new owner test file added.
