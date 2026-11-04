### Cluster model list: one rule for what fits

- The cluster's plan now judges a Mac's memory with every app closed the way the load-time memory gate does, which counts cached files: a 128 GB Mac can give a model 120 GiB, not 75.6 GiB. MiMo V2.6 Flash on two 128 GB Macs, and large models on an M3 Ultra with an M5 Max, are offered (with "Quit apps first" when apps hold the memory) instead of being called too large even with every application closed.
- A split whose GPU part is larger than a Mac's GPU memory limit is no longer offered just because memory happens to be free; it would fail with "Insufficient Memory".
- A Mac under memory pressure is no longer described as fitting on cached files the gate will not count; the plan says to quit apps there first.
