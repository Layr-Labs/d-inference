# 037 — Primary 8K baselines: B=2 1501, B=4 1557 tok/s

Status: **locked baseline**

## Setup

- M3 Max 40 GPU cores, 128 GiB;
- AC, High Power (`powermode=2`) before and after each run;
- one rebuilt Darkbloom binary and contiguous CBv2 engine;
- default chunk 512 / step budget 2,048 / solo stripe 2,048;
- prefix cache off, text-only, greedy, 8,192 prompt tokens/row;
- schema-6 harness, three measured burst repetitions after warm-up;
- metric `B * (8192 - 1) / [max(first token) - min(submission)]`.

Artifacts:

- `artifacts/baseline-rebuilt-b2-8192.json` + `.meta`
- `artifacts/baseline-rebuilt-b4-8192.json` + `.meta`

## Result

| Cell | Per-iteration aggregate tok/s | Median | Median makespan |
|---|---|---:|---:|
| B=2×8192 | 1501.6 / 1500.7 / 1500.4 | **1500.7** | **10.9165 s** |
| B=4×8192 | 1545.1 / 1557.4 / 1560.6 | **1557.4** | **21.0375 s** |

All row token checksums were stable across all three repetitions.
Arrival error stayed within the recorded 20 ms tolerance.

## Binding bars

For B=4 (program.md primary):

```
baseline aggregate = 1,557.4 tok/s
2.5x target         = 3,893.5 tok/s
baseline makespan   = 21.0375 s
target makespan     =  8.4150 s
```

For the stronger interpretation requiring B=2 itself to reach 2.5×:

```
baseline aggregate = 1,500.7 tok/s
2.5x target         = 3,751.8 tok/s
baseline makespan   = 10.9165 s
target makespan     =  4.3666 s
```

B=4 aggregate again equals B=1 8K (1,555 tok/s) within noise. Continuous
batching is not creating extra arithmetic throughput on the current path.
