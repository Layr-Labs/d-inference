Portable real9B peer validation handoff

The inspected peer is Apple M4 Pro, macOS26.6.2, arm64, 24GiB RAM. Read-only inspection found pressure level1, zero swap, 13,852,065,792 estimated reclaimable bytes, ample disk and no native probe/supervisor process. The model manifest declares aggregate127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b and configuration bytes hash to c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423. Payload files were not rehashed by this inspection; the unchanged driver and rank workers verify their full content before execution.

Use /Users/developer/.darkbloom/python/bin/python3 (3.12.13). System Python3.9.6 is unsuitable for the strict-zip runtime. This is one-host local-loopback correctness on an M4 Pro, with no JACCL, RDMA or M3 Ultra throughput claim.

The local package contains164 hashed files plus its manifest: the completed local run's exact native bundle,146 archived source files, original three driver/helper files unchanged, original prompt/teacher evidence, and two portable wrapper/integrity helpers. The wrapper adapts only source/bundle/input/model locations and archival hooks, preserving all six native/both-wide × solo/FFN/full workloads, 96 prompt IDs, chunk32, four outputs and teacher[4087,13,271]. It retains the original pressure/swap/headroom/deadline/cleanup checks. Sources are copied from the package; the remote Git clone is neither read nor changed by the execution bridge.

CPU checks passed package integrity,146-file archival with the checkout replaced by a nonexistent sentinel, six specs, ten rank argv checks, and wrong-manifest rejection. No native inference or remote writes were performed by the preparing agent. Root owns staging and execution.

Frozen package tar: /Users/developer/DarkbloomDev/cluster-research/qwen9-peer24-package-20260913.tar
Tar SHA256: 86c548ffd242d22ad4630d7d4ee985607a5d73104eaf03d0f9d01fd6fe86ffd6
Manifest SHA256: 49190b33015157950a1ac4b1af2c13b49fe1e4512c807268c171d845b8086a76
Native binary SHA256: 26fe9543a617d97309c581bfdf80fc929b85fb2c652d9cd560f61191d1794770
Read-only inspection SHA256: cc021e0beac031578410256611090721a5cef1cef55a2e796ee183a419697a0b
Staging helper: /Users/developer/DarkbloomDev/cluster-research/stage-qwen9-peer24.sh (SHA256 e984c9fef8993fe78cfce690e841e17fd84aa184eadc5abbaa4a2d1bf8a444c0)

Root has already created /Users/developer/DarkbloomDev/cluster-research/qwen9-peer24-stage-20260913 and started transfer. Do not re-run helper lines1–10. After transfer completes, execute only extraction/check lines11 onward:

```sh
sed -n '11,$p' /Users/developer/DarkbloomDev/cluster-research/stage-qwen9-peer24.sh | bash -euo pipefail
```

This verifies the tar, extracts165 regular files into a new payload directory, checks the manifest and performs read-only package/spec/resource checks. Exact run command after successful checks:

```sh
ssh -T -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 darkbloom-24 /Users/developer/.darkbloom/python/bin/python3 /Users/developer/DarkbloomDev/cluster-research/qwen9-peer24-stage-20260913/payload/drivers/run-qwen9-staged-local-tp.py --package /Users/developer/DarkbloomDev/cluster-research/qwen9-peer24-stage-20260913/payload --manifest-sha256 49190b33015157950a1ac4b1af2c13b49fe1e4512c807268c171d845b8086a76 --model-dir /Users/developer/DarkbloomDev/models/Qwen3.5-9B --output /Users/developer/DarkbloomDev/cluster-research/qwen9-peer24-stage-20260913/run --plans all
```

The run writes original driver receipt/raw rank artifacts plus portable-execution.json binding package identity, Python, source origin and final run-receipt hash. Existing stage/output paths fail closed. No user process, service, model file or checkout is overwritten. Numeric gate misses remain in evidence without changing bounds; the data do not qualify model quality or hardware-cluster speed.
