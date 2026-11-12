# Authenticated record CPU cost on the two development Macs

Both actual M4 Pro Macs passed all eight cases using the same optimized binary as the local M4 Max run. This measures CryptoKit record processing on each CPU; encrypted RDMA has not been integrated or measured.

The binary was pinned before and after each run to `3a2fb41e1374099700e19118458395828d262461e60e5daea060f155701602d8`. Each case generated a fresh key and epoch, performed three warmups followed by twenty measured records, and verified every plaintext outside the timed interval. Both direction labels use distinct keys.

| Mac | Shape | Direction label | Seal median | Open median | Pair median |
|---|---|---:|---:|---:|---:|
| darkbloom-24 | 9B prefill, 4 MiB | 0 → 1 | 0.759 ms | 0.802 ms | 1.558 ms |
| darkbloom-24 | 9B prefill, 4 MiB | 1 → 0 | 0.493 ms | 0.522 ms | 1.015 ms |
| darkbloom-24 | 27B prefill, 5 MiB | 0 → 1 | 0.600 ms | 0.634 ms | 1.234 ms |
| darkbloom-24 | 27B prefill, 5 MiB | 1 → 0 | 0.601 ms | 0.635 ms | 1.236 ms |
| darkbloom-24 | 9B decode, 8 KiB | 0 → 1 | 3.125 µs | 3.292 µs | 6.416 µs |
| darkbloom-24 | 9B decode, 8 KiB | 1 → 0 | 3.125 µs | 3.271 µs | 6.417 µs |
| darkbloom-24 | 27B decode, 10 KiB | 0 → 1 | 3.333 µs | 3.458 µs | 6.833 µs |
| darkbloom-24 | 27B decode, 10 KiB | 1 → 0 | 3.333 µs | 3.458 µs | 6.812 µs |
| darkbloom-48 | 9B prefill, 4 MiB | 0 → 1 | 0.754 ms | 0.794 ms | 1.545 ms |
| darkbloom-48 | 9B prefill, 4 MiB | 1 → 0 | 0.493 ms | 0.517 ms | 1.006 ms |
| darkbloom-48 | 27B prefill, 5 MiB | 0 → 1 | 0.600 ms | 0.633 ms | 1.237 ms |
| darkbloom-48 | 27B prefill, 5 MiB | 1 → 0 | 0.621 ms | 0.636 ms | 1.260 ms |
| darkbloom-48 | 9B decode, 8 KiB | 0 → 1 | 3.166 µs | 3.334 µs | 6.500 µs |
| darkbloom-48 | 9B decode, 8 KiB | 1 → 0 | 3.125 µs | 3.333 µs | 6.459 µs |
| darkbloom-48 | 27B decode, 10 KiB | 0 → 1 | 3.333 µs | 3.542 µs | 6.875 µs |
| darkbloom-48 | 27B decode, 10 KiB | 1 → 0 | 3.333 µs | 3.521 µs | 6.875 µs |

The 5 MiB pair medians were 1.234–1.261 ms; 10 KiB pair medians were 6.813–6.875 µs. The first 4 MiB cohort was consistently slower than the later one on both Macs. The raw order, all samples and observed ranges are retained; this is not evidence that one protocol direction is inherently slower.

The pair interval is sequential seal then open on one CPU. Timing includes the actual codec’s framing, locks, AES-GCM and Data allocations. It excludes cohort key generation/HKDF, input/context preparation, equality verification and caller-held output destruction. It also excludes RDMA transfer, GPU readback/upload, MLX, inference and coordinator key establishment. Every record adds 40 framing/tag bytes.

Both CPU children exited zero and were reaped with their owned groups absent, without forced termination. SSH and benchmark stderr were empty. Each pre-existing canonical native-device lease stayed empty with the same inode under a held exclusive flock; all three process observations found no owner/native/provider process. No journal was modified, and no model ran. The quiet slot was released after both commands ended.

Sources remain frozen at `cluster-authenticated-record-remote-cpu-20260915/manifest.json` (`8578934444ad97793bfb00dcad1e9446483edbf432acec10060bf9faa51de5ea`). `replay.json` binds all raw evidence and independently recalculates the per-case medians and ranges. Remote raw stdout/stderr also remain in the create-only `/Users/developer/DarkbloomDev/cluster-record-cpu-benchmark-20260915` tree on each Mac. No additional remote operation was used for this replay.
