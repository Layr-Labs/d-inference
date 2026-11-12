# Registered-member validation wrapper

Source-only wrapper for frozen member manifest
`4ae431c60990ff9e4dfe319b8b5387ac8fb6bffcd54eac0213d3f85ed60ef965`.
No source/cache materialization, Go/Swift compilation, model, coordinator or
remote invocation has run from this package. Root owns compiler scheduling.
Current MAIN is the exact tested V2 registry base; the new member overlay stays
private. Its separate narrow lifecycle review is bbd74978.

## Source gates

Every prepare and run rechecks all 81 member manifest inputs, all 30 MAIN
preimages and 10 required absences, three byte-exact reused helpers, and the
five unchanged anonymous-metallib-binder sources/test input. No MAIN writes,
git reset/stash, dependency update or frozen overlay mutation occurs.

Go preparation computes a conservative source closure from registry, protocol
and the actual API handler package, recursively including local imports from
production and test Go files. It copies exact source, go.mod/go.sum, embedded
assets and testdata into a fresh private workspace, then rechecks all bytes.
This adds the registration-handler typecheck missing from the original narrow
member runner. Focused mode selects 15 retained verified-pair methods + 4 new
member methods; API compiles with no matching test required. Full mode runs
registry, protocol AND API tests and requires successful completion of all
three packages. No API execution claim is made for the focused phase.

Swift preparation reuses the already-reviewed inventory/closure helper. It
verifies all local package paths, then APFS-clones the CURRENT dirty source and
cached dependencies for provider-swift, darkbloom-cluster, mlx-swift and
mlx-swift-lm into a new workspace. It records exact source/dependency snapshots
before/after and preserves original SwiftPM metadata/path-bound ModuleCache.
Only private workspace-state paths are rewritten, then only the declared Swift
member delta is applied. No Package.swift/source correction is introduced.
Nested local dependency paths must close inside the new workspace.

Preparation is a separate command because cache cloning and source hashing
also require the root's resource slot. The source snapshot is taken at that
explicit preparation step. If MAIN changes a required member preimage, the
wrapper refuses; do not silently rebase. If another source changes during
copy/build/test, its exact inventory comparison refuses and retains the run.

## Commands, in order and only with the root grant

From this wrapper directory, use fresh directories for every preparation:

```sh
/usr/bin/python3 -B prepare.py --phase go --output /Users/developer/DarkbloomDev/cluster-research/cluster-registered-member-go-build-1-20260916
/usr/bin/python3 -B run.py --phase go-focused --prepared /Users/developer/DarkbloomDev/cluster-research/cluster-registered-member-go-build-1-20260916 --attempt 1
/usr/bin/python3 -B run.py --phase go-all --prepared /Users/developer/DarkbloomDev/cluster-research/cluster-registered-member-go-build-1-20260916 --attempt 1
/usr/bin/python3 -B prepare.py --phase swift --output /Users/developer/DarkbloomDev/cluster-research/cluster-registered-member-swift-build-1-20260916
/usr/bin/python3 -B run.py --phase swift-build --prepared /Users/developer/DarkbloomDev/cluster-research/cluster-registered-member-swift-build-1-20260916 --attempt 1
/usr/bin/python3 -B run.py --phase swift-tests --prepared /Users/developer/DarkbloomDev/cluster-research/cluster-registered-member-swift-build-1-20260916 --attempt 1
```

Proceed to each phase only after the prior phase passes and while retaining the
compiler grant. Go uses the exact previously tested offline Go1.25 binary,
-race/-p2, a120s per-package test timeout and300s owned-parent bound. Swift
builds the actual darkbloom CLI product with jobs2, then the focused Provider
and CLI tests, with automatic dependency resolution disabled and900s bounds.
No native model executable is run. Local WebSocket fixtures use test servers,
not registered external coordinators. Environment filtering retains existing
toolchain/home/cache locations and drops live service/database credentials;
it does not redirect HOME or change the host's environment.

The filter includes new ClusterMemberRegistrationTests/ClusterMemberLoopTests,
DistributedStartCommandTests/DistributedStartSessionFactoryTests, existing
CoordinatorClient and StartupPreload cases, EngineV2SupportedSetGateTests and
MetallibHashTests. It retains the real local ACK/old-server timeout cases and
checks their names and final Swift Testing completion in the captured output.
CLI build records the resulting binary hash/size but does not execute it.

All child commands use the same frozen unreaped-only owned-process cleanup
helper as the previous qualified runs. Every phase retains stdout/stderr,
argv/PID/exit/reap/group observation and source recheck before reporting pass.
The reused wrapper refuses diagnostic output larger than4MiB before parsing;
its process-wide file ceiling remains512MiB so legitimate compiler archives
are not corrupted by a small output cap. A failure is evidence, not permission
to change assertions. Corrections require separate source/pin receipts and new
attempt directories; the original4ae431 member freeze stays unchanged.

## Anonymous metallib binder source review

`binder-review.json` records exact unchanged Swift/C++/fixture pins. The member
CLI requires the existing binder before registration claims. It unlinks the
snapshot before copying, hashes the same copied bytes, retains the descriptor
in the static serialized binder, and refuses a changed source/digest without
rebinding. The C bridge ends at `g_metallib_path = path`, with no MLX device
acquisition or GPU operation. This is compatible with control-only member
startup. It is not protection against code already executing inside the
trusted process, nor a deadline bound on the source read. Existing binder tests
are included; the preexisting stale comment saying ProviderCore makes no setter
call is recorded but not changed by this feature.

This package validates source/role/lifecycle behavior only. It does not make
protocol ACK into attestation, approve a native bundle, issue a pair grant,
establish traffic keys or qualify encrypted RDMA. Those remain separate gates.
