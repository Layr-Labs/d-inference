This fresh harness copies only 36 frozen source/helper/prompt files from `gemma4-decode-optimization-20260920/harness-v2`, manifest `e2cd5a65fa30b70ff0df31c5150050995744e531f6866f26e7dcc9be29564266`. The only copied-byte change is remote namespace `gemma4-decode-benchmark-20260920-v2` → `gemma4-decode-cpu-control-20260920-v1`. `copy-provenance.json` replays each exact transformation. No old cases, deployments, archives, binaries or root actions were copied.

The base source manifest is `1a169d0377caad5844acafe349ec4cd52ea025ab362d6597fcf43e0e4a5ad903`. Source check passed 36 exact copies, 32 Python AST parses, 27 imports with subprocess creation blocked, and remote metadata helper AST. No author compiler, native or SSH execution. Root's actual build receipt must bind `build/applied-cpu-control.json` in the parent task directory before physical activation. No native hash is guessed here.

Use the unchanged bounded `root_run.py` helper. It retains strict SSH, create-only install/run roots, canonical inherited lease, pressure/AC/zero-swap/actual-free guards, native300/remote315/SSH345 bounds, peer cancellation, original alias retirement and all raw outcomes. `--build-receipt` requires successful reaped compilation and the actual binary size/hash; the later comparator also joins the exact source composition. Root owns all following actions:

```sh
python3 -B ROOT/root_run.py deploy-prepare --name deploy-prepare-cpu --binary ACTUAL_BINARY --build-receipt ACTUAL_BUILD_RECEIPT
python3 -B ROOT/root_run.py install --name install-cpu-24 --host darkbloom-24
python3 -B ROOT/root_run.py install --name install-cpu-48 --host darkbloom-48
python3 -B ROOT/root_run.py case-prepare --name prepare-cpu-solo --case p4096-cut7-c64-serial-cpu --prompt 4096 --cut 7 --chunk 64 --capture
python3 -B ROOT/root_run.py case-prepare --name prepare-cpu-pair --case p4096-cut7-c64-overlap-cpu --match p4096-cut7-c64-serial-cpu --prompt 4096 --cut 7 --chunk 64 --policy oneChunkLookahead --capture
python3 -B ROOT/root_run.py metadata --name describe-cpu-full --case p4096-cut7-c64-serial-cpu --mode full
python3 -B ROOT/root_run.py metadata --name describe-cpu-stage0 --case p4096-cut7-c64-overlap-cpu --mode stage0
python3 -B ROOT/root_run.py metadata --name describe-cpu-stage1 --case p4096-cut7-c64-overlap-cpu --mode stage1
python3 -B ROOT/root_run.py prepare-memory --name memory-cpu-solo --case p4096-cut7-c64-serial-cpu
python3 -B ROOT/root_run.py solo --name run-cpu-solo --case p4096-cut7-c64-serial-cpu
python3 -B ROOT/root_run.py prepare-memory --name memory-cpu-pair --case p4096-cut7-c64-overlap-cpu
python3 -B ROOT/root_run.py pair --name run-cpu-pair --case p4096-cut7-c64-overlap-cpu
```

`ROOT` is `/Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/harness-cpu`. Only the solo full role and the two lookahead roles run. All have one warmup plus three measured P4096/C64/O16 requests. Preparation generates fresh UUIDs/epoch and actual native identity; `--match` deliberately shares request identities across the new solo and pair. Do not execute a new serial pair or additional captured cohort. The comparator reuses retained padded-v2 evidence and checks all tokens, full final rows, whole KV state, original same-cadence/same-budget conditions and physical cleanup. Its numerical replay belongs in root's exclusive bulk-I/O window after retirement.

Copied `compare_results_overlap.py` remains the old five-role comparator, and requires a serial pair. Do not invoke it for this three-role task. The separate new `review-cpu/compare.py` is the supported comparison for this cohort; it uses the frozen validators directly and does not relax their physical or numerical acceptance.
