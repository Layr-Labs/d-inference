# Guarded remote rank-owner launcher

Private source/CPU adaptation,2026-09-14. Root owns actual SSH/native use. This
copies the frozen rank-phase launcher and requests two distinct diagnostic
sidecars under each rank's owned directory. No native candidate, actual prompt,
model payload, SSH or native process was accessed by the author.

Two runtime files differ from the frozen phase launcher:

- `long_rank_configuration.py` appends exactly
  `--prefill-owner-trace-file @rank/owner-trace.json` after the existing fixed
  `--prefill-phase-trace-file @rank/phase-trace.json` pair.
- `launch_remote_long_ranks.py` uses
  `remote_qwen_long_prefill_rank_owner_launcher` and adds
  `owner_timing_requested: true`, preserving `phase_timing_requested: true`.

Seventeen upstream Python files remain byte-identical. Two inherited phase
tests adjust expected kind/argument positions; one added owner test compares
both ranks and both policies against the frozen phase configuration plus only
the owner pair, rejects missing/duplicate/wrong paths, and exercises the fake
entry's receipt and sidecar-excluded archive. All25CPU/fake tests pass;22tests
are unchanged. Actual subprocess/socket creation is blocked. Python3.9 syntax
checks cover21Python files.

```sh
python3 launch_remote_long_ranks.py \
  --release RELEASE_BUNDLE_DIRECTORY --runtime REPOSITORY/experiments/cluster/runtime \
  --output NEW_OUTPUT_DIRECTORY --host REVIEWED_SSH_ALIAS \
  --remote-model-dir REMOTE_REGISTERED_MODEL_DIRECTORY \
  --artifact-aggregate-sha256 REGISTERED_ARTIFACT_SHA256 \
  --expected-native-sha256 FINAL_REVIEWED_NATIVE_SHA256 \
  --prompt-file PINNED_PROMPT_JSON --long-prompt-sha256 RAW_PROMPT_SHA256 \
  --prompt-origin-file TOKENIZATION_RECEIPT_JSON --prompt-origin-sha256 ORIGIN_FILE_SHA256 \
  --stage-prefill-policy serial_v1 --stage-logits-dtype bfloat16 \
  --parent-timeout-seconds 330
```

Native mode remains `qwen-long-prefill-rank-check`, exact registered9B
8192/chunk512/output1, seed7, native precision, CBv2 contiguous, no teacher,
one repeat and zero warmups. Explicit policies remain `serial_v1` or
`prompt_lookahead_one_v1`; root chooses the diagnostic schedule. Fresh epoch,
two distinct rank directories/loopback endpoints, source/bundle/model pins,
raw prompt/host-file seals, arithmetic environment, readiness/two-record
contracts and exact source-bound loopback stderr warning are unchanged.

The initial remote screen requires6GiB actual free before remote bundle/model
reads; post-hash screening requires8GiB estimated reclaimable. Pressure must
stay<=2 and every observed reported swap value must be zero. Native/worker
alarms remain300seconds and the parent deadline at most330seconds. Peer loss,
partial launch, deadline, parse, resource or source failure fences both owned
paths. Primary/cleanup/post-run errors stay separate. Local SSH client reaping
does not establish remote native waitpid; sampled RSS is not a peak.

The native stdout schema and stderr contract are preserved; observed output
bytes and timing can change with request identity or observer overhead. No
numerical, phase, owner, throughput, power, clock-alignment, physical-transfer
or GPU-overlap qualification is asserted by the launcher.

**Neither sidecar is retrieved or verified here.** Remote files remain under
each owned rank directory as `phase-trace.json` and `owner-trace.json`.
`rank_files` still has the original ten files and metadata collection is
unchanged. A passed receipt records requested tracing only. A separate bounded
four-file reader and independent semantic auditor are required. Existing
readers/provenance helpers require explicit namespace/configuration adaptation;
old reports and frozen sources remain untouched.
