package registry

// Measured gemma-4-26B-A4B-it-qat-4bit decode rates, shared by the quality-cap
// and Gate G0a tests so the two cannot drift apart or be mistaken for each
// other.
//
// THREE numbers, not one, and they are not interchangeable. Each is cited to
// the report it came from, and they differ along two axes:
//
//   - PER-REQUEST vs AGGREGATE decode. At B=1 these are the same measurement
//     of the same thing, but they were taken by different harnesses on
//     different days and rounded independently, so quoting one where the other
//     belongs silently changes which report a failure sends you to.
//   - Which BACKEND served. The 2026-07-25 gate run measured both arms; the
//     earlier engine benchmark measured paged only.
//
// All three are Apple M4 Max (40 GPU cores, 546 GB/s), release build. They are
// deliberately close together — that IS the finding, since the quality cap has
// to clear its threshold on whichever arm a box happens to resolve — so if you
// need "the gemma-4 solo rate" for a new assertion, pick the one whose report
// you would want to reread when it fails, rather than the nearest literal.
const (
	// measuredGemmaSoloTPSPaged is the CBv2 v2-PAGED B=1 PER-REQUEST decode
	// rate — the shipping engine's own number, and the conservative one (the
	// eager path measures 101.8).
	// libs/mlx-swift-lm/benchmarks/reports/gemma4-26b-qat4bit-paged-gate-2026-07-09.md
	measuredGemmaSoloTPSPaged = 99.5

	// measuredSoloTPSPaged and measuredSoloTPSContiguous are solo (B=1)
	// AGGREGATE decode, medians of five repetitions, both arms of the v0.8.0
	// gate run. docs/reports/2026-07-25-paged-gate-results.md
	measuredSoloTPSPaged      = 98.8
	measuredSoloTPSContiguous = 107.2

	// measuredQwen36SoloTPS is the single-stream decode anchor for the Qwen3.6
	// 35B-A3B production build (EigenLabs/Qwen3.6-35B-A3B-MLX-VL-4bit-g64-router8,
	// served as qwen3.6-35b-a3b-vl-mtp-mxfp8): the target-only STOCK AR decode,
	// 140.0 steady-state tok/s (105.4 ms TTFT) on an Apple M5 Max, 128 GiB. The
	// MTP lanes on the same machine measure 191.1 (exact K2) / 211.6 (fast K2)
	// at 1K, so 140 is the conservative non-MTP anchor. Measured alongside the
	// optimization ledger in mlx-swift-lm benchmarks/qwen36-a3b/ (source
	// receipts decode-stock-20260824, context-matrix context-L1024-*-source-final).
	measuredQwen36SoloTPS = 140.0

	// measuredQwen35SoloTPS is the fleet MoE build (EigenLabs/Qwen3.5-35B-A3B-MLX-
	// VL-4bit-g64, served as qwen3.5-35b-a3b): B=1 24.5 tok/s and B=4 78.8 tok/s
	// aggregate on an Apple M4 Max (546 GB/s), production CBv2 engine, contiguous
	// KV, VLM extraction + parity gate. 2026-08-28 qwen3.5-9b validation & MTP
	// report (docs/reports/2026-08-28-qwen35-9b-validation-and-mtp.md).
	measuredQwen35SoloTPS = 24.5
)
