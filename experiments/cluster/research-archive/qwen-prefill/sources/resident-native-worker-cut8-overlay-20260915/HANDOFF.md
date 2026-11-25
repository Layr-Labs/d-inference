# Cut8 admission overlay for the native resident worker

Apply the five files under `proposed/` to a new copy of the frozen assembled worker package. This extends only the explicit experimental registered9B admission from cuts12/16 to8/12/16. The native Plan already supports the interval-aligned `[0,8)` and `[8,32)` partition. Model construction, tensor mapping/loading, wire protocol, generation math, source validation, capacities, deadlines and memory floors are unchanged.

Base source packages remain untouched: facade manifest `4cceeb117ee2e5973dbd4d2f1d7d449e4d6ed84cd5815349721cf224b9db487f`; worker manifest `2d13d5add5901896fd9c7fff065dd4c6c89252c129266039665b7d00ce991f52`. Original bytes for all five files are retained under `originals/`. Two runtime predicates/error messages change; the third runtime file changes only its cut scope comment. `runtime-and-tests.patch` records the entire delta.

The real facade fixture now admits all three cuts on both ranks, then constructs cut8's actual native Plan against the retained registered metadata. The added case asserts the saved native catalog Plan fingerprint, contiguous complete global layers, preserved local interval phase, complete927-name/injective local mapping,233/694 active tensors,1,545,572,992/3,492,468,608 logical bytes,6/18 F32 tensors and endpoint ownership. It rejects noninterval, gap and overlap Plan ranges. The pre-device-read admission tests reject unsupported cuts, including noninterval cuts and otherwise legal but unselected4/20. The worker parser checks both ranks/all three cuts and rejects malformed canonical numbers and unsupported cuts.

No fixture or payload copies are added. Use the original retained-inputs JSON via `DARKBLOOM_RETAINED_PROFILE_FIXTURE`, with its existing raw SHA check. There are now8 facade test methods and the same9 worker methods; the new/changed cases have not yet run. Existing frozen tests remain recorded separately as7 facade and9 worker passes before this overlay.

After applying to a new assembled package and obtaining the root compiler slot, the focused command is:

```sh
DARKBLOOM_RETAINED_PROFILE_FIXTURE=/ABSOLUTE/EXISTING/retained-inputs.json \
  swift test --package-path /ABSOLUTE/NEW/PACKAGE --jobs 2 \
  --disable-automatic-resolution --skip-update \
  --filter 'ResidentFacadeTests|WorkerTests'
```

Root owns the next compilation and actual native26.2 build/deployment. A macOS14 test build still uses the JACCL stub and does not qualify physical operation. The existing `build-native-worker.sh` remains unchanged. Keep the optional generation diagnostic overlay separate from this serving worker.

`CACHE_POLICY_PROPOSAL.md` maps explicit dedicated-worker cache0/clear-beforeReady placement. It is deliberately not implemented in these five files. This cut8 source change alone does not address retained freed-buffer cache or establish new memory headroom.
