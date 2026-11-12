# Authenticated RDMA measurements — 2026-09-20

All 14 physical runs passed on the 24 GB and 48 GB M4 Pro Macs over Thunderbolt RDMA, macOS 27 build 26A428. This is an SSH-authenticated standalone lab component; it does not establish verified Darkbloom membership or encrypted model serving. Every run retired both native groups, left the same empty device journals, removed one-shot secret files, and restored the temporary Thunderbolt alias.

Each process uses 3 warmups and 20 measured iterations per mode, in fixed order. Values below are medians of the per-process medians where repeated. Timings are rank0 round trips on one clock; rank1 receive includes peer wait. Small apparent negative differences are measurement/order effects, not negative encryption cost. Raw record means the same logical wire length including 40 bytes of padding. The array mode includes completed native export/import. These are instrumented component measurements, not model TPS/TTFT or a pure-link decomposition.

| Payload bytes | Processes | Raw payload ms | Raw record ms | Encrypted record ms | Encrypted array ms |
|---:|---:|---:|---:|---:|---:|
| 1 | 1 | 0.1530 | 0.1222 | 0.1413 | 0.2550 |
| 5632 | 1 | 0.2727 | 0.2199 | 0.2180 | 0.3057 |
| 8192 | 1 | 0.2460 | 0.2232 | 0.2198 | 0.3248 |
| 10240 | 1 | 0.2751 | 0.2206 | 0.2485 | 0.3254 |
| 65536 | 1 | 0.3911 | 0.3116 | 0.3026 | 0.4324 |
| 131072 | 1 | 0.3665 | 0.3253 | 0.3629 | 0.4927 |
| 360448 | 2 | 0.7231 | 0.4810 | 0.5273 | 0.6932 |
| 720896 | 2 | 0.6428 | 0.5012 | 0.8510 | 1.0851 |
| 1048576 | 1 | 0.5869 | 0.6217 | 1.1606 | 1.4061 |
| 4194304 | 1 | 1.6151 | 1.6709 | 3.6721 | 4.2999 |
| 5242880 | 2 | 1.9662 | 2.0177 | 4.5017 | 5.2506 |

The two 5 MiB encrypted-record medians were 4.502604 ms and 4.5008545 ms; equal-size raw medians were 2.0174375 ms and 2.018021 ms. End-to-end encryption cost depends on transfer size/count and overlap; these numbers do not imply the same percentage loss in model throughput. Do not add/subtract independent codec/copy medians as a measured decomposition.

Actual build and source identities are retained in `artifact-bindings.json`; per-rank frames, exact encrypted counters, ciphertext joins and local component samples remain under `cases/`. The summary receipt is `actual-sweep-summary.json`.
