CPU-control comparison passed for one matched solo and lookahead pair. All tokens, complete final rows and native KV bytes match accepted padded v2; exact guard cadence and resource budgets are unchanged.

| Role | Padded prefill / decode TPS | CPU-control prefill / decode TPS |
|---|---:|---:|
| solo | 370.436 / 47.068 | 371.091 / 46.562 |
| lookahead0 | 454.544 / 32.010 | 454.841 / 32.021 |
| lookahead1 | 454.477 / 32.091 | 454.789 / 32.081 |

P4096/C64/O16/cut7: one excluded warmup plus three measured requests. All four requests receive full numerical checking. New solo versus combined pair: four full rows and 360 state components. Same-role padded comparisons: eight full rows and 720 state components.

Five host-control GPU fences per continuation token are omitted through a Data-only API; CPU completion, all resource/fault checks and the residual CPU/GPU fences remain. Logical decode guard counts must remain exactly the accepted 65/63 per rank/token. No power reader changed. The receive-wire category now includes its existing Data copy; total request clocks are unchanged.

These are same-process internal timings for one fixed plaintext-RDMA workload. Inclusive owner/guard/wire intervals overlap and wire time includes peer work. No external TTFT, pure link/GPU timing, encrypted transport or broad throughput claim.
