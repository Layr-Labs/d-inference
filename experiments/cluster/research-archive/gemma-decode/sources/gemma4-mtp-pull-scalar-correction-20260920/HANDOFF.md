# Tiny pull fixture scalar constructor correction

The first combined native build failed before native execution: MLXArray.full requires an MLXArray value. Only four fixture constants change from values:2/3/4/5 to values:MLXArray(2/3/4/5). BF16 result dtype, shapes, exact expected values, all resource/ownership controls, dense scope and Entry remain unchanged. Original5302, combinedcb4, actual failed116-source receipt2d90 and failed build receipt are preserved and pinned.

Root source check and sequential retry after review:
```sh
python3 -B /Users/developer/DarkbloomDev/cluster-research/gemma4-mtp-pull-scalar-correction-20260920/apply.py
python3 -B /Users/developer/DarkbloomDev/cluster-research/gemma4-mtp-pull-scalar-correction-20260920/apply.py --output /Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/build/tiny-dense-composition-2 --apply
python3 -B /Users/developer/DarkbloomDev/cluster-research/gemma4-mtp-remote-integration-20260920/BuildV2/run.py --sources /Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/build/tiny-dense-composition-2/sources.json --output /Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/build/tiny-dense-build-2
```
The source receipt adds qualifierCompileCorrectionManifestSHA256 and exact qualifierCompileCorrectionPredecessor. Physical binders must explicitly require that manifest, predecessor, and single updated Support hash e008d125; no arbitrary source substitution. Same original jobs2/900s build and all execution fences remain. Author performed source checks only, no compiler, native, remote or active workspace changes.
