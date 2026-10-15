# Remote two-rank prefill diagnostic launcher draft

This outside-repository draft starts two native layer-stage ranks on **one**
remote SSH host using explicit loopback transport. It is a developer correctness
and diagnostic check. It does not qualify two-machine inference, physical
transfer, or cluster throughput. Native rank-zero diagnostic timing remains an
opaque part of the saved native result until the independent audit examines it.

The fixed workload uses the pinned registered Qwen3.5-9B artifact, retained
65-token prose prefix, chunk size 32, one output token, no teacher, one repeat,
zero warmups, native `cbv2-contiguous`, and explicitly qualified `bfloat16`
logits. The caller must choose `--stage-prefill-policy serial_v1` or
`--stage-prefill-policy prompt_lookahead_one_v1` and supply the exact native
binary SHA256. The launcher has no default binary pin or automatic policy.

For each invocation the launcher archives the root's current inference sources,
dependency identities, runtime, input provenance and exact native bundle. It
creates a fresh private UUID directory under the remote
`~/DarkbloomDev/cluster-runs` (or explicit `--remote-run-root`). Its two native
directories are `rank-0/` and `rank-1/`, with one shared `bundle/` and one
existing model directory. It does not copy model weights or need a remote Git
checkout. Existing UUID paths and SCP destinations are rejected.

The fixed remote bootstrap binds two IPv4 sockets simultaneously to
`127.0.0.1:0`, records two distinct assigned endpoints, then closes both sockets.
The endpoints become both ranks' identical hostfile. They are not kept reserved
during staging; any subsequent port-binding race fails native startup without
fallback, retry, or reuse of an existing epoch. The bootstrap source and returned
allocation record are retained with the run.

Pinned remote controls apply the same gates as the frozen single-process
launcher: at least 6 GiB in actual **Pages free** before remote bundle staging
or model hashing; after full model/bundle verification, at least 8 GiB estimated
reclaimable memory, 4 GiB disk space, and descriptor headroom; pressure at most
level 2 and no increase in reported swap from that post-hash baseline. The
later actual-free reading is recorded, not required to stay above 6 GiB after
file-cache reads. These screens are not peak-memory guarantees.

Both ranks use the unchanged archived `rank_worker.py`, including its model
verification, private native process group, cancel-file supervision, native
deadline, and `finally` cleanup. The local parent has one at-most-180-second
cohort deadline. A failed/disconnected SSH client, malformed output, peer
agreement mismatch, memory failure, or partial startup fences **both** remote
rank paths. Primary errors, cohort cleanup errors, and final cancellation errors
are retained separately. Local SSH PIDs/reaping are distinct from sampled
remote rank supervisor/native PIDs. Remote RSS bytes are sampled `ps` KiB ×1024,
not peaks; absence is not treated as zero. A later remote inventory observation
is not proof of remote `waitpid` reaping, which is deliberately not claimed.

The launcher admits exactly two JSON records per rank:

- `qwen_layer_stage_prefill_rank_ready`, schema 1, flow
  `bounded_prefill_measurement_v1`, envelope version 3, with model-readiness and
  no-fresh-request-state declarations.
- `qwen_layer_stage_prefill_rank_report`, with completion, correctness-only,
  unqualified transfer/timing, and state/model retirement declarations.

Both rank descriptors and agreement fingerprints must match exactly. The
descriptor binds policy, dtypes, epoch, source identities and the fixed prepared
input. Final outer request/source pins must match; the nested `execution` object
stays opaque. This launcher does not validate numerical parity, scalar action
traces, timing arithmetic, or final state/logit receipts. A separate CPU oracle
does that work. Stdout is limited to 64 MiB per rank, 60 MiB per line, and stderr
to 4 MiB per rank.

Before and after native execution, the remote controls verify every shared
bundle file and the complete remote registered model. They also pin both rank
configurations and final prompt/hostfile bytes. Only model metadata and the rank
files are fetched back; stdout/stderr stream to local `rank-0/` and `rank-1/`.
The local archive is build provenance, not a replacement for remote model
verification. Remote control processes' monotonic clocks are not assumed to
share a common origin.

After root review, run serial first with the explicit newly built binary:

```sh
python3 /Users/developer/DarkbloomDev/cluster-research/remote-prefill-rank-launcher-draft/launch_remote_prefill_ranks.py \
  --release /Users/developer/DarkbloomDev/d-inference/experiments/cluster/inference/.build/arm64-apple-macosx/release \
  --runtime /Users/developer/DarkbloomDev/d-inference/experiments/cluster/runtime \
  --host darkbloom-24 \
  --remote-model-dir /Users/developer/DarkbloomDev/models/Qwen3.5-9B \
  --artifact-aggregate-sha256 127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b \
  --expected-native-sha256 9341ca3b3dc5190ffa6759cfd045300a29422a0094710c13b88dcc39afe8ca16 \
  --input-origin /Users/developer/DarkbloomDev/cluster-research/runs/qwen9-output-boundaries-20260913 \
  --expected-inventory /Users/developer/DarkbloomDev/cluster-research/qwen-layer-stage-real9b-expected-20260913.json \
  --stage-prefill-policy serial_v1 \
  --output /Users/developer/DarkbloomDev/cluster-research/runs/qwen-layer-stage-prefill-ranks-serial-peer24-20260914 \
  --timeout-seconds 180
```

For the separate lookahead run, change only the policy to
`prompt_lookahead_one_v1` and output to a new directory such as
`runs/qwen-layer-stage-prefill-ranks-lookahead-peer24-20260914`. The launcher
creates a fresh remote UUID and endpoint pair for each invocation.

The 22 draft tests use fake processes, fake sockets, and small CPU-only files.
All actual subprocess and socket creation is forbidden by guards. No SSH,
native/build/GPU execution, or model-payload reads were performed by the agent:

```sh
cd /Users/developer/DarkbloomDev/cluster-research/remote-prefill-rank-launcher-draft
python3 -m unittest -v test_rank_prefill.py
```

Both older single-process launchers and historical reports remain unchanged.
The archived generic helpers are byte-identical copies; new files separate
rank/record admission, remote controls, staging, supervision, and orchestration.
