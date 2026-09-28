# Cluster record encryption CPU cost

> Last updated: 2026-09-15 · commit `605651bb9`

The proposed authenticated record codec takes about 1.23–1.26 milliseconds
to encrypt and decrypt a 5 MiB buffer on either development M4 Pro Mac.
This measures the actual codec, including its internal Data operations. It
does not measure encrypted RDMA, inference contention or additional transport
staging, so it does not establish an end-to-end TPS penalty.

## Measurement

The same optimized executable runs on both the 24 GB and 48 GB M4 Pro Macs.
Each buffer size is measured in both protocol directions: three warmups and
20 retained samples per case, for 160 measured samples per Mac. A fresh key
and epoch are created for each case; record counters never reset within it.
Every decrypted payload is checked after the timed interval.

| Logical payload | Same-host encrypt + decrypt median range across both Macs and directions |
|---|---:|
| 9B prefill, 4 MiB | 1.006–1.558 ms |
| 27B prefill, 5 MiB | 1.234–1.261 ms |
| 9B decode, 8 KiB | 6.416–6.500 microseconds |
| 27B decode, 10 KiB | 6.813–6.875 microseconds |

These ranges contain case medians, not confidence intervals or latency
percentiles. The first 4 MiB case is slower on both hosts than the subsequent
case. Case order and protocol direction are confounded; the data does not
establish a directional difference or a steady-state bound.

The measurement includes framing, locking, AES-GCM, internal allocations and
copies, authentication and publication inside the codec calls. It excludes
key creation/derivation, input/context construction, output verification and
caller-held output destruction. Each encrypt/decrypt pair runs sequentially
on one CPU, with no network transfer between the two operations.

## Implication for the current layer pipeline

For an 8,192-token prompt with 512-token chunks, the main activation stream
contains 16 buffers: 64 MiB for 9B or 80 MiB for 27B. Adding the separately
measured median encryption time on rank 0 to median decryption time on rank 1,
then multiplying by 16, gives this conditional CPU-work accounting:

| Model | Estimated codec work for the main 8K activation stream |
|---|---:|
| 9B | 24.84 ms |
| 27B | 19.72 ms |

These are arithmetic estimates from component measurements, not observed
request overhead. They exclude control records, GPU materialization and
reconstruction, RDMA staging and synchronization, coordinator verification
and key establishment. The apparent model ordering reflects the case-order
effect above. Actual overlap and contention require an integrated run.
Tensor parallelism and expert sharding need their own transfer counts and
buffer distributions.

The codec adds exactly 40 bytes per record: a 24-byte prefix and a 16-byte
authentication tag. For a 5 MiB payload that is 0.000763%; for 10 KiB it is
0.390625%. These percentages describe bytes, not latency or TPS.

## Correctness, ownership and provenance

Before timing, the codec passes eight CPU check groups, including independent
Python/OpenSSL bidirectional fixed vectors, altered data/context, replay,
record limits and invalidation. Both remote benchmark children exit zero,
are reaped with their groups absent, and leave their existing canonical
journals empty with unchanged inodes. No native model runs during timing.

Evidence is under `/Users/developer/DarkbloomDev/cluster-research/`:

- `cluster-authenticated-record-checks-1-20260915`: correctness receipts.
- `cluster-authenticated-record-cpu-benchmark-v2-20260915`: frozen optimized
  benchmark and exact codec sources.
- `cluster-record-cpu-remote24-1-20260915` and
  `cluster-record-cpu-remote48-1-20260915`: actual per-host timing JSON and
  owned-process receipts.
- `cluster-record-cpu-remote-results-20260915`: independent raw replay.

The executable SHA-256 is
`3a2fb41e1374099700e19118458395828d262461e60e5daea060f155701602d8`.
The codec source manifest is
`c206c9e0860c641de64057a48652887ed93a4737edf0a4db16a4ba4251f692ac`.

This private codec is not yet integrated into RDMA. Earlier model timings
remain plaintext measurements. Verified/routable pair authorization, fresh
session key establishment and encrypted transport qualification remain in
the [calibration and confidentiality design](../design/distributed-cluster-calibration-and-confidentiality.md).
