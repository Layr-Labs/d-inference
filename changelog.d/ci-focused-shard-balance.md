### Provider CI: balanced Cluster Focused Checks shards

- Cluster Focused Checks shard 1 ran its step for 541 to 648 s and was the last job of run 44935109278 (13.6 min); shard 2 ended 2 to 4 min before it. The link worker runner (`libs/darkbloom-cluster/Tests/LinkWorkerChecks`, checks 87 to 89 s) moves to shard 2, whose plan step (`scripts/cluster-test-plan.py run focused 2`) runs it after that shard's other runners.
- Every focused runner still runs exactly once, its checks alone on the Mac, on the same lane and job count.
