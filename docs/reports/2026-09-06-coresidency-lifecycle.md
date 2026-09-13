# Three-model shared-memory lifecycle, 2026-09-06

> Last updated: 2026-09-06 · commit `2eebb5412`

The reviewed test build passed one non-skipped lifecycle test with nine request outcomes and 17 ordered observations. Qwen 3.6 used paged attention, SSD caching and normal MTP; GPT-OSS 20B and Gemma 4 QAT used paged attention with SSD and MTP off.

Qwen’s cache grant fell from 68,844,138,374 to 25,803,645,093 bytes while GPT loaded, then to 12,862,314,113 bytes while Gemma QAT loaded. The corresponding Qwen request was active before, during and after each load. Each load began after a real 20,480-token SSD restore. Across recovery the counters reached five consumptions and 2,840,203,280 bytes read. This proves restored-generation/load overlap; SSD-read/load overlap is not claimed.

Both intended cancellations completed after 532 and 645 generated tokens. Seven recovery requests produced positive 64/128-token completions without errors. Cache grants regrew after unloading the other models; the final snapshot had no slots, grants, ledger owners, owned/materialized reservations, cache bytes or debt. The isolated operator memory cap was 70% with the fixture’s 8 GiB operator memory-reserve setting. The ledger’s separate activation reserve was 5.5 GiB (5,905,580,032 bytes); activation floors were unchanged.

All 70 collected files and seven runtime identities were verified. Source, provider, runtime and model identities were unchanged across execution. The temporary Qwen discovery projection was retired, preserving its ownership journal and original weights. All owned processes were absent, including the SwiftPM helper that used its own process group.

This is one lifecycle on an M5 Max with 128 GiB, using candidate 104/version 0.8.16 plus four isolated test files. It does not establish answer quality, throughput, whole-fleet acceptance, or acceptance of the final 0.9.0 binary. No prompts, response text, model tensors, binaries, credentials or cache payloads are included. Hashes and all 17 numeric observations are retained in [evidence projection](evidence/coresidency-2026-09-06/evidence.json).
