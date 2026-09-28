# Readiness launcher V2: optional explicit bundle reference

This is an additive private launcher variant. The original frozen V1 manifest
`3dd5754d56f12101e80d29bb5d24bb1f18fcfc33622c54a70174675d791cc6a3` and all
earlier run evidence remain unchanged. Six runtime helpers and the original
25-test file are copied byte-for-byte. Only `launch_readiness.py` changes; it
uses the exact `owned_bundle_reference.py` helper SHA
`c4832e457307f683f5aff55cafefe6feeeaf6a69ad1be2dc220325f96f5da8a4` already
reviewed for the constructor driver.

Add both optional flags, or omit both to retain ordinary snapshot creation:

```sh
python3 /Users/developer/DarkbloomDev/cluster-research/resident-cohort-readiness-launcher-v2-draft/launch_readiness.py \
  --runtime /Users/developer/DarkbloomDev/d-inference/experiments/cluster/runtime \
  --release /Users/developer/DarkbloomDev/d-inference/experiments/cluster/inference/.build/release \
  --output /Users/developer/DarkbloomDev/cluster-research/runs/cohort-readiness-match-reuse-20260914 \
  --expected-native-sha256 8574bb893e147c554880faf0e2e7f501c692a6a1f8812db7772cc3d782b7d946 \
  --scenario match \
  --reuse-bundle /Users/developer/DarkbloomDev/cluster-research/runs/dense-constructor-27b-nocache-20260914/bundle \
  --expected-bundle-manifest-sha256 f57b7bfd99430f3bcdbbd425b7f5d810ebad41f4ee2f89ae710f6760113ceb55
```

Root owns this command. For `warmup-mismatch` and `missing-peer`, use that
scenario name and a different new output directory. Each invocation gets a new
epoch, source/launcher archive, rank configs, observations and receipt. Reuse
creates only an explicit `output/bundle` symlink to the previously created
bundle; it never copies, chmods or modifies the original. The manifest/native
pins above are from the retained constructor prelaunch refusal, not a claim
that that run executed or qualified readiness.

The shared helper checks owned read-only regular files, directory ownership,
exact bounded manifest/tree, native and file hashes, both requested/resolved
paths, and bundled Python helper equality to the fresh runtime archive. The
entry checks the reference before the unchanged final memory screen and adds
an independent postflight action. Reference drift is recorded even if the
existing source/bundle/launcher verification also fails. Successful recheck sets
`bundle_reference_unchanged_after_run`; any postflight failure still fails the
scenario.

Opt-in receipts add `bundle_acquisition=reused_external_reference`,
`bundle_copied_for_this_run=false`, the helper pin, and the shared reference
record containing explicit paths and manifest/native/runtime hashes. The old
archive verifier remains active. Bundle hashing still reads the existing files;
reuse eliminates copying and does not promise zero IO or memory overhead.

The unchanged rules still require initial/prelaunch actual free >=1GiB,
pressure<=2 and no new reported swap. Native timeout remains30 seconds; parent
execution/validation limits remain45 seconds for match/mismatch and3 seconds
for missing-peer. Expected negative scenarios remain distinct from native
success. Cancellation, reaping, model-free DTOs, output bounds, scheduling,
native arithmetic/resource descriptor limits and numerical separation remain
as documented in V1. No model, payload, resident reuse, physical transport or
throughput is qualified by this launcher.

The unchanged25 tests and four additional fake wiring tests passed (29 total).
The added tests mock bundle validation and process execution; the exact shared
helper's nine invented-bundle tests are retained in its original package. The
new cases cover all three scenario routes without copying, prelaunch refusal,
independent source/reference postflight failures and paired-argument rejection.
No actual bundle validation, native/compiler/SSH job, model payload or candidate
read was performed while producing this V2 package.
