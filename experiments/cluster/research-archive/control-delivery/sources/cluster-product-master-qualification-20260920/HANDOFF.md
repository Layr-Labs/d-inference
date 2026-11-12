# Default product qualification on current master

This is an unexecuted root-scheduled runner for the actual master worktree composition. It creates a fresh four-package scratch workspace; it changes neither MAIN, the upstream worktree, nor the qualified private workspace. There is no signing, service deployment, native model invocation or remote operation here.

The source authority is cc225365 plus the retained MAIN work, App Attest proof carry, common coordinator relay, default Provider promotion, automatic mutual initiation and typed App Attest pair reader. `context.json` pins the actual root application receipts and SDK materialization; `expected-files.json` joins 462 named final package files and `coordinator-context.json` joins the 82 affected coordinator files. The latter is compatibility context, not a Go qualification claim. Full compilation inventories are produced and rechecked by root preparation and every phase.

`test-coverage.json` preserves the default promotion's 181 labels and adds exactly 3 identity, 5 initiation and 3 typed-membership labels, with no overlap: 192 total. The original 178 private controls are preserved in source, with the 4 private hardware-driver methods excluded from this default build, and 7 early HTTP refusal methods included. Both parameterized groups require the exact five observed case starts, exact `with 2 test cases` / `with 3 test cases` completions, every named method exactly once, and one exact 192-test terminal summary. A failed, missing, duplicate, additional or skipped method refuses qualification. Four parser-control methods are staged in `test_completions.py` and have not been run by the author.

The target master workspace currently has no Provider cache. Preparation requires the same exact 36-dependency Package.resolved lock as the retained private workspace, checks all 9,832 actual qualified checkout inputs, then uses APFS file clones for the four source packages and `cp -cR` for the cache into `qualification-1/workspace`. There is no ordinary-copy fallback. Only the copied SwiftPM workspace-state absolute roots are relocated, with original metadata retained. The cloned historical CLI is only cache data; qualification requires a natural successful default test and subsequent actual `swift build --product darkbloom` against the frozen current-source inventory.

The fixture helper is rebuilt once, using the actual previously qualified six command shapes: Protocol, Process, Bootstrap, Security, Remote and the four original CPU child fixture files. Source membership is exact; modules link only to the new helper directory. Existing helper receipts are provenance, never substitute evidence for these new binaries. The 192-test suite then uses that matching helper for actual CPU owner/socket/crypto lifecycle cases. No new helper or product test seam was added.

Root owns the sole preparation/compiler slot. All controller output must go to regular files. Run each phase separately, review its terminal receipt, then advance; there is no automatic retry or overwrite:

```sh
cd /Users/developer/DarkbloomDev/cluster-research/cluster-product-master-qualification-20260920
python3 -B check_sources.py --current
python3 -B -m unittest test_completions
python3 -B run.py prepare
python3 -B run.py helper
python3 -B run.py tests
python3 -B run.py build
```

Preparation is an owned child bounded to 300 seconds; its APFS cache copy is additionally bounded to 180 seconds. Each of six helper compilations has 60 seconds and jobs=2. Swift tests and matching CLI build each retain the existing 900-second owned-child bound and jobs=2. Diagnostics retain the existing 4 MiB parser limit and compiler files the existing 512 MiB ceiling. Every child must exit naturally with code zero, be reaped and leave its owned process group absent. Failed output and the candidate remain for diagnosis; output directories are create-only. `run.py` holds a phase lock, sanitizes inherited environment, uses no private Swift define and disables automatic dependency resolution/build-manifest caching.

The current upstream SDK is used: MLX 0f4fe403 and LM e22fc82, with the exact existing low-level native changes from root's submodule source plan. There is no copied private SDK replacement. New upstream signatures or test membership may expose a real compile or source-contract failure; retain that evidence and correct narrowly instead of changing assertions or falling back to older SDK bytes.

Success would qualify the default software composition and same-source CLI only. It would not establish real App Attest/MDA credentials, native runtime approval, protected hardware inference, performance, release signing or public routing readiness. The native approval catalog remains independently required.
