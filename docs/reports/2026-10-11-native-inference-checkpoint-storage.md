# Native inference and quantized checkpoint qualification

> Last updated: 2026-10-11

Native inference with independently quantized SSD checkpoints passed the recorded
text-inference, restore, cancellation and isolation checks on eight model
artifacts. Quantization reduced encrypted write traffic, but its effect on
first-token latency depends on the model and reused prefix. This is candidate
validation, not a release, deployment or general model-quality certification.

## Scope and method

The provider selected native live KV and compared native checkpoint storage with
`balanced` checkpoint storage. Both arms used paged execution, MTP off, fixed
output lengths, an excluded warmup and independent encrypted-cache roots.
Model weights were checked before and after loading against their exact
aggregate hashes. No production coordinator or provider was used.

The optimized test builds used `-O`, `-enable-testing` and `-DDEBUG`. The last
flag retains existing test hooks; these are not signed production binaries.
Model loading and weight verification were outside request timing. OS file
caches were not flushed, so these are file-backed cache measurements, not
cold-media bandwidth measurements.

The current harness records `donationControlVersion = 1`. Its no-export control
uses a real complete-checkpoint store capped at one MiB, the same positive
checkpoint target and the same executed prefill ranges as the exporting donor.
The cap refuses capture before export. Full fixed-budget output hashes must
match; the control must perform no checkpoint I/O and the donor must write.
The earlier zero-target donor remains a diagnostic, not the export reference.

For every recorded comparison, actual restored-token counts matched between
storage arms. Repeated restores, cross-tenant misses, cancellation and recovery
were checked. Native live storage remained native; compressed file sizes were
not used as RAM-admission credit.

## Representative results

TTFT is request submission to first nonempty output. TPS measures tokens after
that first output over the first-to-last-output interval. `Raw` is the separate
warm-model full-prefill control with no prefix reuse. Numbers below are rounded
observations, not confidence intervals or interchangeable workloads.

`P` is the actual production checkpoint policy. `Q` is the explicit
`demanded_recurrent_qualification` policy used to exercise another boundary; it
does not establish production-default short or long partitioning.

| Model | Host | Policy / Restored Tokens | Native SSD TTFT | Balanced SSD TTFT | Raw TTFT | Native / Balanced TPS |
|---|---|---|---:|---:|---:|---:|
| GPT-OSS 20B | M3 Ultra | P / 1,024 | 547 ms | 575 ms | 921 ms | 121.42 / 121.25 |
| Gemma 4 26B QAT4 | M3 Ultra | P / 1,024 | 584 ms | 883 ms | 861 ms | 97.05 / 96.92 |
| Qwen3.5 9B | M3 Ultra | Q / 1,024 | 900 ms | 941 ms | 1,503 ms | 100.36 / 100.44 |
| Qwen3.5 35B A3B | M3 Ultra | P / 2,048 | 777 ms | 825 ms | 1,363 ms | 87.50 / 89.55 |
| Nemotron 3.5 Lightning | M3 Ultra | P / 2,048 | 862 ms | 876 ms | 1,587 ms | 100.85 / 101.14 |
| Qwen3.6 35B A3B MXFP8 | M5 Max | P / 2,048 | 501 ms | 559 ms | 863 ms | 115.99 / 115.86 |
| Qwen3.8 27B | M5 Max | P / 2,048 | 2,469 ms | 2,551 ms | 4,798 ms | 32.02 / 32.57 |
| Ternary Bonsai 2 27B | M5 Max | P / 2,048 | 3,585 ms | 3,511 ms | 6,865 ms | 44.89 / 45.56 |

Each representative row has one measured pair and 32 output tokens. Default
solo stripes were retained: 4,096 for the measured dense Qwen models and 2,048
for the other listed models. Production-frontier requests used token floors
3,073 donor / 2,304 shared / 4,096 fork / 2,048 demanded. Short requests used
1,793 / 1,152 / 2,304 / 1,024. Actual rendered token counts were recorded.

Gemma's balanced restore was about 51% slower than native-file restore and about
2.5% slower than raw full prefill in this short sample. This is an explicit
tradeoff, not a claim that every SSD hit beats recomputation. Most other rows
show a meaningful gain over raw prefill. The acceptance decision permitted this
roughly 50% Gemma native-checkpoint overhead in exchange for the disk savings.

Additional current-harness long cases passed. Qwen3.5 MoE and Nemotron used
7,168-token fork reuse with two 64-output pairs under Q; the M5 models used
4,096-token reuse with one 32-output pair under Q. M3 values are medians of the
two pairs; M5 values are single-pair observations:

| Model | Native / Balanced SSD TTFT | Balanced Raw TTFT | Native / Balanced TPS |
|---|---:|---:|---:|
| Qwen3.5 35B A3B | 524 / 733 ms | 2,859 ms | 89.58 / 89.86 |
| Nemotron 3.5 Lightning | 493 / 590 ms | 3,193 ms | 101.41 / 98.69 |
| Qwen3.6 35B A3B MXFP8 | 1,019 / 1,131 ms | 1,788 ms | 115.09 / 113.48 |
| Qwen3.8 27B | 5,223 / 5,338 ms | 9,714 ms | 31.53 / 31.33 |
| Ternary Bonsai 2 27B | 7,407 / 7,209 ms | 13,580 ms | 42.99 / 43.65 |

The production-frontier cases above separately exercised natural production
boundaries without the benchmark long-prompt extension. No partition policy,
minimum, output assertion or EOS handling was relaxed to obtain these results.

## Encrypted writes and live memory

These are aggregate donor-write counters for the representative cases, including
encrypted framing. They are not general compression factors or live-RAM savings.
Each selected row wrote one donor file in each arm; broader long cases could
write several files. Ephemeral timing reports do not inventory authenticated
capture positions, so equal file counts are not asserted to prove equal positions.

| Model | Native Donor Write Bytes | Balanced Donor Write Bytes | Reduction |
|---|---:|---:|---:|
| GPT-OSS 20B | 56,378,086 | 19,219,419 | 65.9% |
| Gemma 4 26B QAT4 | 230,707,959 | 91,935,651 | 60.2% |
| Qwen3.5 9B | 85,082,998 | 64,898,042 | 23.7% |
| Qwen3.5 35B A3B | 106,357,008 | 79,323,530 | 25.4% |
| Nemotron 3.5 Lightning | 61,687,578 | 53,577,640 | 13.1% |
| Qwen3.6 35B A3B MXFP8 | 106,357,002 | 79,323,524 | 25.4% |
| Qwen3.8 27B | 288,195,381 | 201,688,049 | 30.0% |
| Ternary Bonsai 2 27B | 425,365,237 | 213,025,857 | 49.9% |

Native recurrent and auxiliary state explains part of the lower reduction for
hybrid models. Direct engine-queue `memoryAtPrefillCompletion` observations had
equal native-live bytes in both arms. They are not whole-process or GPU peak
measurements. The decoder retains its 64 KiB admitted scratch bound and batches
validated native writes up to 16 KiB without reconstructing another full history.

## Persistent restart and safety evidence

A separately authorized Developer-ID-signed test host used a dedicated Keychain
access group and fresh test namespaces. Both native and balanced storage passed
four distinct processes: donate, restore, read-budget refusal, then restore after
refusal. All eight processes ran the selected test; no ephemeral-key fallback
was accepted. Actual host/module images, signatures and resource hashes were
verified. Authenticated ciphertext file lists, hashes and byte counts stayed
unchanged across all six consumer phases.

This proves the recorded same-device process restart with OS-backed persistent
keys, not recovery from power loss. `strictFsync` remained false. No production
keys, running provider, coordinator or published release was changed.

Focused SDK validation passed 84 functions with zero failures/skips on M3 and
M5: row-codec byte parity, request-sized live-packed feasibility, native paged and
contiguous restoration, legacy packed formats, and native cancellation ownership.
The final harness passed 55 Python tests and 21 focused Swift tests per machine,
including delayed-consumer memory evidence and watchdog-safe trace cleanup.
Full provider integration, documentation, changelog and PR checks are recorded
separately from the performance cohort; timing results do not stand in for them.

## Artifacts and provenance

The tested artifact aggregate hashes were:

| Artifact | Aggregate SHA-256 |
|---|---|
| GPT-OSS 20B | `61bfc04e4016a7fa487eb10e29f79360047e302487229f298da3681984aec512` |
| Gemma QAT4 | `2468a0cb3049a871f42052f4d9f9380bf12a0792f64c7a29f768559fc7d28785` |
| Qwen3.5 9B | `127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b` |
| Qwen3.5 35B A3B | `95811153b3bb2ed78bf44b3248b07b52fce637706107de8b0fddf21796ade01c` |
| Nemotron 3.5 | `366d9285ec367633c25b5c064ad94482e04be043c2a515a16e4fcf12c0a8f85b` |
| Qwen3.6 MXFP8 | `d932e96b00404b0575fff47e2dac8ed113056b3f22d0040c3c8d3f9ef25b09ed` |
| Qwen3.8 27B | `bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463` |
| Bonsai 2 | `ea1e901e4946c0ba9ad70c78517548808b353db6b3a13e87a8fa20468d81244c` |

The M3 timing module was
`be8179c3d05d5f0062e09d607cac6fe25eb6839c35979129fda02d8267756eac`;
the M5 timing module was
`73530dff4821e8164db6fb300c18f117f0c76b6711743d9efcd01d1ccbc5ba42`.
Their source-matched metallibs were respectively
`fb1ba8f90b9f1cc346246b7240c3986771464bd977c67f0ef03186811f16c85c`
and `7c28ecf53933836990a9f29f0ec5367c44dae9e0c2f3e875076c3bac3a5adb32`.
The signed restart used Debug test module
`32624784a81ccccd85b4adacc1435b0f70452998a09dacb2da29aa8735ac4074`
and signed host
`f0aa62b21ebeb4a16b858ee19d11dbcbd5b096c968883526e84243f71785bf91`.
The generic Swift test host's hash alone is not a module/source identity.

Runtime and test sources match the SDK implementation through
`6b7ebf45a472b3790f1991c58ad5da55cd08bc13` and the provider feature commit
`5c2da7a73b0b660376bfae0eed5a82a3dfd77f6f`. Later master integration adds
App Attest handling/diagnostics and documentation, not new model arithmetic.
The reproducible driver, report schema and validation tests are under
[`reports/kv-checkpoint-storage-2026-10-09`](../../reports/kv-checkpoint-storage-2026-10-09/README.md).

## Limits and retained failures

- These are small, public-text, greedy, batch-one observations. They do not
  certify broad task quality, all contexts, multimodal inputs, MTP-on throughput,
  production networking or saturated concurrency.
- Native-format restoration remains lossy for quantized older rows. Same-profile
  repetition and control equality do not imply equality with cold native output.
- Gemma 8-bit was excluded at the user's request. Full MiMo weights were not run;
  native-only MiMo policy and geometry regressions passed. QSA, persistent
  assistant and native-block diffusion exclusions retain their native fallback;
  they are not claimed as compressed-storage performance results.
- Earlier zero-target donor comparisons mixed prefill partitions in MoE models.
  Their failed reports remain excluded; the replacement control preserves both
  executed geometry and full-output equality. The invalid 7,680-token demand
  experiment also remains distinct from valid stride-aligned reuse.
- Earlier debug and pre-SIMD measurements remain historical. Their large restore
  overhead is not substituted for this optimized cohort, nor hidden by it.
- The existing live-packed inference work is retained. Its separate performance
  report is [runtime KV quantization](2026-10-09-runtime-kv-quantization.md);
  it is not evidence for native execution with compressed checkpoints.
