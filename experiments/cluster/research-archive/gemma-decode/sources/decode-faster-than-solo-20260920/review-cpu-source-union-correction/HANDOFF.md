This is a comparator-only correction. Original `review-cpu` manifest `c5cb49cf…`, its reader and input pins remain unchanged and are also preserved under `preimages/`. Root's first thirteen controls had twelve passes and one source-union error. That failed result remains historical; no runtime or physical result is changed here.

The old explicit padded source inventory has 46 members. The new actual inventory correctly has 48: its three-file overlay newly tracks two existing Collective files, while replacing the already tracked Wire file. The corrected reader requires exactly `old inventory ∪ three overlay paths`, requires the two newly tracked names to be precisely `Collective.swift` and `CollectivePointToPoint.swift`, and verifies all three reviewed before-byte hashes against frozen preimages. Every unchanged row remains exact, every final changed row is bound to actual frozen bytes, and all duplicates or extra paths refuse. No source gate is dropped. The numerical comparator itself is byte-identical to the original.

Root commands, not executed by the author:

```sh
python3 -B /Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/review-cpu-source-union-correction/test_contract.py
python3 -B /Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/review-cpu-source-union-correction/compare.py --output-dir /Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/review-cpu-source-union-correction/actual-cpu-1
```

The first now has fifteen controls, including unexpected inventory addition and corrupt newly tracked preimage refusal. The second retains the original complete physical/resource/numerical checks and must wait for all physical owners to retire and root's exclusive I/O window. Use the existing owned240-second controller for the replay. No new capture, serial pair, compiler, native or remote action is introduced.
