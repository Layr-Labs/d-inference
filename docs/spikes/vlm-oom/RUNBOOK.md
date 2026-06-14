# VLM media-decode OOM — repro + on-hardware measurements

The VLM path decodes inline `data:` image/video from a request before any
KV/token/load admission runs. `decodeImage` → `CIImage(data:)` eagerly
rasterizes (W·H·4 bytes) with **no size or dimension cap**, and PNG has no
scaled-decode, so a tiny highly-compressed "decompression bomb" explodes on
decode. This directory is the repro that proved it and validated the fix.

## Files
- `make_bomb.py <W> <H> <out.png>` — streams a uniform-color PNG through zlib so
  the *generator* stays at ~one-scanline memory. Produces a few-KB→few-MB file
  (well under the 32 MiB WS frame cap) that rasterizes to W·H·4 bytes.
- `oom_probe.swift` — faithful to the provider: `CIImage(data:)` (the exact
  `decodeImage` call) + the real MLX-VLM render (`MediaProcessing.resampleBicubic`
  → `asMLXArray`/`context.render`). Modes: `decode` (laziness check), `naive`
  (full-extent render), `mlxpath` (the real resample-to-448 provider path),
  `header` (the **fix mechanism** — `CGImageSourceCopyPropertiesAtIndex`, dims
  with no raster).
- `run_guarded.sh <png> <mode> [target]` — runs the probe under a watchdog that
  samples RSS every 50 ms and SIGKILLs it if it crosses a ceiling (14 GB) or
  system-available memory drops below a floor (10 GB). Required: the bench box
  runs a real ~63 GB provider with **zero swap**, so an unbounded run would
  jetsam-kill it.

## Measured on an M5 Max (128 GB, macOS 26.4.1), provider co-resident at ~63 GB

| input    | mode               | on-wire | decoded   | peak RSS |
|----------|--------------------|---------|-----------|----------|
| 8000²    | decode-only        | 198 KiB | 64 Mpx    | 0.25 GB  |
| 16000²   | decode-only        | 757 KiB | 256 Mpx   | 0.96 GB  |
| 16000²   | **mlxpath (real)** | 757 KiB | 256 Mpx   | **1.78 GB** |
| 32000²   | **mlxpath (real)** | 3.0 MB  | 1024 Mpx  | **5.73 GB** |
| 32000²   | naive              | 3.0 MB  | 1024 Mpx  | 9.64 GB  |
| 40000²   | naive (12 GB ceil) | 4.7 MB  | 1600 Mpx  | watchdog SIGKILL @ 12 GB |
| 40000²   | **header (fix)**   | 4.7 MB  | 40000×40000 | **0 GB** |

Findings:
- `CIImage(data:)` is **not** lazy for PNG — decode-only RSS scales linearly with
  pixels (4×pixels → 4×RSS), i.e. it allocates W·H·4 at the decode call.
- The model's downscale does **not** save the provider: `mlxpath` (resample to
  448²) still peaks at 1.78 GB / 5.73 GB because CoreImage decodes the full-res
  source before downscaling.
- ImageIO applies **no** dimension cap — it decoded a 1-gigapixel PNG fine.
- The fix mechanism (`header` mode) reads dimensions at **~0 GB RSS** even for a
  gigapixel bomb, so rejecting from the header is O(header), not O(raster).

Extrapolation (NOT executed — would jetsam the co-resident provider): a few-MB
`~96000²` bomb decodes to ~65 GB; on this 0-swap box it OOM-kills the provider.

## Fix
`VLMRequestInference` now reads pixel dimensions from the header and rejects
`MediaError.mediaTooLarge` (→ HTTP 400) before `CIImage(data:)` runs:
per-image cap (`DARKBLOOM_MAX_IMAGE_MEGAPIXELS`, default 100), request-wide
aggregate (`DARKBLOOM_MAX_REQUEST_IMAGE_MEGAPIXELS`, default 384), and a per-part
decoded-byte cap (`DARKBLOOM_MAX_MEDIA_MIB`, default 25). See
`VLMRequestInferenceTests.swift` for the regression suite.
