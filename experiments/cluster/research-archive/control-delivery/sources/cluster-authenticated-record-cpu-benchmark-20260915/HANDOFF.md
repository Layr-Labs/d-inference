# Local CryptoKit record overhead — source-only benchmark candidate

This separate package measures the byte-exact four codec sources from frozen `c206c9e0860c641de64057a48652887ed93a4737edf0a4db16a4ba4251f692ac`. Those sources passed all eight correctness groups, including independent OpenSSL/HKDF vectors, in `cluster-authenticated-record-checks-1-20260915` (`checks.json` SHA `c64e748472734d41257062bc2c95e4eee360590ca228cd2a7208aa9bb0555832`). No codec changes are proposed here.

**Benchmark Swift is uncompiled and unexecuted at this freeze.** No encryption performance number is claimed yet. The root must review and grant the compiler/CPU slot before the command below. The observed host is required to identify as Apple M4 Max; these will be local M4 Max results, not an estimate for the remote M4 Pro machines.

## Exact measurement

Eight cases: both source directions for 4,194,304-byte and 5,242,880-byte prefill records, and 8,192-byte and 10,240-byte decode records. These are the logical BF16 residual sizes for 9B/27B C512 and one-token decode. They contain deterministic fixture bytes, not model data.

Each case constructs a fresh random 256-bit key and epoch, then one sender/receiver channel pair with exactly 23 records of budget. Three warmup records precede 20 retained measured records. Sequence increases from 0 through 22; each record uses a fresh request UUID, and no channel/key/nonce reset or retry is permitted. Both counters and cumulative byte charges must equal the exact planned cohort. Channels are explicitly invalidated afterward. Keys are never printed or written.

Every iteration retains four same-process monotonic `DispatchTime.uptimeNanoseconds` readings:

1. Immediately before actual `channel.seal`.
2. Immediately after it returns.
3. Immediately before actual `channel.open`.
4. Immediately after it returns.

All framing, locks, AEAD, internal Data allocations/copies and publication logic inside those methods remain timed. Plaintext equality and output-size verification occur after all four readings. Cohort key generation/HKDF, synthetic payload/context preparation, and caller-held output destruction after verification are outside the intervals. No empty-loop subtraction or allocator reset is performed. The paired interval includes both calls and the small measured gap between them; it must equal seal + open + gap exactly. Raw warmup and measured samples are retained separately; only the 20 measured samples enter each summary.

The paired result is sequential seal then open on **one local CPU**, not two remote hosts. Rate summaries count one plaintext payload per operation or pair, not double the paired bytes. There is no RDMA, transport, MLX, GPU readback/upload, native inference, key-establishment network exchange or coordinator authorization. This is not encrypted end-to-end TTFT or throughput. Record metadata/timing remains public.

## Copy and admission limits

This uses the existing Data API and measures its actual method-level staging work. It does not model materializing a residual from MLX, native ciphertext allocation, RDMA buffer copies, reconstructing a native residual after open, or per-device synchronization. The fixture compares plaintext outside timing and can warm CPU caches; results describe this warmed CPU codec workload, with all raw warmups retained.

Current codec wire overhead is exactly 40 bytes. Future transport admission must use `plaintext <= negotiated sealed-message ceiling - 40`, with checked subtraction, named staging memory and cumulative transfer budgets. A codec pass is not memory admission. Current local SDK 26.5 exposes no RawSpan/in-place AES.GCM API; no in-place or zero-copy claim is made.

For a P8192/C512 request, the main prefill residual stream has 16 records: 64 MiB for 9B or 80 MiB for 27B, plus headers/tokens/ACKs and decode. Multiplying the CPU sample by 16 is at most a conditional codec-work illustration, not an encrypted RDMA request bound. Measured latency may overlap differently across hosts; extra copies and synchronization are unmeasured here.

## Root command after review and slot grant

```sh
python3 -B /Users/developer/DarkbloomDev/cluster-research/cluster-authenticated-record-cpu-benchmark-20260915/run.py --output /Users/developer/DarkbloomDev/cluster-research/cluster-authenticated-record-cpu-benchmark-run-1-20260915
```

Direct Swift 6 `-O`, warnings-as-errors, jobs 2, target macOS 14; no SwiftPM or MLX build. Compiler bound 60 seconds, benchmark bound 30 seconds, fresh private output/module cache. The exact reviewed owned-process helper retains timeout/group/reaping evidence. Stdout/stderr are retained and checked at most 1 MiB per stream after completion (no claim of streaming backpressure). Nonzero exit, timeout, group residue, stderr, source change, wrong CPU identity, bad counts, missing samples or failed content verification rejects the run.

The runner validates all eight case/shape/direction identities, strict integer counts, monotonically ordered sample ordinals, paired timing arithmetic and closed scope flags before producing medians/min/max and rates. It retains the raw JSON separately. No remote, GPU, model, cache-copy or installed-config operation is performed. Parent compiler/timing exclusion remains required.
