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
)
