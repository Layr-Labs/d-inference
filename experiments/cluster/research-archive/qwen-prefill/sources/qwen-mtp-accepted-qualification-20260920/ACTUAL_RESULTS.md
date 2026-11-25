# Qwen 9B accepted-draft hardware qualification — 2026-09-20

The exact registered Qwen3.5 9B 4-bit artifact passed a fresh full-model reference, a two-Mac MTP-off run and a two-Mac depth-one MTP-on run. Workload: P32/C16/O8, BF16 residual, layer cut 4 of 32, greedy output, no stop IDs. These are correctness runs, not throughput benchmarks or protected serving.

MTP accepted **3 draft tokens across 4 rounds**, reconciling all 7 decode inputs with 11 bilateral receipt sets. Both target ranks matched all 8 output IDs, the complete 496,640-byte final BF16 logit row, and 72 ordered state entries from the fresh full reference. The exact acceptance branch was exercised. Assistant hidden arrays and intermediate logit rows were not independently exported/compared.

Both runs retired their original owner/native groups, preserved the empty canonical device journals and restored the temporary Thunderbolt alias. Actual resource samples retained AC power, normal pressure and zero swap. Lowest externally observed free bytes: off 8,584,986,624 / 25,714,475,008; MTP-on 8,663,744,512 / 24,783,863,808.

Worker native: `7787dad579c454176ac902336ce764efc215db087e7e34267a0de7e8e4449435`. Fresh reference: `91c3cf8cdf7bd4ea2ed490ba9e84ab6900eec9261cf6190ea03d2f8c2fe055dc`. Both built with the same final 3,481-source tree and exact 8,755 dependency files. The first build’s mismatched reference dependency lock was rejected; its failed receipts remain. The root corrections also preserve failures for the copy-module filename, missing output parent and final snapshot reader. The corrected collector keeps all inode/mode/size/time/hash checks and declares its own source hash.

- [MTP-off result](off-collected-2/pair-result.json)
- [MTP-on result](depth1-collected-1/pair-result.json)
- [Actual build](build-2/receipt.json)
- [Collector correction](root-snapshot-reader-correction-1/source-receipt.json)

Longer resident MTP-on/off throughput, 27B/Gemma MTP, encrypted MTP, fault recovery and product serving remain unqualified. The shorter total process lifetime of one arm includes loading/diagnostics and must not be reported as an MTP speedup.
