# Guarded remote short two-rank cut12 launcher

This private source/CPU proposal launches the registered 9B short serialized
`qwen-layer-stage-rank-check --stage-cut 12`: 65 prompt tokens, chunk32, four
output positions and teachers 4087/13/271. Two native processes execute on one
remote host through loopback ring transport. No full baseline runs in this
cohort. Root's separate frozen short-rank numerical auditor compares completed
reports with separately pinned baseline evidence.

The parent admits two existing short ready/report records per rank, exact
cut/source/request identities, six frame coordinates/frontiers and consumed
acknowledgements, peer header/residual metadata and model/request retirement.
State inventories and logit values are opaque to the launcher. Parent success
leaves independent execution/comparison oracle flags false, timing false and
throughput/physical qualification false. There is no v4 agreement, long profile,
user scheduling-policy option or sidecar. The inherited internal `scheduling`
argument slot is restricted to None to keep the supervisor API narrow.

## Preserved controls and bounded delta

`originals/` retains the frozen long-rank source inventory, manifest
`6fb40507e7b304affb5f917f7a4d1efc491cd82e7117bf6a6886180c77f82580`.
Rank path/port bootstrap, archive/dependency checks, memory helper and exact
source-bound warning helper are byte-identical. The rank layout is the actual
pinned `long_rank_paths.paths` result: shared `run/bundle` and ordered
`run/rank-0`, `run/rank-1`. There is no `native` path component. Ports are two
simultaneously reserved remote IPv4 loopback sockets, closed before use; an
allocation race fails without fallback. Tests never open those sockets.

The three input/expected/request modules are copied byte-identically from the
frozen one-process short launcher 826df158. It retains the exact raw prompt,
teacher, original receipt, 96-token prefix and source text. The named original
`cbv2-native` call binds teacher evidence; compact-JSON logical ID hashes are
separate from raw-file hashes. Both rank directories receive identical raw
prompt/teacher bytes and `input_files={}` prevents worker reserialization.
Each rank's prompt, teacher and hosts are sealed and verified before and after
native work, and all three plus rank.json are retrieved per rank. Local staging
and post-run raw input rereads use the existing bounded pinned reader.

The original remote control namespace remains `long_rank_control` because its
pinned observation machinery is reused. It does not select a native model mode.
Its only semantic delta is the additional raw teacher attestation per rank.
Model artifact and bundle verification still execute on the remote host before
and after native work. No model payload copies are created. The launcher also
archives and rechecks live and saved source/runtime/dependency/bundle/input
identities; any included source/document edit during a run still fails it.

Initial remote actual free must be >=6 GiB before remote bundle/model reads.
Post-hash reclaimable must be >=8 GiB with the existing disk/descriptor bounds.
Pressure must remain <=2 and reported swap exactly zero. Initial actual free is
not represented as a sustained launch-time guarantee. Remote native/supervisor
PID and RSS observations stay distinct from local SSH-client handles; missing
RSS is not assumed zero and remote absence is not a `waitpid` proof.

Native timeout is 180s. The parent supervision deadline defaults to 210s and is
capped at 210s; archive/setup/model hashing are separate bounded control calls.
The new copy adds a post-memory-observation deadline check so late observations
cannot convert an expired cohort into success. Other stop/reap mechanics remain;
primary, cleanup and post-run errors are distinct. The inherited summary field
is renamed `shared_source_request_identity_matches` to describe the short
schema correctly. Whole-cohort cancellation still touches both owned paths,
including peer loss or failed second startup.

Each rank has 64 MiB stdout and 60 MiB line caps, retaining signed-zero parsing.
Stderr must be exactly one current archived-source Collective loopback warning,
including its final newline; extras or omission fail. There are 12 rank-file
receipts (rank.json, prompt, teacher, hosts, stdout and stderr for each rank)
and 12 retrieved metadata files (four model metadata copies plus four per rank).
No sidecar is collected. The exact source-based native named-state/boundary
bound 165740576 bytes is an admission value, not total OS/MLX memory.

## Root-only command

Verify `source-review-20260914.json` before running. Keep all archived source and
runtime files unchanged until the parent is terminal. The output must be new.
The executable SHA is required by CLI and is not hardcoded in runtime source.

```sh
python3 -B /Users/developer/DarkbloomDev/cluster-research/remote-short-rank-cut-launcher-draft/launch_remote_short_ranks.py \
  --release /Users/developer/DarkbloomDev/d-inference/experiments/cluster/inference/.build/release \
  --runtime /Users/developer/DarkbloomDev/d-inference/experiments/cluster/runtime \
  --output /Users/developer/DarkbloomDev/cluster-research/runs/qwen-layer-stage-ranks-cut12-peer24-20260914 \
  --host darkbloom-24 \
  --remote-model-dir /Users/developer/DarkbloomDev/models/Qwen3.5-9B \
  --prompt-file /Users/developer/DarkbloomDev/cluster-research/runs/qwen9-output-boundaries-20260913/prompt-65.json \
  --teacher-file /Users/developer/DarkbloomDev/cluster-research/runs/qwen9-output-boundaries-20260913/cbv2-native/rank-0/teacher.json \
  --prompt-origin-file /Users/developer/DarkbloomDev/cluster-research/runs/qwen9-output-boundaries-20260913/receipt.json \
  --prompt-prefix-file /Users/developer/DarkbloomDev/cluster-research/runs/qwen9-output-boundaries-20260913/prompt-96.json \
  --source-text-file /Users/developer/DarkbloomDev/cluster-research/runs/qwen9-output-boundaries-20260913/source-text.txt \
  --prompt-sha256 667b2e8232e3fc941469be79c3a178469b7d90c23d6f3ef1de4bd8bd87a813fc \
  --teacher-sha256 aad3b6387a197e052f32d75bd3d0aead834da80e577279665e04966e81c27fbc \
  --prompt-origin-sha256 0afffd9b1863f785f4f3880f71c21305177f36cb825e29e506983ff0f745cfc1 \
  --artifact-aggregate-sha256 127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b \
  --expected-native-sha256 f82b05eb2d221152e49c8ecbffff0e091691795be76a20c78cd47d29a108fc23 \
  --parent-timeout-seconds 210
```

## Pure tests and review

```sh
python3 -B -m unittest test_short_rank_contract test_short_rank_supervision test_short_rank_launch test_short_rank_controls
```

All 25 fabricated CPU tests pass. They block real subprocess/socket entry points,
cover both rank teacher seals/attestations/retrieval, exact input/config/epoch/cut
and source pins, narrow actual rank layout, warning/parser bounds, peer-loss and
startup fencing, separate cleanup failure and the post-observation deadline.
Python 3.9 AST syntax is checked separately. Pipeline reviewed source/input/path/
control/cleanup deltas; arithmetic reviewed the native outer DTO/identity seam.
Neither reviewer executed helpers/tests or read candidates. No native, compiler,
SSH, model payload or upcoming candidate access occurred in this draft task.
The full numerical oracle and actual run remain separate root-owned work.
