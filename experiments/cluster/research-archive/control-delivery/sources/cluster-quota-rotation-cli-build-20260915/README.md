# Pending CLI quota activation checks

This preparation reuses the owned, already-qualified rotation workspace and cache. It creates no checkout/cache clone. The exact three-file frozen CLI delta is pinned in `inputs.json`; current MAIN and private target preimages/absences matched during source preparation. The workspace has not been modified and no compiler has run.

After root explicitly grants the slot:

```sh
python3 stage_overlay.py
python3 run_checks.py --output /Users/developer/DarkbloomDev/cluster-research/cluster-quota-rotation-cli-build-20260915/checks-1
```

Staging rechecks the complete prior qualified source/dependency inventory, frozen CLI manifest and destination states before writing only the three files. It preserves the replaced source and emits the exact expected new snapshot. Tests and the CLI product build run sequentially with jobs2 and the existing reviewed 900-second owned-process bounds. The same unreaped-process cleanup helper is imported by hash; no new signalling or supervisor logic is introduced. Every step has a fresh stdout/stderr/process receipt and before/after source check. Failures remain in their output directory; any correction must be separate and root-coordinated.

No MAIN writes, native model execution or remote activity is part of this sequence. The old rotation receipts/snapshots and both fixture corrections remain unchanged. The candidate's private Package/fixture target is retained only in its private workspace and is not a MAIN promotion.
