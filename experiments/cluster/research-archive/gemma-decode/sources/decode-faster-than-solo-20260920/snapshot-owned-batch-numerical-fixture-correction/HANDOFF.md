# Test-only wire-scope fixture correction

The actual six-method run failed two methods before wire hashing because their inherited synthetic job contained only UUIDs/epoch. The unchanged O128 counts reader now requires the complete closed workload selector. This successor adds exactly P128/C64/O16/full/cut7/BF16/serial/300s metadata to those two fixtures. Expected129/143 frontiers and every assertion remain unchanged. The test imports the exact frozen numerical reader from its original directory; no runtime/helper/reader/harness bytes change. Original failed receipt/stderr are pinned and preserved.

Root-only retry:

```sh
python3 -B /Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/snapshot-owned-batch-numerical-fixture-correction/run.py
python3 -B /Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/snapshot-owned-batch-numerical-fixture-correction/run.py --run --output /Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920/snapshot-owned-batch-numerical-fixture-correction/qualification-1
```

No tests were executed by the author. The root-owned child retains the original30-second bounded process-group supervision; all six methods must pass and predecessor inputs recheck afterward.
