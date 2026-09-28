# Verified real9B stage-rank launcher draft

This is a separate out-of-repository draft. The frozen stage-p2p-launcher-draft is unchanged. No model payload, native binary, GPU task, socket or process cohort was executed during preparation; tests use fake process objects and reject real subprocess/socket calls.

Root-run command after native admission/coordinator integration and a completed build:

```sh
python3 /Users/developer/DarkbloomDev/cluster-research/stage-rank-launcher-draft/launch_stage_rank.py \
  --release /Users/developer/DarkbloomDev/d-inference/experiments/cluster/inference/.build/arm64-apple-macosx/release \
  --runtime /Users/developer/DarkbloomDev/d-inference/experiments/cluster/runtime \
  --model-dir /Users/developer/DarkbloomDev/models/Qwen3.5-9B \
  --artifact-aggregate-sha256 127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b \
  --expected-native-sha256 db9c98e36cc0e2a9f4bf17cc2763ec670161bf0868311767b27325b70a3776f0 \
  --input-origin /Users/developer/DarkbloomDev/cluster-research/runs/qwen9-output-boundaries-20260913 \
  --expected-inventory /Users/developer/DarkbloomDev/cluster-research/qwen-layer-stage-real9b-expected-20260913.json \
  --output /Users/developer/DarkbloomDev/cluster-research/runs/qwen-layer-stage-ranks-20260914 \
  --timeout-seconds 180
```

Output must be new and outside repository/model. This admits only the approved dense9B artifact/configuration and fixed natural65-token prefix,32-token chunks, four output rows, and teachers4087/13/271. Prompt IDs and source-text hash are checked against the pinned prior receipt, not just the current token files; teachers match that receipt and the fixed sequence. Copies include provenance/configuration/tokens only, never loadable weight files.

Each native rank receives exactly `--mode qwen-layer-stage-rank-check --model-dir @model --artifact-aggregate-sha256 PIN --transport loopback-test --epoch HEX32 --execution-path cbv2-contiguous --tokens-file @rank/prompt.json --teacher-tokens-file @rank/teacher.json --prompt-tokens65 --chunk-size32 --decode-tokens4 --repeats1 --warmups0 --timeout-seconds N` (actual argv has separate flag/value entries). The model directory is the original shared path; MLX_RANK identifies stage0/1, and the existing runtime creates two distinct IPv4 loopback listeners through staged MLX_HOSTFILE. DARKBLOOM_BF16_WEIGHTS=1 binds the established stored-F16 conversion policy. Native defaults keep attention/FFN output policies native; there is no synthetic/TP/MTP/workload generalization.

Before launch, copy/hash all inference Swift, package/build/dependency generator and pins, runtime Python/docs, launcher sources and the executable/metallib/resource bundle. Import and stage the copied runtime. Hash the complete original registered artifact before and after through archived runtime.verify_model; each unchanged rank supervisor also verifies the pin before starting native. Native verified stage loaders retain their own pinned descriptors. Record source/model/config/token/bundle identities and verify copied/current source, bundle, original metadata, rank configs and exact staged JSON input bytes after completion. This binds observed source/artifact identities, not a reproducible-build proof.

Preflight requires at least8GiB estimated reclaimable memory (free+inactive+speculative pages, excluding overlapping categories),4GiB disk and descriptor headroom. The estimate is an admission guard, not a whole-process memory guarantee. Before/during/after execution, pressure must remain<=2 and OS-reported swap-used must not increase. Raw sysctl/vm_stat observations retain printed precision. No swap/page/RSS guarantee is inferred; native memory records and root's independent PID/RSS inventory are separate evidence.

The driver owns exactly two supervisors. Each existing rank_worker owns a separate native process group and kills it in finally even after an exited native leader. The driver cancels both active ranks on deadline, native failure, malformed/oversized output, memory query/gate failure or signal, then reaps supervisors. There is no retry, persistent epoch reuse, peer fallback or production scheduler. Timeout1–180seconds bounds the active cohort; snapshot/hash/preflight and bounded cleanup are outside that window. Cleanup reports supervisor reaping and delegated native-group cleanup; root must independently inventory native/descendant PIDs.

Expected native output is one `qwen_layer_stage_rank_ready`, followed by one `qwen_layer_stage_rank_report`, each schemaVersion1 with epoch/rank/worldSize2/backend ring/transport loopback-test. The terminal requires completed, allRequestStateRetired and modelReleased true; correctnessOnly true, throughputMeasurementValid/modelForwardCompared false. It carries sourceLoad, QwenLayerStageRecordedRequest (epoch-derived request UUID), six frame completions, and memory observations. Each completion wraps the agreed capture structure and a completed consumed-ack phase. Rank0/rank1 source construction hashes and stage fingerprints may differ; common artifact/configuration/plan/storage/request and per-frame residual/header hashes must match.

Rank1 retains four full-vocabulary logit rows. Native BF16 logits are represented by Float32 JSON values, while the recorded native dtype and logical-byte hash describe the original storage; this is not a claim of a native Float32 output projection. These are bounded under a separate64MiB-per-rank stdout limit and60MiB-per-line limit; signed zero survives Python decoding. No values are discarded or truncated. The launcher validates the outer pin/request/frame/retirement/peer contract, not complete tensor inventories, source coverage, recurrent-state values or logit parity. The independent CPU auditor must compare global state and full logit evidence against the separately recorded baseline, whose older request UUID/fingerprint intentionally differs.

A successful receipt means the pair completed its outer execution/identity/resource contract. It is not a baseline comparison result, real two-machine/TB5 qualification, throughput result or production integration claim. The source draft is ready for root integration; actual ABI/record/native behavior remains to be exercised.

CPU recipe: `python3 -m unittest -v test_stage_rank_launcher.py` from this directory. Tests cover exact model/argv admission, report and history mismatches, wrong frame order/ack, release flags, signed zero, finite/duplicate JSON, allowed stage-local identity differences, common digest disagreement, successful fake execution, deadline, peer failure and memory-triggered retirement.
