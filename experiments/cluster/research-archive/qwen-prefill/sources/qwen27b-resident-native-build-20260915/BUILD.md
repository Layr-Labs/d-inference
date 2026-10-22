# Private 27B native validation workspace

The workspace is ready for root's compiler slot. No compiler, native entry, model load or remote operation has run here.

`source-snapshot.json` pins all3038 members of the four current MAIN package trees after applying exactly the frozen eight Runtime files, two private worker replacements and five staged test methods. `main-source-preimages.json` preserves the original source bytes' hashes. The frozen overlay remains unchanged (`09d4866d…e75b4`). There are no MTP proposal/loading overlays in this workspace.

Both scratch directories are independent APFS clones of the idle MAIN worker cache. Only private generated JSON/YAML paths were rewritten; the old path-dependent ModuleCache directories were retained outside scratch. No MAIN cache or arithmetic cache was modified. `dependency-source-snapshot.json` pins8755 source files from31 existing checkouts and their revisions; both clones matched those bytes. Source Package.swift/Package.resolved files are unchanged except the explicitly listed private source patches, which do not alter package manifests.

`commands.json` gives the full argv, environment, timeout and selected method counts. Run steps sequentially after root releases the compiler slot. Save each command's stdout/stderr and exit status in a fresh result directory, then rerun source verification. Use the existing root process-group watchdog for compiler timeouts; no command runs the model worker after building it.

```sh
cd /Users/developer/DarkbloomDev/cluster-research/qwen27b-resident-native-build-20260915
python3 verify_sources.py
/bin/bash /Users/developer/DarkbloomDev/cluster-research/qwen27b-resident-native-adapter-draft-20260915/Tests/run.sh
```

Runtime metadata tests (13 existing9B +3 new27B):

```sh
DARKBLOOM_RETAINED_PROFILE_FIXTURE=/Users/developer/DarkbloomDev/cluster-research/qwen27b-resident-native-adapter-draft-20260915/Tests/retained-inputs.json \
swift test --package-path workspace/libs/darkbloom-cluster \
  --scratch-path workspace/libs/darkbloom-cluster/.build-native-runtime \
  -c release --jobs 2 --disable-automatic-resolution --skip-update --disable-build-manifest-caching \
  --triple arm64-apple-macosx26.2 -Xcc -target -Xcc arm64-apple-macosx26.2 \
  --filter 'ResidentFacadeTests|NativeValidationAdmissionTests'
```

Worker parser/lifecycle tests (9 existing +2 new27B):

```sh
swift test --package-path workspace/libs/darkbloom-cluster-worker \
  --scratch-path workspace/libs/darkbloom-cluster-worker/.build-native-worker \
  -c release --jobs 2 --disable-automatic-resolution --skip-update --disable-build-manifest-caching \
  --triple arm64-apple-macosx26.2 -Xcc -target -Xcc arm64-apple-macosx26.2 \
  --filter 'WorkerTests|NativeValidationWorkerTests'
```

Build the existing worker target with its private27B entry and the same explicitly pinned metallib:

```sh
/bin/bash workspace/libs/darkbloom-cluster-worker/build-native-worker.sh \
  /Users/developer/DarkbloomDev/cluster-research/qwen27b-resident-native-build-20260915/workspace/libs/darkbloom-cluster-worker \
  /Users/developer/DarkbloomDev/cluster-research/resident-cache-off-package-20260915/bundle/mlx.metallib \
  2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2
python3 verify_sources.py
```

That existing script requires native JACCL symbols, exact macOS26.2 deployment and the matched metallib. Root should also retain the owner-bootstrap callback symbol, binary/resource hashes and actual build/test records. A successful compile does not establish27B loading, arithmetic, memory fit, accepted execution, installed capability or performance. The ordinary product worker and provider policy remain unchanged.

Root has separately rehashed the local14-file27B payload and is copying it over authenticated LAN. That operation and future two-Mac qualification are outside this source workspace; no new payload verification is claimed here.
