# Packed-head local MTP harness

Source only; preserves serial harness1015 and resource-binding correction9b4. The original base39 files and serial overlays are source-verified, then transformations.json replays exact namespace/operation/policy substitutions. All numerical helper definitions outside compare() remain exact. Original deadlines, leases, process/journal/resources, four separately rounded1MiB head rows and same-build comparison stay unchanged.

This namespace accepts only gemma4_verification_packed_m1_dense_packed_head_v1. Native source must be the exact ad942 five-file activation over c868, with all116 source entries and explicit ancestry fields. The successful packed-width prerequisite4c6a (24fullrows/360states, no tolerance) is required. Actual new source/build/native SHA and size are late-bound from successful build, then the original deployment hashes actual binary/resources. No future identity is guessed. Resource matching uses the already-reviewed exact two-name bijection, independent of list order.

Root source check and thirteen CPU controls, not run by author:

```
python3 prepare.py --check
/usr/bin/python3 -B Tests/test_packed_contract.py
```

Root preparation after actual new build:

```
python3 prepare.py --output /Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/harness-local-mtp-packed-head-v1 --build-receipt ACTUAL_BUILD --sources /Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/build/packed-head-activation-composition-1/sources.json
```

Then unchanged root_run.py deploy-prepare/install actions, using actual new native/build/source paths. Remote create-only namespace: /Users/developer/DarkbloomDev/gemma4-local-mtp-packed-head-20260920-v1. Prepare fresh same-build P128/C64/O16 capture cases:

```
python3 root_run.py case-prepare --case p128-solo-capture-1 --prompt 128 --native-operation execute-solo --capture
python3 root_run.py case-prepare --case p128-packed-d1-capture-1 --prompt 128 --depth 1 --native-operation execute-local-mtp-dense-head --capture
python3 root_run.py case-prepare --case p128-packed-d2-capture-1 --prompt 128 --depth 2 --native-operation execute-local-mtp-dense-head --capture
```

For each, unchanged metadata/run/compare actions. After physical retirement, use numerical_compare.py for each depth versus this fresh same-build solo. Exact arguments are unchanged from the serial harness: --ordinary-case, --mtp-case, --build-receipt, --source-receipt, --native-file, --package-manifest, --prompt-file, --output. Each output is create-only and requires all64 IDs/four complete final262144rows/360state components, exact native bytes/dtypes/shapes/frontiers and complete physical joins. Different fresh per-case UUIDs are validated against their own source inputs, not mistaken for semantic mismatch.

Then fresh P4096 timing cases without capture, same solo/d1/d2 build/prompt/workload. Current native admission remains O16. This harness does not qualify O128 or infer a faster-than-best-solo result from a short forced-width prerequisite. Defaults and serial namespace remain unchanged.
