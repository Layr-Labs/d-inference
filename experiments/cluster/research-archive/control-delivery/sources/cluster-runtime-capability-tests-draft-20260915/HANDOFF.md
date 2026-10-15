# Package-local capability checks

2026-09-15. This isolated proposal adds 12 test/fixture files. No main, package manifest, runtime, worker or native-build source was changed. `integration.json` is the complete add-only map; `tests.patch` contains the text delta. Preserve executable mode on both `run.sh` files.

The shared package gets `Tests/CapabilityChecks`: a 98-line Protocol fixture, one canonical descriptor and a runner that also reuses the unchanged seven-group Protocol test. The worker package gets its own `Tests/CapabilityChecks`: separate metadata, input/argument and small assertion helpers, two exact metadata files, five-child command checks and a pure-source runner. There is no new general test framework or copied runtime implementation.

Both runners are package-relative:

```sh
libs/darkbloom-cluster/Tests/CapabilityChecks/run.sh
libs/darkbloom-cluster-worker/Tests/CapabilityChecks/run.sh
```

They use Swift 6 warnings-as-errors and Foundation/CryptoKit source closures. They neither invoke SwiftPM nor link the MLX/Cmlx model runtime. The command executable is a CPU fixture compiled with the actual `WorkerCapabilityInput` and `WorkerCapabilityCommand`, plus the actual pure metadata producer. It is not the full native worker. No external weights, private directory, live service, network or GPU is required.

The Protocol fixture has an explicitly fabricated binary hash of 64 ones. Its Plan/profile/arithmetic identities come from the already passed producer and are checked again by the worker metadata suite. The two configuration/manifest fixtures total 5,803 bytes and decode exactly from existing public retained metadata, preserving its registered hashes. No canonical tensor list or checkpoint payload is copied. `fixture-lineage.json` records the derivation; package-local READMEs explain the fixtures without private paths.

Actual isolated runner checks passed:

- Protocol: 3 accepted / 54 rejected cases, plus all 7 unchanged original Protocol groups; 2.95 seconds.
- Metadata/input: 4 accepted / 13 rejected cases, plus 5 actual CPU child processes; 5.30 seconds.
- Both stderr streams empty. Every compiled main source still matches the frozen capability closure `77d910d9f54d9f5219bde6705fe67335493d3d2363e5463f4a15d15f71314f6e`; all copied test-workspace bytes match the proposal. Proposed files contain no private absolute paths.

The final receipt is `records/checks.json`, SHA `2e8d01617e63c3013a3523744c68bbabf97503c69d9275ad0d33c1bb2cf500ac`. The test-only workspace used symlinks to the current main source directories and exact copies of these proposed fixtures. Those workspace links are excluded from the promotion map and frozen manifest. Current runtime behavior, native build validation and installation qualification remain unchanged.

The migrated refusal cases preserve the private codec coverage, including unknown model/profile/partition/policy, duplicate keys, Boolean/fraction/exponent/overflow handling, noncanonical bytes, incomplete stage coverage, altered/oversized metadata and FIFO/symlink/argument refusal. The metadata suite now explicitly counts the actual producer/golden comparison as a positive case. Original source-preservation proof for the capability runtime stays in its frozen implementation package; these maintainable tests assert behavior and native metadata identities rather than freezing implementation text forever.
