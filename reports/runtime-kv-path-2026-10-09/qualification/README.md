# Whole-model runtime KV qualification

This directory contains the reproducible offline input generator and serving
runner for the new KV implementation. The catalog and manifests are the public
coordinator's 2026-10-09 snapshot. Each available artifact was verified against
every manifest file hash before execution. `verify_models.py` creates owned
hard links to matching immutable local files; it does not repair source caches.

`prepare_suite.py` creates four deterministic long-context tasks and one
original-prose continuation per model. It uses each exact artifact's tokenizer
without remote code. The tasks cover distributed record retrieval, arithmetic,
program evaluation and a longer distributed retrieval case. Their generated
answers are scored by the last JSON object after a closing thought marker,
requiring a normal stop; truncated reasoning is a failure even if it mentions
the expected answer. The continuation provides identical token contexts for
native/packed teacher-forced NLL and top1 comparisons, with repeat controls.
This small synthetic suite measures bounded drift and does not establish broad
benchmark accuracy.

`freeze_candidate.py` copies an already-built developer executable, its exact
source-matched metallib and SwiftPM resource bundles to an independent owned
directory. Its receipt binds compiled-source files, source revisions, the build
log, executable, metallib and every resource file. These loose artifacts are
qualification builds; they are not published signed/notarized app bundles.

`run_suite.py` verifies that receipt, runs each model/profile sequentially and
preserves raw JSON, stderr, complete commands and hashes. It checks exact model
aggregate identity, the actual paged backend and the resolved precision.
Failed or unparsed results remain in the manifest; existing evidence is never
overwritten. Periods in model IDs remain part of distinct task/profile filenames.
The script supports the system Python 3.9 on the remote M5 host.

Example:

```sh
python3 prepare_suite.py --output /owned/inputs \
  --model-root /owned/verified-models --catalog ../catalog.json
python3 freeze_candidate.py --root /checkout --binaries /checkout/provider-swift/.build/debug \
  --output /owned/candidate --build-log /owned/build.log
python3 run_suite.py --candidate /owned/candidate --config /owned/provider.toml \
  --inputs /owned/inputs --output /owned/results \
  --models gpt-oss-20b gemma-4-26b-8bit qwen3.6-35b-a3b-vl-mtp-mxfp8 --scores
```

AR generation uses the production CBv2 slot with cache reuse disabled, fixed
template date, greedy sampling and MTP off for the paired controls. Separate
`--mtp` runs request the artifact's actual policy and retain proposed/accepted
round counts through the production metrics projection. Ordinary scalar AR
benchmarks do not exercise this cache. Teacher-forced observations do not
certify sampler, scheduler or speculative verification behavior.

Cache page commitment and host-observed KV usage describe different owners;
recurrent and original-band allocations remain counted. Host samples can miss
prefill transients. MLX peak memory is retained separately, and timing includes
no claim of a speedup. All raw qualification evidence lives in the task's owned
local/remote output directories; curated report metrics bind their hashes.

`curate_runs.py` verifies each retained raw JSON/log hash against its run
manifest and requires matching executable/metallib hashes in the measured
schema: nested `runtimeIdentity` for generation or flat identity fields for
scores. Missing, malformed, mismatched or contradictory identities refuse
curation. Native top1 comparisons also require a parsed native score peer in
the same manifest, its matching raw hash and both verified artifact identities;
unlisted or unparsed files do not contribute. It produces a compact summary
with answers, measurements and finite/repeat/top1 score observations. Failed and superseded stages remain
separate; the dated report names the usable cohorts. CPU regressions exercise
the actual CLI with changed execution identities and unchanged raw-hash validity.

```sh
python3 curate_runs.py --root /owned/qualification \
  --stages candidate03-m4-matrix candidate07-m5-gemma-mtp \
  --output /owned/curated-runs.json
```

Measured outcomes and boundaries are recorded in the
[October 9 qualification report](../../../docs/reports/2026-10-09-runtime-kv-quantization.md).
