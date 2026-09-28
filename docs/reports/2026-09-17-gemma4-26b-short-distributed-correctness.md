# Gemma 4 26B short distributed correctness

> Last updated: 2026-09-17 · commit `605651bb9`

A private Gemma 4 26B QAT 4-bit run split across the M4 Pro 24 GiB and 48 GiB Macs matched a retained full-model reference exactly. This records one short correctness workload and its physical cleanup; it does not establish performance, encrypted RDMA, expert parallelism or production readiness.

The workload used one tokenizer-derived 32-token prompt, two chunks of 16, two greedy output tokens, empty stop IDs and MTP disabled. Cut10 placed global layers 0–9 on 24 GiB and 10–29 on 48 GiB. Each stage retained all experts belonging to its layers and the required tied-embedding storage. The full reference ran first on 48 GiB at 05:03 UTC; the successful staged run completed at 05:20 UTC. Both used native binary `4fa7d2c85885b2bc398ab82fe4945fbbddd032cb94f17805f58a2ec928346271`, artifact identity `2468a0cb…28785`, Plan `9081ffaf…87258` and prompt file `4def99e2…33787d`.

The frozen comparator `7edf02eb…38ce1da` passed, and an independent read-only audit verified the retained bytes and evidence joins:

- Both outputs are IDs `[1813, 496]`, each the unique maximum of its full vocabulary row.
- Both 262,144-value **F32** logit rows match in their reconstructed native bytes: 2,097,152 logical bytes total. No absolute or relative tolerance was applied.
- All 90 final state components match exactly: BF16 keys and values plus int32 positions, totaling 7,434,360 bytes. The disjoint 30/60-component stage union matches the full 30-layer state; layout and snapshot fingerprints were recomputed.
- All three recorded inter-stage boundary digests agree at committed frontiers 16,32 and33. Final committed frontier is 33 with capacity 34. The second output is selected but not fed back into the model.

The actual KV geometry matches the global model: 25 sliding layers use 8 KV heads ×256 with window 1024; five full-attention layers use 2 ×512. All retained positions are 0–32, so this workload does not exercise a real-model window wrap or long context.

| Retained run | Resource samples | Minimum actual free bytes | Native PID | Collected files |
| --- | ---: | ---: | ---: | ---: |
| Full reference, 48 GiB | 91 | 16,678,240,256 | 83628 | 106 |
| Stage0, 24 GiB | 81 | 7,099,547,648 | 31973 | 44 |
| Stage1, 48 GiB | 81 | 22,257,434,624 | 92157 | 76 |

All 253 raw samples independently replay as AC, pressure1, zero reported swap and at least 6 GiB actual free. Native operational 4 GiB load and 2 GiB allocator headroom policies remain unchanged. These observations do not prove a whole-process MoE peak bound or establish a serving activation floor.

All three native leaders exited 0, were reaped, had absent owned groups, and reported request-state retirement/model release. Collected terminal hashes match the original successful launch receipts. The inherited lock stayed on the same empty canonical journal inode through exit, with no journal mutation; this is physical exclusion evidence, not a member-protocol release ACK. Stage1 retained one exact 45-byte JACCL connection-retry line; the bounded startup parser accepted that line, while final output/exit/cleanup still had to succeed. Rank0/full stderr were empty. The temporary 48 GiB `en1` alias was removed; raw observations preserve bridge membership, management route and active RDMA port.

Earlier failures remain retained and failed. The original full run refused attention geometry and required the explicit/implicit layer-identity correction. The first staged cohort rejected a JACCL retry diagnostic; rank0 later exited 124 and retained an `EPERM` group-cleanup error. A separately diagnosed rendezvous route selected the wrong interface. The successor used the verified management-address TCP rendezvous while retaining the `rdma_en1` mesh. Its first attempt then refused stage0 before loading any tensor: actual free 11,574,362,112B versus required 11,785,238,263B; stage1 timed out and was reaped. Root prepared memory and launched a fresh attempt 2 without lowering any guard. None of those failed cohorts supplies correctness evidence.

The independent [evidence review](evidence/gemma4-short-correctness-20260917/evidence-review.json) pins every collected file, the actual launch/collection joins, raw-resource replay and byte comparisons. [Prior failure receipts](evidence/gemma4-short-correctness-20260917/prior-failures.json) retain their diagnostics. This audit did not rerun the comparator, execute native code, access either Mac, rehash model payloads or independently rebuild the native binary. The application/serving path, encryption, throughput, broader prompts and expert-sharded execution remain unqualified by this record.
