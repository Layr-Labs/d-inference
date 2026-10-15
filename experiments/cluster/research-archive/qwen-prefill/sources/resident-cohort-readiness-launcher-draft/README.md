# Private model-free cohort readiness checks

This source proposal runs one fresh, local two-rank readiness scenario per invocation. It uses the actual closed native `qwen-long-prefill-cohort-readiness-check` entry and the existing cohort exchange. It does not load a model, materialize weights, execute requests, inspect resident reuse, or qualify throughput or physical transfer. The native fixture's arithmetic and resource identities are CPU fixture metadata; the parent performs its own saved OS resource observations.

Root owns all actual execution. The proposal has only fabricated CPU tests and source checks. Its native entry is frozen separately in `resident-cohort-readiness-check-draft/manifest.json`; the explicit native SHA must identify root's subsequent integrated release. Existing launchers and public runtime files are unchanged.

Use a new output directory for each scenario, with an existing parent. Replace `ROOT_SUPPLIED_NATIVE_SHA256` with the exact root-verified release SHA before invoking any command:

```sh
python3 -B /Users/developer/DarkbloomDev/cluster-research/resident-cohort-readiness-launcher-draft/launch_readiness.py \
  --runtime /Users/developer/DarkbloomDev/d-inference/experiments/cluster/runtime \
  --release /Users/developer/DarkbloomDev/d-inference/experiments/cluster/inference/.build/release \
  --expected-native-sha256 ROOT_SUPPLIED_NATIVE_SHA256 \
  --scenario match \
  --output /Users/developer/DarkbloomDev/cluster-research/runs/resident-cohort-readiness-match-20260914

python3 -B /Users/developer/DarkbloomDev/cluster-research/resident-cohort-readiness-launcher-draft/launch_readiness.py \
  --runtime /Users/developer/DarkbloomDev/d-inference/experiments/cluster/runtime \
  --release /Users/developer/DarkbloomDev/d-inference/experiments/cluster/inference/.build/release \
  --expected-native-sha256 ROOT_SUPPLIED_NATIVE_SHA256 \
  --scenario warmup-mismatch \
  --output /Users/developer/DarkbloomDev/cluster-research/runs/resident-cohort-readiness-warmup-mismatch-20260914

python3 -B /Users/developer/DarkbloomDev/cluster-research/resident-cohort-readiness-launcher-draft/launch_readiness.py \
  --runtime /Users/developer/DarkbloomDev/d-inference/experiments/cluster/runtime \
  --release /Users/developer/DarkbloomDev/d-inference/experiments/cluster/inference/.build/release \
  --expected-native-sha256 ROOT_SUPPLIED_NATIVE_SHA256 \
  --scenario missing-peer \
  --output /Users/developer/DarkbloomDev/cluster-research/runs/resident-cohort-readiness-missing-peer-20260914
```

All three commands configure two owned directories, `rank-0` and `rank-1`, with one shared `bundle`. The existing allocator binds both IPv4 loopback ports concurrently during selection. Missing-peer starts only rank 0, using the ordinary `match` native case; it exercises startup cancellation only. No SSH path is admitted. Both `rank.json` and `hosts.json` are retained and rechecked; `input_files` is empty and no model directory is supplied.

The native argument list contains exactly five pairs: mode, loopback transport, fresh epoch, readiness case, and a 30-second native timeout. Match and mismatch have a 45-second parent execution/validation deadline; missing-peer has a 3-second deadline. Stream reads, resource observations, and final success or mismatch validation are charged before an accepted result. Cleanup retains the unchanged bounded worker/process controls separately from the execution deadline.

Match requires two native exits of zero, two closed success records with identical complete admitted cohort descriptors, and exactly the source-bound loopback warning in each stderr. The CPU validator independently derives all three fresh UUIDs, A/B/A raw prompt hashes and full recorded-request fingerprints, plus the descriptor and readiness digest recipes. Plan, arithmetic-environment and resource-admission fingerprints remain source-bound native metadata, not independently derived claims.

Warmup-mismatch requires rank 1's exact disagreement diagnostic and exit 1 while rank 0 is still observed running, before the parent deadline, with no stdout from either rank. Root then retires rank 0 through the existing cancellation path. Missing-peer requires the parent deadline, an observed-running rank-0 supervisor immediately before cancellation, a later nonzero exit, empty stdout and exactly the loopback warning. An already exited child discovered after a slow observation cannot qualify as parent cancellation. Unexpected errors, early success, extra diagnostics and missing required evidence fail the scenario. `scenario_passed` for an expected negative is separate from `native_success`, which stays false.

Before launch, actual free memory must be at least 1 GiB. Pressure must stay at or below 2 and reported swap must not increase from the initial observation; pre-existing swap is not called zero. The driver records observed supervisor/native PID, group, command and RSS relationships, then checks the exact owned identities after cleanup. Missing samples remain missing. It explicitly reaps the local supervisors; native waitpid ownership comes from the unchanged pinned worker, not an independent parent observation.

The reused source helper archives all current inference Swift sources, runtime Python/Markdown, build/package files and dependency identities, and checks live and archived source, bundle and launcher bytes before and after. The binary is copied into the new bundle and checked against the explicit SHA. Source drift, remaining owned processes or any postflight error leave the parent failed even if native records passed. Primary, cleanup and post-run failures are retained separately. No sidecars or model inputs are read.

The focused test command is `python3 -B -m unittest -v test_readiness` from this directory. Every test prohibits real subprocess and socket creation and uses temporary invented files/processes. `check_source.py` reads only source files, replays the source-warning contract against the frozen native proposal overlay, checks Python 3.9 syntax, and verifies the exact reused files; it does not invoke the launcher or native code.
