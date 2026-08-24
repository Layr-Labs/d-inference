# 057 — E20 prefill-only adaptive MoE: up to 1.379×

Status: **promising component; quality gate pending**

The default-off Qwen prefill routing policy changes top-k only during
real CBv2 prompt forwards. Decode, MTP verification, ordinary forwards,
and model weights stay top-8/unchanged.

Environment:

```
DARKBLOOM_QWEN35_PREFILL_MOE_TOP_K={1|2|4}
```

An optional full-top-k layer set is supported for later quality tuning.

## Validation

- policy tests: 4/4 pass;
- release Darkbloom build: pass;
- default-off adjacent B=4×2K control: 1,693.0 tok/s;
- schema 7 reports first/full token IDs and timestamps.

## B=4×2K

| Policy | Aggregate tok/s | Speedup | Two-token checksum |
|---|---:|---:|---|
| top-8 control | 1,693.0 | 1.000× | baseline |
| top-4 | **2,054.2** | **1.213×** | 4/4 match |
| top-2 | 1,994.2 | 1.178× | 2/4 match |
| top-1 | **2,085.9** | **1.232×** | 2/4 match |

Top-2 underperforms top-4 because narrower assignment shapes lose tile
efficiency. Top-1 removes more arithmetic and recovers the lead despite
the generic small-assignment route.

## Primary B=4×8K

Against the locked 1,557.4 tok/s baseline:

| Policy | Aggregate tok/s | Speedup | Two-token checksum |
|---|---:|---:|---|
| top-4 | **1,857.0** | **1.192×** | 4/4 match |
| top-1 | **2,147.5** | **1.379×** | 4/4 match |

This is the first large end-to-end gain after the objective reset. It is
not sufficient alone: top-1 still needs 1.813× to reach 3,893.5 tok/s.

## Next

1. Run the natural-prompt quality corpus baseline/top-4/top-1.
2. Identify quality-sensitive layers; restore top-8 only there.
3. Compose with prefill layer/token/state reduction.
4. Optimize top-1 assignment geometry only after the quality policy is
   selected.

Artifacts: `artifacts/e20-*.json`, policy test log, and release build
log.
