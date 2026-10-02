# Guarded remote short cut12 comparison proposal

This private launcher is source/CPU qualified only. It runs one native process on
one selected remote host; that process releases a fresh full-model baseline before
loading the full-width 12+20 stages sequentially. It requests the registered 9B
65-token natural prefix, chunk32, four output positions and teachers 4087/13/271.
The native mode is `qwen-layer-stage-compare --stage-cut 12`, native CBv2, seed7,
one repeat and no warmup. No transport, long profile or sidecar is requested.

The prospective parent validates exactly the existing baseline checkpoint and
comparison report, their source/selected-plan/request identities, six frame counts,
retirement and model-release flags. It leaves frame state/logit arithmetic opaque.
A parent pass always retains `independent_comparison_oracle_run=false` and
`independent_numerical_audit_passed=false`. Root must run the separately frozen
`short-stage-cut-audit-draft/audit_cut12.py` against completed stdout and the actual
retrieved prompt/teacher before making any numerical claim. There is no timing,
physical-transfer or throughput qualification.

## Preserved controls

The upstream frozen solo framework is preserved under `originals/`, including its
14-file manifest. `prefill_compute_archive.py`, `prefill_compute_memory.py`,
`remote_prefill_paths.py` and `remote_prefill_supervision.py` remain byte-identical.
The actual pinned solo path constructor yields `run/native/bundle`; native files
are under `run/native`. Fake tests derive and pin this constructor rather than
assuming the distinct two-rank layout.

The launcher archives the current inference Swift, runtime Python/Markdown,
Package/build/dependency pins, its own Python files and the binary bundle. It
requires an explicit native SHA; source, bundle and input drift fail the run. Do
not edit included repository files or this launcher during a cohort. Remote
controls fully verify the model artifact and bundle before and after native work.
Only metadata and rank/output files are copied back; no model payload is staged.

Prompt and teacher are copied as their exact raw bytes with `input_files={}`.
Their pins, the original receipt, source text and 96-token prefix are checked.
The named original `cbv2-native` call binds the three teachers. Both remote raw
inputs are hash/size checked before and after execution and retrieved afterward.
Logical ID hashes use compact JSON integer arrays encoded as UTF-8; these are
separate from raw-file pins. Neither native input is reserialized.

The initial remote actual-free screen is >=6 GiB before remote bundle/model
reads. After model hashing, the separate screen requires >=8 GiB reclaimable,
pressure<=2, zero reported swap and the existing disk/descriptor bounds. Memory
observations during execution retain remote PID/RSS samples. Initial actual free
is not represented as a sustained launch-time guarantee. Named state/boundary
admission 165740576 bytes is not total process memory. Native timeout is180s;
the parent supervisor defaults to210s and is capped at210s. Existing remote cancel
and process-group cleanup bounds remain. Parent supervision time starts before
its SSH child, not at the earlier archive/hash phase.

Stdout is capped at64 MiB total and60 MiB per line; stderr is capped at64 KiB and
must be empty. Primary, cleanup and post-run errors remain separate. An exited
local SSH client must be reaped. Saved remote process absence is an observation,
not remote `waitpid` proof or a substitute for root's separate postflight.

## Root-only invocation

Review and verify `source-review-20260914.json` before using this proposal. The
following is the exact prepared command for the registered saved inputs; the
output must not already exist. The native SHA is an explicit invocation value,
not a constant in the launcher. Root may substitute the newly qualified binary
pin if a later build is deliberately selected.

```sh
python3 -B /Users/developer/DarkbloomDev/cluster-research/remote-short-stage-cut-launcher-draft/launch_remote_short_cut.py \
  --release /Users/developer/DarkbloomDev/d-inference/experiments/cluster/inference/.build/release \
  --runtime /Users/developer/DarkbloomDev/d-inference/experiments/cluster/runtime \
  --output /Users/developer/DarkbloomDev/cluster-research/runs/qwen-layer-stage-cut12-peer24-20260914 \
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
  --expected-native-sha256 8e4596fe284f610eb7c2d5bda41cd50e448268127e40f43f443a839184a532ee \
  --parent-timeout-seconds 210
```

## CPU validation and scope

Run from this directory:

```sh
python3 -B -m unittest test_short_cut_contract test_short_cut_flow test_short_cut_control
```

The 21 fabricated tests forbid subprocess/socket creation and exercise exact
configuration/path admission, raw-input provenance, stale-plan and request
rejection, output/parser bounds, zero-swap gates, both remote input attestations,
owned timeout cleanup, SSH reaping and primary/cleanup failure retention. A
Python 3.9 AST syntax check is separate. Neither the launcher nor a native model
has been executed by this draft author; no upcoming candidate outputs were read.
The previous launchers and evidence remain unchanged.
