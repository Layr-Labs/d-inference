# Decode benchmark harness, 2026-09-20

This subtree reuses the completed resident benchmark supervision. It does not enable serving, encrypted transport, a new workload, or weaker resource admission. No native executable, metallib, model weight, or dependency tree was copied by this author. No compiler, SSH, purge, deployment, native, or GPU operation was executed by this author.

`source-inputs.json` (`7c58c28ab3dc0d44885415063b898505d2b14b32bfe5650385062d41813778f1`) freezes the basic package before root deployment. `copy-provenance.json` records exact source paths, preimages, postimages and reversible substitutions for 33 files (290,546 bytes). The only copied operational-source change is the exact namespace `gemma4-resident-benchmark-20260920-v7` → `gemma4-decode-benchmark-20260920-v1`. The copied overlap comparator is relocated to this directory, and its reader's path/hash is updated accordingly. `alias.py`, `lease_source.py`, `compare_results.py` and the reviewed `owned_process.py` are necessary unchanged dependencies. Python caches were excluded.

All original native300s / parent315s / SSH345s bounds, canonical device lock/journal, peer failure cancellation, alias retirement, 6 GiB actual-free floor, AC, pressure1, zero swap, continuous native resource ledger and exclusive CREATE/install behavior remain. Outer controller timeout is 1020s so the existing 625s alias-expiry path and two bounded180s collections can finish. An outer timeout remains a failure and does not prove remote retirement; the remote owners retain their original independent cleanup obligations.

Root supplies the actual native path/build receipt. `root_run.py deploy-prepare --name prepare-1 --binary ABSOLUTE_NATIVE --build-receipt ACTUAL_BUILD_JSON` requires an actual successful/reaped compiler receipt, checks the exact binary hash/size, then invokes unchanged `deploy.py prepare`. It does not invent an artifact identity. Each root action creates fresh regular `root-actions/NAME/{stdout,stderr,receipt.json}` files, owns a new local process group through the retained helper, records actual exit/reaping/group absence and rechecks the basic source manifest. No action has been run by this author.

Typical root sequence, from this directory (every action name must be fresh):

```sh
python3 -B root_run.py deploy-prepare --name prepare-1 --binary ABSOLUTE_NATIVE --build-receipt ACTUAL_BUILD_JSON
python3 -B root_run.py install --name install-24-1 --host darkbloom-24
python3 -B root_run.py install --name install-48-1 --host darkbloom-48
python3 -B root_run.py case-prepare --name case-1 --case p4096-cut7-c64-serial-v1 --prompt 4096 --cut 7 --chunk 64 --policy serial --capture
python3 -B root_run.py metadata --name describe-full-1 --case p4096-cut7-c64-serial-v1 --mode full
python3 -B root_run.py prepare-memory --name memory-before-solo-1 --case p4096-cut7-c64-serial-v1
python3 -B root_run.py solo --name solo-1 --case p4096-cut7-c64-serial-v1
python3 -B root_run.py case-prepare --name case-2 --case p4096-cut7-c64-overlap-v1 --prompt 4096 --cut 7 --chunk 64 --policy oneChunkLookahead --capture --match p4096-cut7-c64-serial-v1
python3 -B root_run.py metadata --name describe-stage0-1 --case p4096-cut7-c64-overlap-v1 --mode stage0
python3 -B root_run.py metadata --name describe-stage1-1 --case p4096-cut7-c64-overlap-v1 --mode stage1
python3 -B root_run.py prepare-memory --name memory-before-pair-1 --case p4096-cut7-c64-overlap-v1
python3 -B root_run.py pair --name pair-1 --case p4096-cut7-c64-overlap-v1
```

Metadata uses a separate create-only remote metadata directory. It verifies the installed package, exact native/job hash, canonical quiescence, and runs only `--describe` or `--check-arguments` with a 15s owned child, retaining real stdout/stderr and cleanup receipt. It verifies that no sidecar output was created. The outer SSH call is bounded40s and root action50s. It neither launches `--execute` nor populates the inference run directory. This is an additive local helper; it changes no frozen package member.

The copied `compare_results_v2.py` retains its original three-role **serial** scope. The copied `compare_results_overlap.py` retains its original five-role scope (solo + serial pair + lookahead pair). Neither accepts a missing serial pair. Arithmetic's separately reviewed comparator owns root's requested solo + lookahead comparison; no substitute comparator was added here. Existing analyzers retain their exact validation, with the overlap module read from this local copy.

`check_source.py` replays every source transform and pin, parses all29 Python sources plus the remote metadata body, and imports27 modules with subprocess creation blocked. This is source/import qualification only; execution and all numerical/performance/resource acceptance remain root-owned. Root may already have subsequent physical/deployment evidence; that is separate from this author's freeze.
