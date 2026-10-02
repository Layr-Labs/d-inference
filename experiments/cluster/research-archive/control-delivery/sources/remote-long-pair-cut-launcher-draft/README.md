# Guarded private 8K pair check at cut12

2026-09-14. Source and fake CPU checks only. Root owns the actual run.

This separate launcher runs one remote native process in
`qwen-long-prefill-pair-check` with exactly one fixed `--stage-cut 12`. It first
produces a fresh full-model reference bound to the12/20 plan, releases that
model, then loads both stages for the existing sequential comparison. Native
request geometry remains8192 prompt tokens, chunk512, output1, no teacher,
CBv2-contiguous, repeat1/warmup0 and300 seconds. Parent supervision remains
bounded to330 seconds. The explicit executable SHA is supplied at invocation.

The only original runtime changes are the new launcher namespace and selected
plan receipt, the fixed native cut argument, and outer reference/stage/agreement
plan checks. `long_pair_cut.py` binds constants from the independent pure Plan
control and derived expected metadata; it does not inspect candidate tensors or
compute a numerical comparison. All nine other original helpers are byte-for-byte
preserved, including raw inputs, paths, remote controls, client, resource gates,
source archive and supervision. All13 originals and their manifest are retained
under `originals/`. Historical launchers, reports and tests remain untouched.

The two native record kinds remain `qwen_long_prefill_pair_reference_checkpoint`
and `qwen_long_prefill_pair_report`. The new launcher receipt kind is
`remote_qwen_long_prefill_pair_cut_launcher`; `selected_layer_plan` records cut12,
ranges0..<12 /12..<32 and the expected plan/stage/configuration pins. Parent
success establishes the completed outer/provenance contract only.
`independent_reference_oracle_run`, the execution's
`independent_comparison_oracle_run` and the selected-plan
`independent_numerical_comparison_run` remain false. A separately frozen
cut12 numerical oracle must check the complete reference, stage inventories,
sixteen paired commits,72-component final state union and final token/logit
metadata/digests. Candidate native logit bytes are not exported by this mode.

The actual solo path constructor creates `run/native` and **`run/native/bundle`**.
The unchanged worker receives `@rank/prompt.json` with `input_files={}`; the raw
prompt and opaque independently pinned tokenization receipt are retained without
reserialization. Remote full artifact/configuration/manifest, bundle, rank config
and raw input hashes are checked before and after execution. Both final raw
prompt and configuration copies are retrieved. No model payload is copied, and
local model verification is not substituted for remote verification.

Initial remote actual free memory must be at least6GiB before remote bundle/model
reads. Post-hash reclaimable memory must be at least8GiB; pressure must remain<=2
and reported swap must remain zero. The initial6GiB screen is not described as a
launch-time free-memory guarantee. Stdout and individual lines remain<=8MiB;
stderr must be empty. The inherited supervisor already checks the deadline
after a memory observation, stops only the owned run, reaps the local SSH client,
and keeps primary, cleanup and post-run errors separate. Remote PID observations
do not prove remote `waitpid`. No timing, physical transport, cluster throughput
or target-hardware qualification is made.

Root command after verifying the frozen source manifest and the built executable:

```sh
python3 -B /Users/developer/DarkbloomDev/cluster-research/remote-long-pair-cut-launcher-draft/launch_remote_long_pair.py \
  --release /Users/developer/DarkbloomDev/d-inference/experiments/cluster/inference/.build/release \
  --runtime /Users/developer/DarkbloomDev/d-inference/experiments/cluster/runtime \
  --output /Users/developer/DarkbloomDev/cluster-research/runs/qwen-long-prefill-pair-cut12-peer24-20260914 \
  --host darkbloom-24 \
  --remote-model-dir /Users/developer/DarkbloomDev/models/Qwen3.5-9B \
  --prompt-file /Users/developer/DarkbloomDev/cluster-research/long-prefill-input-20260914/prompt-8192.json \
  --prompt-origin-file /Users/developer/DarkbloomDev/cluster-research/long-prefill-input-20260914/tokenization.json \
  --long-prompt-sha256 ee6caf0be6391e00ec41df930f0fd6351613969622cbb247b1b4bdaf69afe997 \
  --prompt-origin-sha256 b9e70184956db293c3d76d224728ae773c51971a60244cd930aea9e06bf67320 \
  --artifact-aggregate-sha256 127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b \
  --expected-native-sha256 "${QWEN_PAIR_NATIVE_SHA256:?Set the exact root-verified post-fix build SHA256}" \
  --parent-timeout-seconds 330
```

The input/output values above were supplied by root. Root must set
`QWEN_PAIR_NATIVE_SHA256` to the final verified build hash after the separate
solo admission correction; no executable hash is hardcoded in this launcher.
This drafting task did not open the actual prompt, origin, native executable
or candidate output.

Run the local fake checks with `python3 -B run_cpu_checks.py`. All23 cases pass:
the original8 outer checks remain, plus15 focused cut/config/source/storage,
actual path-constructor, raw input, bound/deadline and cleanup checks. The test
runner rejects process/socket creation and parses all16 Python files with the
Python3.9 grammar. No standalone native, compiler, SSH or model call occurred.
The independent source review is recorded separately in the freeze.
