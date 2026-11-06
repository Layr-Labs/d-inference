# Separate owned-batch remote experiment

This immutable harness requires exact batch124 source, actual Foundation12 success, actual successful build, and a fresh **same-build** batch tiny physical qualification plus its original comparison child receipt. It preserves packed target arithmetic, depth1|2, P128|4096/C64/O16|128, producer2/queue5, all named reserves/floors, fresh resource checks, canonical lease, group ownership and alias restoration. The only selected new policy is `gemma4_owned_snapshot_batch_gpu_boundaries_v1`. Missing batch, refill, bonus or other extra policy fields refuse. Control counts/wire joins remain exact; the new schema explicitly reports changed snapshot resource cadence and native completion fences.

Run the sibling tiny handoff first. These commands then use its preserved native/resource bundle, never a later mutable workspace binary. Root alone executes, with exclusive physical ownership:

```sh
python3 -B /Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/snapshot-owned-batch-harness-draft/remote/check_sources.py
python3 -B /Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/snapshot-owned-batch-harness-draft/remote/Tests/run.py --output /Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/snapshot-owned-batch-harness-draft/remote/cpu-controls-1
python3 -B /Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/snapshot-owned-batch-harness-draft/remote/root_run.py deploy-prepare --binary /Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/snapshot-owned-batch-harness-draft/tiny/deployment/bundle/GemmaResidentBenchmark --build-receipt /Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/build/snapshot-batch-build-1/receipt.json --sources /Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/build/snapshot-batch-composition-1/sources.json --tiny-qualification /Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/snapshot-owned-batch-harness-draft/tiny/cases/tiny-1/physical-result.json
python3 -B /Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/snapshot-owned-batch-harness-draft/remote/root_run.py install --host darkbloom-24
python3 -B /Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/snapshot-owned-batch-harness-draft/remote/root_run.py install --host darkbloom-48
python3 -B /Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/snapshot-owned-batch-harness-draft/remote/root_run.py case-prepare --case p128-o128-d2-capture-1 --prompt 128 --output-count 128 --depth 2 --capture --embedding-sha256 45259723b22ef7d5c039213763eb57a0711bdc7e897ca112b58821b3d97827a4
python3 -B /Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/snapshot-owned-batch-harness-draft/remote/root_run.py metadata --case p128-o128-d2-capture-1
python3 -B /Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/snapshot-owned-batch-harness-draft/remote/root_run.py run --case p128-o128-d2-capture-1
python3 -B /Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/snapshot-owned-batch-harness-draft/remote/root_run.py compare --case p128-o128-d2-capture-1
```

A different admitted prompt/output/depth needs a fresh case name and all four case actions. Physical acceptance is not numerical acceptance; run the exact sibling numerical replay against the fresh same-build ordinary reference. Twenty-one synthetic controls are staged; the author ran source/AST checks only. No speed, encryption or serving qualification is claimed. All outputs are create-only, failures retained.
