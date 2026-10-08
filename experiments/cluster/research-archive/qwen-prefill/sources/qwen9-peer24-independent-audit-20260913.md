# Independent CPU audit: registered Qwen3.5-9B on peer24

The six M4 Pro 24 GiB calls completed and their evidence is internally consistent. Numerical qualification still fails: all four matched-policy TP comparisons fail all four output rows. This is one-host, two-process loopback execution on the peer; it is not inference distributed between the two physical computers.

The audit checks 10 rank reports, 40 full-vocabulary rows and 9,932,800 stored logits. Every TP peer pair matches exactly. The four comparable modes (`native-solo`, `native-full`, `both-wide-solo`, `both-wide-full`) have byte-identical logit capture files on M4 Pro 24 GiB and the prior M4 Max 36 GiB machine. Both new solos also reproduce the earlier real9B solo controls exactly. FFN-only was not executed on the first machine, so it has no corresponding cross-hardware result.

The shared workload is 96 tokenized prose tokens, chunk size 32, four outputs, teacher history `[4087,13,271]`, zero warmups, one repetition, CBv2 contiguous execution, real W4/G64 weights with BF16 floating metadata/activations, and disabled MTP. “Both wide” selects Float32 attention and FFN output projection/reduction arithmetic on both solo and TP; it is an explicit policy departure from the native solo.

| Matched comparison | Peak relative row RMS | Peak absolute difference | Argmax disagreements | Strict passing rows |
|---|---:|---:|---:|---:|
| native-solo → native-ffn | 0.01586730663832 | 0.1875 | 0/4 | 0/4 |
| native-solo → native-full | 0.01633654258181 | 0.1875 | 0/4 | 0/4 |
| both-wide-solo → both-wide-ffn | 0.01572166049682 | 0.1875 | 1/4 | 0/4 |
| both-wide-solo → both-wide-full | 0.0137516693628 | 0.1875 | 1/4 | 0/4 |

The strict gate requires maximum absolute error <0.001, relative row RMS <0.0001, and matching argmax on every row. Metrics were recomputed from IEEE Float32 reconstructions of the saved JSON numbers and exactly reproduce the driver comparisons. Wider precision lowers worst row RMS by 0.9179% for FFN-only and 15.8226% for full partitioning. It does not qualify either plan; full row 2 absolute error increases from 0.140625 to 0.1875.

Native runs and the wider solo tie token IDs 4087 and 10926 at logit 19.875 on row 0, selecting lower ID 4087. Both wider TP plans retain 10926 at 19.875 but lower 4087 to 19.75, selecting 10926. All remaining rows select `[13,271,1206]`. Those rows consume the fixed teacher history, including 4087 after the first output; agreement is not evidence of matching free-running continuations.

Changing policy while holding partition fixed changes all four rows in each of solo, FFN and full. Peak relative RMS departures are respectively 0.01412320609397, 0.01219261321816 and 0.01245953711087; only the TP comparisons change row-0 argmax. These departures are separate from the matched-policy TP error. All compared calls use the same CBv2 path, so the previously observed ordinary-versus-CBv2 head-shape difference is not being mixed into these TP comparisons.

Exact source/storage verification covers 927 canonical text tensors, 5,038,041,600 source bytes, and 2,717,908,992 FFN bytes. Full source selection manifests and loaded layout hashes were independently reconstructed from actual safetensor headers, including segmented GDN axes and BF16/F32/U32 source dtypes, then matched to every direct-load receipt:

| Partition | Source bytes sharded | Selected sharded bytes/rank | Total loaded bytes/rank | Largest selected host tensor |
|---|---:|---:|---:|---:|
| ffn | 2,717,908,992 | 1,358,954,496 | 3,679,087,104 | 508,559,360 |
| full | 3,893,236,224 | 1,946,618,112 | 3,091,423,488 | 508,559,360 |

Both ranks retain 927 source and materialized tensors. The source values are partitioned rather than counting all parameters as half; replicated embeddings/head/norms remain in each loaded rank. The audit verifies storage metadata and native load receipts; it does not independently inspect the remote MLX buffers.

| Run | Request-window MLX peak, rank 0 / rank 1 (bytes) | Peak sampled owned-process RSS (bytes) | Pressure samples |
|---|---:|---:|---:|
| native-solo | 5,283,110,656 | 4,683,350,016 | 7 |
| native-ffn | 3,916,221,274 / 3,916,221,274 | 8,695,873,536 | 10 |
| native-full | 3,254,105,370 / 3,254,088,986 | 7,921,172,480 | 9 |
| both-wide-solo | 5,609,991,782 | 6,184,632,320 | 6 |
| both-wide-ffn | 4,132,559,962 / 4,132,559,962 | 9,033,826,304 | 9 |
| both-wide-full | 3,414,376,730 / 3,414,262,042 | 7,940,702,208 | 9 |

Every saved pressure sample is normal (level 1); reported swap usage is zero before, throughout the sampled run, and after each call. Startup MLX observations are separate: FFN ranks show 3,679,093,264 active bytes / 3,679,103,764 process-start peak; full ranks show 3,091,429,648 / 3,091,440,148. All report 11,794 cached bytes at that observation.

`Benchmark.execute` resets MLX peak after model loading. Its request-window peak includes resident parameters and live MLX allocations, but excludes earlier loading peaks, free cache, Foundation/Python host allocations and process RSS. RSS covers observed owned processes and is sampled; neither counter nor admission estimates provide a hard whole-process memory bound. The numerical gap reproduced with normal pressure and zero swap, so the earlier machine’s warning pressure/swap is not necessary for this observed gap.

The eight TP rank logs contain 2,304 verified CBv2 reduction hooks: 192 per FFN rank and 384 per full rank, each across six forwards, for both policies. This is aggregate model graph-hook coverage, not transport timing or physical-link validation. Every call records all expected native processes and supervisors, successful launcher reaping, and no observed owned process remaining at cleanup. No later remote process inspection was performed by this audit.

Integrity checks cover all 164 portable-package files, all 146 archived sources, the unchanged original driver files, the wrapper and its location/source-archival-only overrides, the bundle and per-run copies, native raw reports, rank inputs, logits, and the transferred archive/extracted files. The executable source matches the snapshot; only the current inference README differs. The wrapper records no Git checkout use and one-host loopback transport.

All 12 files of the local exact artifact were independently rehashed (6,113,952,230 bytes); their aggregate/config identities match the remote before/after verifier receipts. The archive does not contain the remote model payload, so remote payload integrity evidence is the saved checks bound to the unchanged verifier code, rather than a second independent remote filesystem read.

Identity pins:

- Artifact aggregate: `127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b`
- Config: `c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423`
- Native executable: `26fe9543a617d97309c581bfdf80fc929b85fb2c652d9cd560f61191d1794770`
- Source manifest: `4788d2f80f6c8fbfa419dc5a9ea0877c64b21d736557dcb2d9dec2bbc9bfe64a`
- Portable package manifest: `49190b33015157950a1ac4b1af2c13b49fe1e4512c807268c171d845b8086a76`
- Transferred archive: `901dc501d596dd238f67d24693ca9b01af8245019337a4e62dd4610d6b112fa4`, 569,425,201 bytes.

TP reports correctly mark correctness-only and invalidate throughput measurement. Solo reports retain their ordinary timing-valid flag, while the governing receipt marks hardware-throughput, numerical, and model-quality qualification false. These short captured, teacher-forced calls do not qualify TPS, 27B behavior, M3 Ultra hardware, physical RDMA/TB5, or a production distributed default.
The complete extraction check verified all 358 archive entries, including 295 regular files, against the archive payload hashes.

Evidence: [audit JSON](runs/qwen9-peer24-20260913/run/independent-cpu-audit.json), [new replay script](audit-qwen9-peer24.py), [CPU log](qwen9-peer24-independent-audit-20260913.log), [original driver receipt](runs/qwen9-peer24-20260913/run/receipt.json). Frozen previous audits were not changed.

The initial full audit passed before extraction verification was added. That added pass then rejected a legitimate top-level `staging-receipt.json` because the audit initially assumed a `run/`-only archive. The corrected pass validates this exact additional filename, every staging field, and the staged package tar hash. The rejected pass and its script are preserved as [failure log](qwen9-peer24-independent-audit-archive-layout-failed-20260913.log) and [failure script](audit-qwen9-peer24-archive-layout-failed.py); it was an audit-layout correction, not a native failure or changed runtime evidence. Final CPU replay session 10960 exited 0 using `python3 /Users/developer/DarkbloomDev/cluster-research/audit-qwen9-peer24.py --confirmed-terminal`; the JSON audit script hash matches the file on disk.
