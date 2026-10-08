# Tiny JACCL and dense target-width diagnostic composition

This source-only successor requires exact tested memo109 `6288a214`, verifies its only three differences from diagnostics108 `05ed94d8`, and composes frozen tiny qualifier `5302f29b`, dense scope `cfc44f7f`, and mandatory head-cast correction `4619f2ea`. No prior freeze or active workspace was edited during preparation.

Thirteen changes produce 116 explicitly pinned sources: four tiny runtime additions, two dense additions, six existing runtime overlays, and the existing Quantized.swift SDK overlay (which was outside the prior 109-file list). The SDK preimage is independently pinned. Optional test target additions and Package changes are excluded. Both Entry overlay orders and both inverse orders must produce the exact recorded bytes. Combined Entry SHA is `27d995ac9e0e662c21fe1e0b48e540be32acc1640c1a4703ca88fe9f4bbbf62a`.

Root commands, strictly sequential in the exclusive compiler/materialization slot:

```sh
python3 -B /Users/developer/DarkbloomDev/cluster-research/gemma4-mtp-diagnostics-integration-20260920/compose.py
python3 -B /Users/developer/DarkbloomDev/cluster-research/gemma4-mtp-diagnostics-integration-20260920/compose.py --output /Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/build/tiny-dense-composition-1 --apply
python3 -B /Users/developer/DarkbloomDev/cluster-research/gemma4-mtp-remote-integration-20260920/BuildV2/run.py --sources /Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/build/tiny-dense-composition-1/sources.json --output /Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/build/tiny-dense-build-1
```

The inherited runner preserves the old binary, uses the exact jobs2/macOS26.2/no-resolution command, owns/fences/reaps the 900-second compiler group, and emits actual native/resource hashes. It never runs native code. The new composer saves every changed preimage and final source before edits; progress is retained if an apply fails. A prior or partial application refuses, with no automatic retry.

The applied receipt retains the original files shape and adds exact memo, qualifier, dense/correction, and this composition manifest bindings. Actual successful build/native/resource identities remain required by the separate physical binder. No future binary identity is predicted here. The tiny entry is `--qualify-remote-mtp REMOTE_JOB`; it exercises real seven-transfer snapshots and scalar queued/pull/cancel/fault controls, with no model weights or real GPU fault injection. Dense target-width is a separate diagnostic mode, not enabled for ordinary or remote target execution. No numerical quality, speed, encryption, or serving qualification is claimed.

Only small source/pin and Entry composition checks were run by the author. No compiler, native execution, remote action, model read, or workspace mutation occurred.
