# Guarded private 8K cut12 ranks with two trace requests

2026-09-14. Source and fake CPU checks only. Root owns actual execution.

This separate launcher adapts the frozen long-rank owner launcher to the
registered9B12/20 plan. Each of two ranks receives exactly one `--stage-cut 12`
in `qwen-long-prefill-rank-check`. Both existing policies remain explicitly
admitted: `serial_v1` and `prompt_lookahead_one_v1`. The initial intended run is
serial. Geometry remains8192 prompt tokens, chunk512, output1, no teacher,
CBv2-contiguous, seed7, repeat1/warmup0. The existing BF16/query128/TF32 environment,
BF16 logits and loopback-only transport remain exact. Native timeout is300s and
the parent bound is at most330s.

The new launcher receipt kind is
`remote_qwen_long_prefill_rank_cut_owner_launcher`. `selected_layer_plan` binds
cut12, ranges0..<12 /12..<32 and the independent pure Plan/configuration pins.
The outer ready and report namespaces remain `qwen_long_prefill_rank_ready` and
`qwen_long_prefill_rank_report`, with two records per rank. Selected plan, both
stage/configuration hashes and actual local source metadata are checked before
the corresponding record is accepted. Peers still agree on their complete v4
agreement. A storage digest is a coherent observed commitment; full inventory,
state, wire/action and numerical checking belong to the separate frozen oracle.

`phase_timing_requested` and `owner_timing_requested` remain true. Each unchanged
native argument sequence includes:

```text
--prefill-phase-trace-file @rank/phase-trace.json
--prefill-owner-trace-file @rank/owner-trace.json
```

The actual frozen constructor gives shared **`run/bundle`**, ordered
**`run/rank-0`** and **`run/rank-1`**. The worker resolves the two leaves within
its own rank directory, giving four distinct sidecar paths. The ten collected
rank files still exclude both sidecars; remote metadata retrieval also excludes
them. This launcher neither retrieves nor validates trace content. A separately
reviewed reader must recognize the new namespace and bind selected-plan output
before fetching all four files. Phase/owner timing audits are separate too.

Only four original runtime files change: launcher namespace/selected receipt,
configuration's cut argument, outer plan/source admission and the post-observation
deadline check. All input/staging/control/client/path/source-archive/resource,
record framing and warning mechanisms remain byte-identical to the frozen owner
base. The new rank plan helper reuses the exact frozen pair plan helper, whose
constants were checked against the pure cut12 control and independent expected
metadata. It does not read a model or numerical candidate. Every original file
and the original source manifest are preserved under `originals/`.

The added deadline check runs after each memory observation and before accepting
two completed children. It is the same reviewed correction used by the short
rank launcher. Whole-cohort cancellation, second-start failure, survivor cleanup,
local SSH waits, primary/cleanup/post-run errors and remote PID/RSS observations
remain unchanged. Observed remote absence is not a claim of remote `waitpid`.

Keep the original resource gates: remote actual free>=6GiB before remote bundle
or model reads; post-hash reclaimable>=8GiB; pressure<=2; absolute zero reported
swap. The initial free screen is not a launch-time free-memory guarantee.
Preserve raw prompt/origin pins and byte copies, `input_files={}`, distinct
simultaneously reserved loopback endpoints, exact remote rank/hostfile/prompt
hashes before and after, full artifact/config/manifest revalidation, bundle and
source drift checks, and bounded metadata retrieval. No model payload is copied.
Each rank's stdout/line limit remains8MiB. Stderr admits only the single exact
loopback warning derived from the archived Collective/logger source.

Parent success means the bounded launch/provenance/outer contract completed.
`independent_execution_oracle_run`, nested execution validation and the selected
plan's `independent_numerical_comparison_run` remain false. Native diagnostic
timing is requested as before; throughput and physical two-machine qualification
remain false. Local phase durations do not align clocks across ranks or isolate
GPU kernel time. The separate cut12 rank oracle must admit the explicitly pinned
qualified cut12 pair container and CPU result, then compare its nested reference;
no old half-plan baseline is relabeled here.

Root command after verifying the frozen source inventory and current executable:

```sh
python3 -B /Users/developer/DarkbloomDev/cluster-research/remote-long-rank-cut-launcher-draft/launch_remote_long_ranks.py \
  --release /Users/developer/DarkbloomDev/d-inference/experiments/cluster/inference/.build/release \
  --runtime /Users/developer/DarkbloomDev/d-inference/experiments/cluster/runtime \
  --output /Users/developer/DarkbloomDev/cluster-research/runs/qwen-long-prefill-ranks-cut12-serial-owner-peer24-20260914 \
  --host darkbloom-24 \
  --remote-model-dir /Users/developer/DarkbloomDev/models/Qwen3.5-9B \
  --prompt-file /Users/developer/DarkbloomDev/cluster-research/long-prefill-input-20260914/prompt-8192.json \
  --prompt-origin-file /Users/developer/DarkbloomDev/cluster-research/long-prefill-input-20260914/tokenization.json \
  --long-prompt-sha256 ee6caf0be6391e00ec41df930f0fd6351613969622cbb247b1b4bdaf69afe997 \
  --prompt-origin-sha256 b9e70184956db293c3d76d224728ae773c51971a60244cd930aea9e06bf67320 \
  --artifact-aggregate-sha256 127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b \
  --expected-native-sha256 705013e1e7f706c1ced164dbd37c7e6887a8caf43e8bd176a9cdf0bbee7ddb1d \
  --stage-prefill-policy serial_v1 \
  --stage-logits-dtype bfloat16 \
  --parent-timeout-seconds 330
```

The executable/input values came from root. This drafting task did not read the
executable, actual input, pair output or upcoming rank/sidecar candidates.

Run `python3 -B run_cpu_checks.py` for the fake suite. All35 cases pass, with
Python3.9 parsing across25 Python files. The25 upstream cases are retained;
fixture/expected namespace/config values are adapted for cut12. The peer
disagreement case now uses two valid different storage commitments so it still
tests peer fencing after stronger selected-plan checks. Ten new cases cover
exact owner-base config+one cut, required flags, coherent stale-plan rejection,
local ownership/config/storage, distinct rank paths and expiry during observation.
Process and socket entry points are blocked throughout tests. Independent source
review and exact inherited-file comparisons are bound in the freeze.
