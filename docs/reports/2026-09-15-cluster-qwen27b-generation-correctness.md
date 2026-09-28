# Qwen27B generation across two Macs

> Last updated: 2026-09-15 · commit `605651bb9`

Registered Qwen3.8 27B 4-bit completes a short two-Mac RDMA request with 16
layers on the 24 GB M4 Pro and 48 layers on the 48 GB M4 Pro. All 128 output
tokens, the complete final BF16 logits row and the complete exported state
record union match the full-model reference. This is correctness evidence;
8K prefill throughput and external TTFT remain unmeasured for this model.

## Workload and partition

Both machines have 14 CPU and 20 GPU cores and run macOS 27 build 26A428.
The request uses 32 tokenizer-derived prompt IDs, 16-token prefill chunks,
128 greedy output tokens, an empty stop-token set, serial prefill and MTP off.
The actual full-model reference runs separately on the 48 GB Mac with the same
request and arithmetic policy. Model loading is part of these correctness
processes, so their overall duration is not an inference throughput measure.

| Rank | Host RAM | Layers | Selected target tensors | Logical active weight bytes |
|---|---:|---:|---:|---:|
| 0 | 24 GB | 0–15 | 463 | 4,140,778,752 |
| 1 | 48 GB | 16–63 | 1,384 | 10,992,023,296 |

These are target tensor counts and logical weight bytes, not measured process
residency. The native loader retains its actual-free and allocator checks.
The split is manually selected to establish a feasible run, not an automatic
placement result or the fastest measured partition.

The preceding 32/32 attempt refused loading on rank 0 at an actual-free check:
10,198,024,192 bytes were available against 10,448,983,422 required. Its
250,959,230-byte deficit was observed during materialization, after 283 of 923
reads were admitted. The allocator-limit check had not run at that failure.
The successful 16/48 attempt changes placement without lowering the guards.

## Numerical comparison

The frozen comparison policy was prepared before candidate output was read.
The full reference and candidate sidecars are collected into separate,
hash-pinned files; the comparator rechecks their identities and contents.

| Check | Result |
|---|---|
| Output token sequence | All 128 IDs agree across both ranks and reference |
| Final schedule | 129 completed frames; committed frontier 159 |
| Final vocabulary row | All 496,640 BF16 bytes reconstructed and equal |
| Final CPU argmax | Token 6326; unique maximum |
| Complete state record union | 144 ordered entries; rank ownership 36/108 |
| State comparison detail | 16 position offsets reconstructed; 128 other state digests agree |

The comparator does not reconstruct the non-offset state payloads, compare
every intermediate logits row, attest binaries or independently observe
physical retirement. Storage commitment equality is an identity check; the
separate source derivation is not a loaded-weight-value audit.

## Actual execution and cleanup

Both native workers exit zero with empty diagnostic stderr. The owner
controller completes all 128 tokens and observes native cleanup, authenticated
owner release acknowledgments, complete diagnostic EOF and successful owner
transport termination for both members. Independent postflight and later
sidecar collection observe no native processes and empty canonical journals.
The temporary Thunderbolt IPv4 alias is removed and management remains intact.

Root replays all retained resource observations from raw macOS output:

| Host | Samples | Minimum actual free bytes | Conditions |
|---|---:|---:|---|
| 24 GB | 103 | 8,142,979,072 | AC power, normal pressure, zero swap |
| 48 GB | 104 | 21,203,910,656 | AC power, normal pressure, zero swap |

Sampling does not establish a continuous memory peak. The physical parent
takes 29.747 seconds, including startup, loading, the request and retirement.
No compiler, bulk copy or competing remote operation overlaps the run.

## Reproduction and limits

Evidence is under `/Users/developer/DarkbloomDev/cluster-research/`:

- `qwen27b-cut16-owner-qualification-20260915`: source/configuration checks,
  two 14-file deployments, preflights, physical execution, root resource and
  cleanup review, collected sidecars and final comparison.
- `qwen27b-cut16-full-reference-20260915`: separately owned full-model
  reference, collected bytes and root review of 100 resource observations.
- `qwen27b-cut16-numerical-audit-20260915`: frozen numerical policy, source
  derivation and fabricated refusal cases.
- `qwen27b-cut16-collection-comparison-20260915`: bounded read-only collection
  and the unchanged six-role comparison interface.

Native SHA-256 is
`989f701ca6a8178ebc41b73e840a937c17aa9b0a3f8a53b9fee8432a4cd5ffdb`.
The final comparison SHA-256 is
`5c0295ffcce813d483c488aec66f788e6a7844cee6895f7f9ce83da9fd438103`.
The Plan is
`8e1408f4f044b0fa6f97ae9b997d575797fe1d22036ddb68409e2aeb349949ed`.

This private development run does not change the installed 9B default or
qualify 27B product routing, encrypted RDMA, MTP, lookahead, external TTFT or
M3 Ultra performance. The transport still carries plaintext inference records;
SSH protects the owner channel. The new delivery requirement is recorded in
the [calibration and confidentiality design](../design/distributed-cluster-calibration-and-confidentiality.md).
The next measurement is matched 8K prefill on the pair and an optimized solo
control, under the [delivery plan](../design/distributed-cluster-delivery.md).
