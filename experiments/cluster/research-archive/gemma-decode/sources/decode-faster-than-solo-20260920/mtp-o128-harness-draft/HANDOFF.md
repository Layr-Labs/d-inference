# Bounded O128 local and remote MTP harness

This source successor accepts exactly full P128 or P4096, C64, cut7, BF16, and explicit O16 or O128. O16 remains the default. Local and remote choose verification depth1 or2; the remote producer still has depth2/five-buffer capacity. Only the packed-head policy is accepted.

`prepare.py` creates three new directories under this directory's parent: `harness-local-mtp-o128-v1`, `harness-remote-mtp-o128-v1`, and `remote-mtp-o128-numerical-v1`. Existing harnesses, actual runs and failed receipts remain unchanged. Preparation reads source/build receipts only. Deployment independently hashes actual native/resource bytes through the original activation path.

The final121-source map is acfb284f/ac946fa6 and the actual applied receipt is2e5d0419. Native identity is taken only from the successful build receipt. Exact packed116 predecessor/qualification, depth39db, guard ea157, output7db, and strict control reader69f remain separately bound. Remote reports must use `gemma4_remote_control_resource_boundaries_v1`; counters must join actual wire-wall record counts. Legacy policy reports are refused.

Timing uses three measured requests: `3*(O-1)` decode tokens (45 or381), and `3*P` prefill tokens. Numeric comparison reads four complete final vocabulary rows, all90 native state components for each of four requests, and every generated ID (64 or512). Full attention retains `[0,F)`; sliding attention retains `[max(0,F-1024),F)`, where `F=P+O-1`. State geometry, position bytes, chronological ranges, dtype, all raw bytes/hashes and fingerprints remain exact. No tolerance is added. Per-file16MiB, 4GiB archive, native300s/parent315s, alias600s and original6/4/2GiB resource floors are unchanged. A future F32 full cache above the16MiB cap refuses; this is a BF16 workload extension.

Author ran source/pin/AST checks only. No fixture, compiler, model, remote, deployment or sidecar replay was run. Root independently ran the predecessor7-depth/9-control CPU checks. New15 workload/resource controls are staged. The copied7/9 methods are also available here with imports directed at the composed projection. The remote harness retains17 original controls with only O128 boundary and exact new-counter fixture updates.

From this directory, root commands:

```sh
python3 -B prepare.py --check
python3 -B -m unittest discover -s Tests -p 'test_*.py' -v
python3 -B prepare.py --prepare --build-receipt /Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/build/remote-control-build-1/receipt.json --sources /Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/build/remote-control-composition-1/sources.json
```

In either new physical harness use the unchanged `root_run.py` deploy/install/metadata/run/compare lifecycle. Add `--output-count 128` to `case-prepare`, with `--prompt 128` or4096 and `--capture` for numerical evidence. Local ordinary uses `--native-operation execute-solo`; local MTP uses `--native-operation execute-local-mtp-dense-head --depth 1` or2. Remote uses `--depth 1` or2 and the original exact embedding identity. All cases use fresh names/UUIDs. Same-build ordinary must run in the new local harness and have capture enabled.

Local numeric replay uses new local `numerical_compare.py` with unchanged flags: `--ordinary-case`, `--mtp-case`, `--build-receipt`, `--source-receipt`, `--native-file`, `--package-manifest`, `--prompt-file`, `--output`. Remote numeric replay uses new numerical `compare.py`: `--ordinary-case`, `--ordinary-package-manifest`, `--remote-case`, `--native-file`, `--prompt-file`, `--output`. Both require accepted physical receipts, exact same native bytes/workload and create-only output. Remote script joins the new exact counters again before sidecar reading. No result or speed claim exists until actual physical and full numerical comparison complete.

The projection contains only changed source files. `harness.patch` shows each original-to-final change; `stage-state.json` records count/namespace edits after exact depth/control overlays. `projection.json` pins all bases, dependencies, producer state sources and the complete actual native map. Mathematical row/state byte decoders and process/resource/lease readers remain byte-exact except the explicit workload/state-range generalization in the orchestration reader.
