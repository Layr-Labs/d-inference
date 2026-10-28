# Private build after root review/slot grant

Use a new owned workspace copied from `/Users/developer/DarkbloomDev/cluster-research/qwen-mtp-target-verification-build-20260915/workspace`. Revalidate the base source/dependency snapshots, preserve the old workspace/cache, and apply `runtime.patch` to the new copy. Do not apply this fixture define or Package target to MAIN. Any cache clone must receive the same path normalization and private ModuleCache handling used in the passed target-verification build.

With `WORKSPACE` and `SCRATCH` bound to the new private paths, the build arguments are:

```text
swift build --package-path WORKSPACE/libs/darkbloom-cluster-worker
  --scratch-path SCRATCH -c release --jobs 2
  --disable-automatic-resolution --skip-update --disable-build-manifest-caching
  --triple arm64-apple-macosx26.2
  -Xcc -target -Xcc arm64-apple-macosx26.2
  -Xswiftc -DQWEN_TARGET_TINY_FIXTURE
  --product TargetVerificationSessionCheck
```

The define is deliberately supplied to the entire private Swift closure because the fixture authority is compiled in the Runtime dependency. The existing ordinary product paths do not select this authority. A normal build without the define must retain the original registered-only Runtime behavior; do not attempt to build the new fixture executable without it.

After a terminal successful build, retain the exact argv, source/dependency pins, stdout/stderr, vtool minimum-OS observation and binary/resource hashes. Pure `TargetVerificationSessionCheck check-arguments` invokes no fixture/native-array work. The closed GPU command is `TargetVerificationSessionCheck run-tiny-session-on-gpu`; only root may run it under the reviewed standalone supervisor with the canonical gate and resource checks. The binary itself retains the gate and alarm through final bounded publication.

The local author check is:

```text
python3 -B /Users/developer/DarkbloomDev/cluster-research/qwen-mtp-target-session-draft-20260915/check_source.py
```

That is source/metadata validation only, not Swift compilation or native execution. Preserve this frozen derivative if a build or numeric check finds a correction; use a separate correction overlay and retained failed receipt.
