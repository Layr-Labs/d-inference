Padded control comparison passed for matched solo and lookahead pair. Tokens, complete final rows and native state bytes match both timestamp v1 and v7.

| Role | v7 prefill / decode TPS | Timestamp prefill / decode TPS | Padded prefill / decode TPS |
|---|---:|---:|---:|
| solo | 363.686 / 44.866 | 370.659 / 47.770 | 370.436 / 47.068 |
| lookahead0 | 452.211 / 22.212 | 459.812 / 28.545 | 454.544 / 32.010 |
| lookahead1 | 452.192 / 22.223 | 459.769 / 28.583 | 454.477 / 32.091 |

Each arm: P4096/C64/O16/cut7, one excluded warmup and three measured requests. TPS is total measured tokens divided by total same-process time. Four requests per role have numerical evidence checked.

Solo cadence and budget are unchanged. Each stage adds one actual rounded 16-KiB native control frame plus 32-KiB host allowance. Decode now has three completed sends and three receives per token; logical checks are exactly 65/63 per rank/token. Global counts also include every probe and begin/ready/request-retired/model-released control. Resource floors, native fault handling, native ownership and physical retirement proofs remain required.

These are internal timings of one fixed plaintext-RDMA workload. No external TTFT, encrypted transport or general throughput claim.

| Padded role | Total ms/token | Owner span | Evaluation | Logical guard | OS snapshot | Wire minus nested guard |
|---|---:|---:|---:|---:|---:|---:|
| solo | 21.246 | 20.238 | 18.417 | 0.974 | 0.087 | 0.000 |
| lookahead0 | 31.240 | 7.080 | 6.716 | 5.507 | 0.416 | 18.042 |
| lookahead1 | 31.161 | 15.788 | 14.682 | 5.886 | 0.479 | 9.039 |

All intervals use only their own process clock. Owner and guard categories overlap; do not add columns. Wire minus nested guard still includes peer computation, scheduling and native completion. JSON includes every guard category/call count, graph/staging/commit phases and before/after-owner intervals for all three versions.
