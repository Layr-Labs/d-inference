# 000 — Machine facts (M3 Max 128 GB)

Status: kept (facts)

- Remote benchmark host: `m3-max-128gb-2`
- `Mac15,9`, Apple M3 Max, 40 GPU cores, 16 CPU (12P+4E), 128 GB
- Unified-memory bandwidth class: ~400 GB/s (M3 Max 128 GB)
- Metal `maxBufferLength` previously observed 86,586,540,032 (~80.6 GiB)
- macOS 26.4 (25E246), Swift 6.3.2, Xcode at `/Applications/Xcode.app`
- Disk: 658 GiB free
- Power at recon: AC, battery 100% finishing charge, `powermode=0`
- Darkbloom 0.8.10 at `~/.darkbloom/bin/darkbloom`
- Provider not running. `provider.toml` still points at live coordinator
  `wss://api.darkbloom.dev/ws/provider`. Benchmarks must not start the
  daemon unless intended.
- Workdir: `/Users/benchmark/work/qwen36-prefill`
- Fan helper: `/Library/PrivilegedHelperTools/io.darkbloom.fan-helper`

Hazard: 2026-08-21 provider.log Qwen load died with

```
[metal::malloc] Attempting to allocate 164783923200 bytes
which is greater than the maximum allowed buffer size of 86586540032 bytes
```

164.8e9 / (248320 * 4) ≈ 165,888 — consistent with a vocab-width
float32 tensor over a ~166k-token axis, or a similarly huge square.
Do not start with 32K+ or vision. Budget shapes first.
