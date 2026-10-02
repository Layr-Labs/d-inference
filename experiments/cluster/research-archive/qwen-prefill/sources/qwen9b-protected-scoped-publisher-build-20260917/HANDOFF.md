# Scoped synchronous publisher correction

The real runtime6 compilation preserved the same Swift borrowed-closure error as runtime5. The earlier thunk alone does not resolve the compiler's reentrancy restriction. This successor changes only `QwenProtectedEvidenceExport.swift`, replacing that invocation with a `withoutActuallyEscaping(publisher)` scope around the same synchronous call. The checker remains borrowed, both public/internal nonescaping signatures remain unchanged, and all existing before/after live checks remain. The publisher is never stored, returned, or queued. Swift's dynamic check still rejects actual escape from the temporary scope. No `@escaping` API widening or `withoutActuallyEscaping` on the live checker is introduced.

The exact native source change is `367dc5ab811e9188ba6bcb7889bdbfaa4ff2079efd0091caa4829ef42523981e` to `82ec33138efb8d5b6f19f00b5500adfbb81a63326962a17d739169507edd15b8`. `original.swift` and `runtime.patch` retain the exact preimage/inverse. Existing Runtime and Worker tests, protocol, descriptor, policy, resources, record budgets, sink and same-owner Provider path are unchanged. No new payload allocation or retained payload is added by this compiler-level callable scope.

Root granted a bounded tiny compiler experiment. Three matching optimized Swift6 object compilations, jobs2 and20s bounds each, produced: baseline expected borrow rejection in0.984s, two outer `@escaping` signatures compiled in0.200s, and this scoped form compiled in0.210s. Each compiler naturally exited and was reaped with no owned group left. No executable ran. Root accepted the scoped form to preserve the original signatures. These actual tiny sources/outputs/objects/receipt are pinned by `parent-evidence.json`; they prove this type pattern compiles, not that the full numerical runtime has passed. The initial type-check-only probe passed its compiler phase and therefore failed its harness expectation; that preserved result established that object generation was necessary to reproduce the actual error.

This is a same-cache source successor to frozen wrapper `7bb73e803ce0e391a24b267a9dab11a5f67b0de292ceb0d504e98ec7b118ca5f`. It uses the actual prepared3081-source/9832-dependency snapshot6 without cloning a tree or changing dependency revisions. Preparation preserves the actual367dc preimage, verifies the original canonical native `dd277746f02ef87e00a517b63932a111ea986b1a4c361718ba8cf05012d9dd70` remains in cache and in its existing immutable backup, changes exactly one source file, and emits snapshot7. Both failed full-runtime attempts and the original tiny experiment remain untouched.

Eight helper/contracts are byte-exact to7bb: owned process/check helper, result parser, controls, canonical description contract, expected capability, exact expected tests and description validator. `run_checks.py` and `package_native.py` differ only in snapshot6→7 filenames. The four small wrappers advance the predecessor/source snapshot and output names, preserving original process, compile and native deadlines. Runtime38 XCTest+7 Swift Testing, Worker19, capability checks and four already-qualified fabricated comparator controls remain required through the retained source/evidence lineage. No assertion or numerical gate is weakened.

Future root-granted commands, strictly sequential from this directory:

```
python3 -B run_phase.py prepare
python3 -B run_phase.py runtime
python3 -B run_phase.py worker
python3 -B run_phase.py capability
python3 -B run_phase.py native
python3 -B run_phase.py package
```

Every output is create-only under `root-*-7`, `preparation-7`, the phase directory or `runtime-bundle-7`. Each next phase requires the preceding matching result. Same full source/dependency identities, checkout revisions, actual child reaping and canonical metadata validation are rechecked. Failure evidence is retained rather than overwritten or automatically retried. The new source wrapper has not been prepared or executed by its author; compiler ownership was explicitly released after the tiny probe. No full runtime build, model, GPU, remote or physical transport qualification is claimed.

Provider wrapper `c7eaffe30f9bda2923429770a665ca028c221060ccdb57e8847af5029c32886d` and all four numerical Provider files are unchanged by this native-only correction. Physical use still needs the matching actual native artifact/descriptor, full tests, TLS and authority qualification, both original owner cleanup receipts, resource checks and independent full-row/state comparison.
