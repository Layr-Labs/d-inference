Timestamp-only comparison passed: new solo and lookahead pair match each other and accepted v7 tokens, complete final rows and native KV state bytes. All global and per-request prefill/decode guard counts match v7.

| Role | Prefill TPS before → after | Decode TPS before → after | Measured requests |
|---|---:|---:|---:|
| solo | 363.686 → 370.659 | 44.866 → 47.770 | 3 / 3 |
| lookahead0 | 452.211 → 459.812 | 22.212 → 28.545 | 3 / 3 |
| lookahead1 | 452.192 → 459.769 | 22.223 → 28.583 | 3 / 3 |

P4096/C64/O16/cut7, one warmup excluded and three measured requests per role. TPS is total measured tokens divided by total measured same-process duration. No new serial pair was needed. Native/launch/lease/resource/alias checks passed through the retained original helpers. This is one fixed prompt, plaintext RDMA and internal timing; no external TTFT or general workload claim.

New pair versus solo: 4 complete rows, 360 state components. Before/after across the three roles: 8 complete rows, 720 components. Four requests including warmup are numerically checked.
