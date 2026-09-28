# Bounded prefill compute check launcher

This root-run draft launches one native inference process through the existing
`rank_worker.py` supervisor. It compares the verified ordinary baseline with
both full-width layer stages in one process. It has no timing or throughput
qualification and does not exercise interprocess transport.

The workload is fixed to the retained registered Qwen3.5-9B artifact, its saved
65-token prose prefix, chunk size 32, and one output token. There are three
prefill forwards and no decode forward, teacher token, warmup, or repeat. Native
arguments select `cbv2-contiguous`; they contain no epoch or transport option.
The launcher UUID is archive metadata only.

Before source/bundle snapshots or full artifact hashing, the launcher records
timestamped raw `vm_stat` and requires at least 6 GiB in **Pages free**. Artifact
hashing can consume free pages as filesystem cache. After hashing it separately
records actual free pages and requires at least 8 GiB of estimated reclaimable
memory (free + inactive + speculative), 4 GiB of disk space, and descriptor
headroom. The initial 6 GiB threshold is **not** asserted at native launch.
Post-hash and during execution, memory pressure must be at most level 2 and
reported swap usage must not increase from the post-hash baseline. These are
bounded observations, not a guarantee of peak process or unified-memory usage.

The runtime, inference source files, dependency identities, native bundle,
launcher Python files, input provenance, model metadata, and expected inventory
are retained with hashes in the fresh private output directory. The original
model payload is verified before and after execution through the archived
runtime. Model weights are not copied. Source, bundle, launcher, input, and
configuration drift fail the run.

The stdout contract is exactly two JSON lines:

1. `qwen_layer_stage_baseline_checkpoint`, with the fixed source/configuration,
   recorded input/schedule, and baseline state/model retirement declarations.
2. `qwen_layer_stage_prefill_report`, schema 1, with the correctness-only and
   model-release flags and a nonempty nested `comparison` object.

The launcher admits the outer records only. It deliberately does not interpret
the new comparison schema or independently establish its numerical assertions.
An independent CPU audit must assess final native logits, state, and capture
counts. Saved output is bounded to 64 MiB total stdout, 60 MiB per line, and
4 MiB stderr. Duplicate JSON keys and nonfinite values fail admission.

The parent deadline is at most 180 seconds from supervisor startup. On failure,
deadline, or interruption it uses the existing cancel-file/supervisor cleanup
to retire the owned native process group. Successful EOF must contain both
complete records. The receipt retains the supervisor PID, exit status, reaping
result, raw logs, and hashes. Independent native PID inventory remains the
root orchestrator's postflight check.

The root built and froze the binary below; use a new output path:

```sh
python3 /Users/developer/DarkbloomDev/cluster-research/prefill-compute-launcher-draft/launch_prefill_compute.py \
  --release /Users/developer/DarkbloomDev/d-inference/experiments/cluster/inference/.build/arm64-apple-macosx/release \
  --runtime /Users/developer/DarkbloomDev/d-inference/experiments/cluster/runtime \
  --model-dir /Users/developer/DarkbloomDev/models/Qwen3.5-9B \
  --artifact-aggregate-sha256 127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b \
  --expected-native-sha256 48931adacab531e289063dbe3f5a03871ee3fd420f3767be82024e7699d74f46 \
  --input-origin /Users/developer/DarkbloomDev/cluster-research/runs/qwen9-output-boundaries-20260913 \
  --expected-inventory /Users/developer/DarkbloomDev/cluster-research/qwen-layer-stage-real9b-expected-20260913.json \
  --output /Users/developer/DarkbloomDev/cluster-research/runs/qwen-layer-stage-prefill-20260914 \
  --timeout-seconds 180
```

This draft has been exercised with pure parsing and fake process/memory tests
only. Tests prohibit `subprocess.run`, `subprocess.Popen`, and socket creation.
They do not read model payloads, invoke the native binary, build, or use a GPU:

```sh
cd /Users/developer/DarkbloomDev/cluster-research/prefill-compute-launcher-draft
python3 -m unittest -v test_prefill_compute.py
```

The earlier P2P, rank, public, and lookahead launchers and their historical
receipts remain unchanged. This folder is a distinct source-only draft.
