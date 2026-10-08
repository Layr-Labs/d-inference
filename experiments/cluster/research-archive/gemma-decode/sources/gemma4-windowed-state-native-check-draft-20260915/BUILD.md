# Build only after an explicit compiler grant

Use a fresh owned source/cache derivative of `qwen-mtp-target-session-build-guarded-20260915/workspace`, retaining its successful source/dependency snapshots. Apply `integration.json` with exact preimage/absence guards. Do not apply this fixture product or define to MAIN. The successful base's `prepare_sources.py`, `prepare_cache.py`, `snapshot_build.py`, `build_native.py` and bounded process helper provide the existing preparation/build pattern; bind new output paths before execution and retain all failed attempts. No workspace/cache copy has been performed here.

The 28-file overlay contains the ten reviewed window-state files (the core has three exact hunks composed onto the qualified target transaction), the eight already-promoted pure Gemma metadata files, the frozen callback probe, seven test-only Runtime files and the worker Package/entry additions. Existing MTP/target Session products and their fixture sources are unchanged. The closed test geometry is unrelated to registered model eligibility.

```text
swift build --package-path WORKSPACE/libs/darkbloom-cluster-worker
  --scratch-path SCRATCH -c release --jobs 2
  --disable-automatic-resolution --skip-update --disable-build-manifest-caching
  --triple arm64-apple-macosx26.2
  -Xcc -target -Xcc arm64-apple-macosx26.2
  -Xswiftc -DQWEN_TARGET_TINY_FIXTURE
  -Xswiftc -DCBV2_WINDOW_STATE_FIXTURE
  --product WindowedRequestStateCheck
```

Use the existing 900-second owned build bound, vtool minimum-OS check, pure `WindowedRequestStateCheck check-arguments`, and exact binary/resource bundle pinning. The only native entry is `WindowedRequestStateCheck run-windowed-state-on-gpu`; root runs it under the reviewed standalone native supervisor/resource watcher and canonical gate. Its alarm remains active for 60 seconds through final output, while the native fixture has a 55-second monotonic budget and a fixed 64-MiB incremental active-allocation ceiling. It reuses the actual AC/power/free-memory checks. This ceiling is a test refusal bound, not Gemma model admission.

Build the unchanged `TargetVerificationSessionCheck` and `TargetVerificationCheck` products against the same composed source snapshot, with both defines. Root should rerun their existing bounded GPU commands separately. Their old successful runs do not establish that this new composition passes. The new fixture also executes actual four-layer Qwen ordinary forwards and compares the new nil-layout snapshot with the exact renamed prior v1 capture body.

Source check only:

```text
python3 -B /Users/developer/DarkbloomDev/cluster-research/gemma4-windowed-state-native-check-draft-20260915/check_source.py
```
