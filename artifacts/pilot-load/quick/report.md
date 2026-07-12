# Coordinator differential pilot report

- Verdict: **PASS**
- Profile: `quick`
- Deterministic seed: `901`
- Soak: `False` (configured duration `120s`)
- Requests per target: `200` load + contract trace
- WS target: `1000` sessions
- Load multipliers: `10x` requests / `10x` chunks

## Throughput and latency

| Target | Requests | Throughput req/s | Total p50 ms | Total p95 ms | Total p99 ms | Total max ms | Prediction MAE ms |
|---|---:|---:|---:|---:|---:|---:|---:|
| go | 215 | 17.25 | 73.02 | 651.89 | 956.81 | 1141.52 | 121.98 |
| rust | 215 | 17.25 | 109.20 | 391.24 | 974.25 | 1149.58 | 131.05 |

## Stage budgets

| Target | Stage | Samples | p50 ms | p95 ms | p99 ms | max ms |
|---|---|---:|---:|---:|---:|---:|
| go | body | 215 | 2.75 | 260.12 | 828.74 | 838.35 |
| go | dispatch | 206 | 0.01 | 0.02 | 0.02 | 0.05 |
| go | encrypt | 206 | 1.71 | 9.71 | 23.01 | 69.73 |
| go | headers | 215 | 45.48 | 478.27 | 616.34 | 655.01 |
| go | parse | 206 | 2.19 | 37.49 | 50.63 | 68.49 |
| go | provider | 206 | 1.12 | 43.09 | 47.96 | 501.04 |
| go | queue | 206 | 0.00 | 0.00 | 0.00 | 0.00 |
| go | reserve | 206 | 3.99 | 47.50 | 71.71 | 122.28 |
| go | route | 206 | 15.99 | 196.29 | 215.23 | 251.96 |
| go | total | 215 | 73.02 | 651.89 | 956.81 | 1141.52 |
| go | ttft | 215 | 45.50 | 478.29 | 616.36 | 655.02 |
| rust | body | 215 | 0.91 | 152.19 | 834.63 | 843.73 |
| rust | headers | 215 | 102.64 | 282.17 | 311.25 | 599.98 |
| rust | total | 215 | 109.20 | 391.24 | 974.25 | 1149.58 |
| rust | ttft | 215 | 103.30 | 291.57 | 349.70 | 599.99 |

## Differential result

- Unapproved differences: `0`
- Manifest-approved differences: `3739`
- Skipped required scenarios: `0`

## Gate failures

All configured differential, budget, baseline, resource, and database gates passed.
