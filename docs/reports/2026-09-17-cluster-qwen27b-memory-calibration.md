# Qwen27B placement from observed memory

> Last updated: 2026-09-17 · commit `605651bb9`

The retained 8K request measurements do not support moving from 16/48 to
24/40 layers on the current 24 GB and 48 GB M4 Pro pair. The smaller Mac has
only 68–185 MB above its six-GiB free-memory floor during the measured requests;
the additional weights and one generation of state backing would require about
1.86 GB. This analysis informs placement without changing any admission limit.

This report replays the raw rank-0 resource samples from the
[prefill phase measurements](2026-09-17-cluster-qwen27b-phase-profile.md) and
checks their retained output hashes, sizes and cleanup receipts. The workload
is registered Qwen3.8 27B four-bit, 8,192 input tokens, 512-token chunks and
128 output tokens, with MTP off. It adds no model execution or throughput sample.
All GB/MB figures below use decimal units; the six-GiB floor is 6,442,450,944 bytes.

| Rank-0 observation | Serial | One-chunk lookahead |
|---|---:|---:|
| Resource samples replayed | 334 | 269 |
| Free bytes at first monitor sample | 13,062,176,768 | 13,073,203,200 |
| Minimum free bytes | 6,510,379,008 | 6,627,573,760 |
| Margin above six GiB, bytes | 67,928,064 | 185,122,816 |
| Free-memory decrease, bytes | 6,551,797,760 | 6,445,629,440 |
| Net decrease not attributed below, bytes | 2,110,388,976 | 2,004,220,656 |

Post-purge free memory is not the launch baseline: 639–768 MB is consumed
between those observations. During the request, file-backed pages increase by
only about 154–232 MB at the free-memory minima, while compressor and swap
remain unchanged. Multiple VM classifications overlap and must not be added
together as independent allocations.

The selected weights contain 4,140,778,752 logical bytes. Source analysis adds
300,630,032 bytes for local KV capacity and one generation of recurrent backing
at chunk size 512. This includes the allocation retained by each convolution
tail view, rather than counting only its three visible rows. The remaining
2.0–2.1 GB is an unattributed net OS decrease. It may contain intermediate
buffers, construction overlap, Metal/JACCL and process overhead, and unrelated
OS changes; it is not an observed measurement of any one of those components.

In the pinned `Qwen35.swift`, `processChunk` returns the final three convolution
rows as a view of the entire `(chunkSize + 3) × 10240` BF16 input.
`RecurrentStateV2.swift` stages and commits that view without detaching it.
Across 12 recurrent layers, this can retain 126,566,400 bytes of backing for
737,280 bytes of logical tails. The fused input projection bank also replaces
the original projections with views into that bank: its construction-overlap
allowance is not proof of permanent duplicate weights. Smaller accounting
reservations alone do not free either kind of allocation.

[INFERENCE] A 24/40 split adds 1,712,808,576 logical weight bytes and
150,315,016 bytes of one-generation state backing at chunk size 512. Keeping
the measured baseline and unattributed decrease projects only 4.65–4.76 GB
free. Even removing the entire observed purge-to-launch loss projects
5.29–5.53 GB, below the existing floor. These are conservative placement
scenarios, not measurements of a 24/40 request. That split remains unavailable
for an 8K pilot on this evidence.

The next bounded memory experiment is a matched 16/48 request with 256-token
chunks, after adapting the fixed phase probe and its reference contract. The
known convolution-backing reduction is 62,914,560 bytes; any larger reduction
in temporary workspace must be measured. Scalar allocator and OS observations
at existing native checkpoints would separate load, readiness, chunk execution
and retirement without adding evaluations or file writes inside forwards.
The current records have no shared timestamp anchor between native phase
events and resource samples, so this report makes no exact phase-to-memory join.

Automatic placement needs measured compute cost, transport cost and request-peak
headroom in addition to initial weight fit and readiness reservations. Unmeasured
workspace must remain an explicit uncertainty; a candidate does not become
available merely because its static ledger fits.

The analysis is retained at
`/Users/developer/DarkbloomDev/cluster-research/qwen27b-actual-phase-memory-calibration-audit-20260917/audit.json`,
SHA-256 `87f1f3fd176f3d25758360481b27084cc324353500741adfa0974f4d4b2996d1`.
It pins the source passages, raw samples, parent output manifests, controller
retirement evidence and both phase comparisons used here.
