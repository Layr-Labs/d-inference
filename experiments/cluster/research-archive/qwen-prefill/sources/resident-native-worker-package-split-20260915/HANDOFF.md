# Separate native-worker deployment package

This corrects package deployment metadata, without editing or patching the first linked binary. The retained first build used26.2 Swift/C++ objects and real JACCL code but linked with macOS14 minimum because the executable belonged to the shared macOS14 package. Its native SHA remains3d87bc87f2759ea66ba96356cf2de9cc9b49d2ba92c85e0482d3ce734cf9b6bd; the old build and combined source remain untouched.

The isolated layout is:

- `workspace/libs/darkbloom-cluster`: tools6.1,macOS14,Runtime and Protocol library products,88 source files plus the one runtime test file. There is no executable product/target or worker source/test directory here.
- `workspace/libs/darkbloom-cluster-worker`: tools6.1,macOS26.2,one executable product,target and its test target; depends on Runtime/Protocol products from `../darkbloom-cluster`. All five worker source files and its test file are byte-identical to the successfully tested/linked source.
- `workspace/libs/mlx-swift` and `mlx-swift-lm` are symlinks to the same pinned main dependency paths. No dependency contents or build caches were copied/changed.

`source-moves.json` maps all95 source/test files from the root's96-pin first-build input. Only the old combined Package.swift is replaced by two manifests. The private base has no Process product; when merging this change into main, retain the already reviewed main Process product/three files and ProviderCore dependencies unchanged. The private shared manifest is not an instruction to drop main Process. Normal provider/shared control deployment stays14; only the separate executable package declares26.2.

`Package.resolved` was copied byte-identically into both packages as the starting dependency lock (b2b12d24d48bbedc4583d8831e0b81fe68b96d641804e0ebc56715cd2d88a7ea). Native package graph evaluation/resolution has not been run. The script disables automatic resolution and skips updates. If SwiftPM requires a new root origin hash, root should prepare that lock explicitly and compare its revision pins to the saved lock before compiling; do not silently update dependencies or change the frozen original.

After source review and root-owned cache preparation, use:

```sh
/bin/bash /Users/developer/DarkbloomDev/cluster-research/resident-native-worker-package-split-20260915/build-native-worker.sh /Users/developer/DarkbloomDev/cluster-research/resident-native-worker-package-split-20260915/workspace/libs/darkbloom-cluster-worker /Users/developer/DarkbloomDev/cluster-research/resident-cache-off-package-20260915/bundle/mlx.metallib 2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2
```

The script targets the sibling package, with Swift triple and C++ target both `arm64-apple-macosx26.2`. The executable package platform supplies the final linker minimum. It verifies real JACCL symbols, then reads final Mach-O metadata with `xcrun vtool -show-build` and requires exactly one macOS LC_BUILD_VERSION with minos26.2 (26.2.0 accepted). An SDK version or newer objects alone do not pass. It then copies/rechecks the explicit matched metallib. No Mach-O rewriting is used.

The new scratch path is `workspace/libs/darkbloom-cluster-worker/.build-native-worker`. No scratch exists yet. Root may clone the first build's `.build-native-worker` there only after review, preserving the original and handling only the cloned relocation-sensitive caches. This package/script does not copy, delete or mutate the old scratch.

Source checks verified all95 source/test hashes, source/test ownership, manifest target/dependency placement and absence of a cache. `bash -n` passed. The exact embedded minos predicate passed nine CPU cases, including rejection of the actual first binary's minos14.0 metadata and acceptance of fabricated exact26.2/26.2.0 records. The old binary was read by vtool, not executed. These checks do not substitute for the required new native link and final vtool check.

No Swift manifest compiler, target compiler, worker, GPU/model or network execution occurred while preparing this package. Existing21 CPU tests apply to unchanged source bytes; the new package graph/target layout remains uncompiled. Root owns the next compile/link and any physical execution. Benchmark SPI/diagnostic/reference overlays remain separate.
