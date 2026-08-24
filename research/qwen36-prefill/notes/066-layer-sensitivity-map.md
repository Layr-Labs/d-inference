# 066 — Four-layer artifact sensitivity map

Status: **measured on natural 32-token continuations**

Baseline for this ablation is top-k4 with all 40 layers. One four-layer
block at a time was changed to artifact-only while every other layer
remained full.

| Artifact-only block | Exact cases / 12 | Token agreement |
|---|---:|---:|
| 28–31 | **8** | **97.1%** |
| 16–19 | 5 | 81.2% |
| 20–23 | 6 | 79.4% |
| 4–7 | 3 | 71.9% |
| 8–11 | 4 | 71.1% |
| 24–27 | 5 | 68.2% |
| 32–35 | 5 | 53.9% |
| 12–15 | 2 | 37.8% |
| 36–39 | 0 | 29.2% |
| 0–3 | 0 | **2.6%** |

The model is strongly depth-sensitive and nonuniform:

- first and final blocks must stay full;
- block 28–31 is nearly redundant under this corpus;
- independent single-block quality does not compose linearly.

Combining the six least-sensitive blocks retained too little quality,
and a 16-full-layer configuration reached only ~2.0×. This map should
drive future selective profiles and correction, not blind stride masks.

Artifacts: `artifacts/e27-topk4-32-baseline.json` and
`artifacts/e27-skip-*.json`.
