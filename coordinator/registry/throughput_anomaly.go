package registry

import "strings"

// Throughput anomaly detection — pure expected-vs-observed decode math.
//
// Decode is memory-bandwidth-bound at batch≈1: each generated token streams the
// active weights out of unified memory exactly once, so the step time is
// dominated by bytes moved, not math:
//
//	read_bytes_per_token ≈ active_params × bytes_per_param
//	expected_decode_tps  ≈ bandwidth_GBps × efficiency / read_GB_per_token
//
// A model whose OBSERVED decode TPS is far below the expectation for its
// active-param class on a given chip family is decoding "heavier" than it
// should — e.g. an MoE read as if it were dense. That is the gemma-4-26b-qat-4bit
// case: it decodes ~21 tok/s, which is the speed of a *dense 26B* read
// (~13–15 GB/token), instead of the ~140 tok/s a ~4B-active read (~2.25 GB/token)
// would give on an M-Max — its expert sparsity is not being exploited. The
// 4B-active control, gpt-oss-20b, decodes ~69 tok/s on the same class, which is
// consistent with a healthy sparse read.
//
// See docs/architecture/routing-v2.md (§5 W8) and
// provider-swift/docs/gemma-decode-bandwidth-analysis.md for the derivation.
//
// This file is intentionally pure (no metrics, no IO, no registry locks) so the
// arithmetic and the trigger are unit-testable in isolation. The periodic fleet
// sweep + metric/log emission lives in coordinator/api/throughput_anomaly.go.

// Bytes-per-parameter for common quantizations. Decode reads each touched weight
// once per token, so this converts an active-param count into bytes/token.
const (
	// BytesPerParam4Bit is 4-bit group quantization: 4 bits of payload plus a
	// per-group scale (a 16-bit scale over a group of 64 ≈ +0.25 bit, plus a
	// zero-point) ⇒ ~4.5 bits ⇒ 0.5625 bytes/param. This is the midpoint of the
	// 0.50–0.60 range used in the bandwidth analysis.
	BytesPerParam4Bit = 0.5625
	// BytesPerParam8Bit is 8-bit group quantization (~8.5 bits ⇒ ~1.0625 B/param).
	BytesPerParam8Bit = 1.0625
	// BytesPerParamBF16 is half precision (2 bytes/param).
	BytesPerParamBF16 = 2.0
)

// Detector defaults (overridable by the api sweep via env vars).
const (
	// DefaultDecodeEfficiency is the fraction of *peak* memory bandwidth a real
	// MLX decode loop sustains — launch latency, non-weight traffic, imperfect
	// overlap. Empirically ~0.70–0.85; 0.80 is the midpoint used when
	// interpreting a measurement.
	DefaultDecodeEfficiency = 0.80

	// DefaultAnomalyRatioThreshold flags a (model, chip) bucket when its observed
	// decode is below this fraction of the expectation. 0.35 sits well below a
	// healthy sparse model's achievable fraction (gpt-oss-20b lands ~0.44 of its
	// 4B-active expectation on an M-Max because of real shared-trunk traffic — a
	// 128-way router, attention sinks, and a large vocab embed/LM-head read) yet
	// far above a dense-read MoE (gemma ~0.15). A flat 0.50 would false-positive
	// gpt-oss on Max-tier hardware, so the default is deliberately tighter.
	DefaultAnomalyRatioThreshold = 0.35

	// DefaultAnomalyMinSamples requires this many observed-decode samples in a
	// (model, chip) bucket before flagging, so a single noisy reading cannot trip
	// the detector.
	DefaultAnomalyMinSamples = 3
)

// ModelDecodeClass describes the decode-bandwidth class of a model: the number
// of parameters actually read per token (the "active" params — for an MoE this
// is the shared trunk plus the routed top-K experts, which is ≪ total) and the
// bytes read per parameter (set by the served quantization).
type ModelDecodeClass struct {
	// ActiveParams is the number of weights streamed per decoded token.
	ActiveParams float64
	// BytesPerParam is the per-parameter byte cost of the served quantization.
	// Zero means "infer from the model id" (see BytesPerParamForModelID).
	BytesPerParam float64
}

// ModelDecodeClasses maps a model id to its decode class. Extend this table as
// models are added — a model absent from the table is simply not evaluated; the
// detector never guesses an active-param count it does not know (which keeps it
// free of false positives on unknown models).
//
// active-param counts:
//   - gpt-oss-20b:          ~3.6B active (pure sparse MoE, top-4 of 128 experts)
//   - gemma-4-26b-qat-4bit: ~4.0B active (sparse experts + an always-on dense FFN)
var ModelDecodeClasses = map[string]ModelDecodeClass{
	"gpt-oss-20b":          {ActiveParams: 3.6e9, BytesPerParam: BytesPerParam4Bit},
	"gemma-4-26b-qat-4bit": {ActiveParams: 4.0e9, BytesPerParam: BytesPerParam4Bit},
}

// ChipBandwidthGBps maps an Apple-Silicon chip class to its approximate peak
// unified-memory bandwidth (GB/s). Values are nominal datasheet peaks; the
// detector multiplies by the efficiency factor to get a sustained estimate. A
// provider-reported memory_bandwidth_gbs, when present, takes precedence over
// this table (resolved in the api sweep); this table is the fallback for
// providers that omit it. M4 Ultra / the M5 line are approximate/extrapolated.
var ChipBandwidthGBps = map[string]float64{
	"M1":       68,
	"M1 Pro":   200,
	"M1 Max":   400,
	"M1 Ultra": 800,
	"M2":       100,
	"M2 Pro":   200,
	"M2 Max":   400,
	"M2 Ultra": 800,
	"M3":       100,
	"M3 Pro":   150,
	"M3 Max":   400,
	"M3 Ultra": 800,
	"M4":       120,
	"M4 Pro":   273,
	"M4 Max":   546,
	"M4 Ultra": 1092,
	"M5":       153,
	"M5 Pro":   300,
	"M5 Max":   600,
	"M5 Ultra": 1200,
}

// ExpectedDecodeTPS returns the bandwidth-bound single-stream decode throughput
// (tokens/sec) for a model that reads activeParams weights at bytesPerParam from
// memory with bandwidthGBps peak bandwidth sustained at efficiency:
//
//	expected ≈ bandwidth_GBps × efficiency / (active_params × bytes_per_param)
//
// Returns 0 if any input is non-positive.
func ExpectedDecodeTPS(activeParams, bytesPerParam, bandwidthGBps, efficiency float64) float64 {
	if activeParams <= 0 || bytesPerParam <= 0 || bandwidthGBps <= 0 || efficiency <= 0 {
		return 0
	}
	readGBPerToken := activeParams * bytesPerParam / 1e9 // bytes → GB
	if readGBPerToken <= 0 {
		return 0
	}
	return bandwidthGBps * efficiency / readGBPerToken
}

// LookupModelDecodeClass resolves a model id to its decode class. It tries an
// exact match, then a case-insensitive match, so registry/catalog id casing
// differences do not matter. When the class's BytesPerParam is unset it is
// inferred from quantization hints in the id. ok is false for unknown models.
func LookupModelDecodeClass(model string) (ModelDecodeClass, bool) {
	if c, ok := ModelDecodeClasses[model]; ok {
		return resolveBytesPerParam(model, c), true
	}
	lower := strings.ToLower(strings.TrimSpace(model))
	for id, c := range ModelDecodeClasses {
		if strings.ToLower(id) == lower {
			return resolveBytesPerParam(model, c), true
		}
	}
	return ModelDecodeClass{}, false
}

func resolveBytesPerParam(model string, c ModelDecodeClass) ModelDecodeClass {
	if c.BytesPerParam <= 0 {
		c.BytesPerParam = BytesPerParamForModelID(model)
	}
	return c
}

// BytesPerParamForModelID infers the per-parameter byte cost from quantization
// hints in a model id, defaulting to bf16 when none are present.
func BytesPerParamForModelID(model string) float64 {
	m := strings.ToLower(model)
	switch {
	case containsAny(m, "4bit", "4-bit", "q4", "int4", "qat-4", "mxfp4", "nf4"):
		return BytesPerParam4Bit
	case containsAny(m, "8bit", "8-bit", "q8", "int8"):
		return BytesPerParam8Bit
	default:
		return BytesPerParamBF16
	}
}

func containsAny(s string, subs ...string) bool {
	for _, sub := range subs {
		if strings.Contains(s, sub) {
			return true
		}
	}
	return false
}

// NormalizeChipClass builds a canonical chip-class string ("M3 Max", "M4 Pro",
// "M2") from a provider-reported chip family and tier. Returns "" when no Apple
// generation token can be found.
func NormalizeChipClass(family, tier string) string {
	return chipClassFromTokens(family + " " + tier)
}

// ResolveChipClass derives a canonical chip class from a provider's reported
// chip family and tier, falling back to the marketing chip name ("Apple M3 Max")
// when family/tier are empty or unrecognized. Returns "" when nothing resolves.
func ResolveChipClass(family, tier, chipName string) string {
	if c := chipClassFromTokens(family + " " + tier); c != "" {
		return c
	}
	return chipClassFromTokens(chipName)
}

// chipClassFromTokens scans a string for an Apple-Silicon generation token
// (M1..M9, case-insensitive) and an optional tier (Pro/Max/Ultra) and returns
// the canonical class ("M3 Max"), or "" if no generation token is present.
func chipClassFromTokens(s string) string {
	gen := ""
	tier := ""
	for _, tok := range strings.Fields(s) {
		switch strings.ToLower(tok) {
		case "pro":
			tier = "Pro"
		case "max":
			tier = "Max"
		case "ultra":
			tier = "Ultra"
		default:
			if gen == "" && isAppleGenToken(tok) {
				gen = strings.ToUpper(tok) // "m3" → "M3"
			}
		}
	}
	if gen == "" {
		return ""
	}
	if tier == "" {
		return gen
	}
	return gen + " " + tier
}

// isAppleGenToken reports whether tok looks like "M<digits>" (e.g. m1..m5),
// case-insensitive.
func isAppleGenToken(tok string) bool {
	if len(tok) < 2 {
		return false
	}
	if tok[0] != 'm' && tok[0] != 'M' {
		return false
	}
	for _, r := range tok[1:] {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// ChipBandwidthForClass returns the table bandwidth (GB/s) for a chip class,
// falling back to the bare generation ("M3 Max" → "M3") when the exact tier is
// unknown, then 0 when the generation itself is unknown. Underestimating an
// unknown tier (using the base generation) is the safe direction: it lowers the
// expectation, raising the observed/expected ratio, so it cannot manufacture a
// false anomaly.
func ChipBandwidthForClass(class string) float64 {
	if class == "" {
		return 0
	}
	if bw, ok := ChipBandwidthGBps[class]; ok {
		return bw
	}
	if i := strings.IndexByte(class, ' '); i > 0 {
		if bw, ok := ChipBandwidthGBps[class[:i]]; ok {
			return bw
		}
	}
	return 0
}

// ThroughputAnomalyConfig holds the detector tunables.
type ThroughputAnomalyConfig struct {
	Efficiency     float64 // sustained fraction of peak bandwidth
	RatioThreshold float64 // observed/expected below this ⇒ anomaly
	MinSamples     int     // minimum observations before flagging
}

// DefaultThroughputAnomalyConfig returns the built-in defaults.
func DefaultThroughputAnomalyConfig() ThroughputAnomalyConfig {
	return ThroughputAnomalyConfig{
		Efficiency:     DefaultDecodeEfficiency,
		RatioThreshold: DefaultAnomalyRatioThreshold,
		MinSamples:     DefaultAnomalyMinSamples,
	}
}

// withDefaults fills any zero/negative field with its default, so a partially
// populated config (or the zero value) still behaves sensibly.
func (c ThroughputAnomalyConfig) withDefaults() ThroughputAnomalyConfig {
	if c.Efficiency <= 0 {
		c.Efficiency = DefaultDecodeEfficiency
	}
	if c.RatioThreshold <= 0 {
		c.RatioThreshold = DefaultAnomalyRatioThreshold
	}
	if c.MinSamples <= 0 {
		c.MinSamples = DefaultAnomalyMinSamples
	}
	return c
}

// ThroughputAnomalyInput is one aggregated (model, chip-class) decode
// observation for the fleet.
type ThroughputAnomalyInput struct {
	Model     string
	ChipClass string
	// BandwidthGBps overrides the chip table when > 0 (e.g. a provider-reported
	// memory_bandwidth_gbs). 0 means "look the class up in ChipBandwidthGBps".
	BandwidthGBps float64
	// ObservedTPS is the representative (e.g. median) observed decode TPS.
	ObservedTPS float64
	// Samples is the number of observations behind ObservedTPS.
	Samples int
}

// ThroughputAnomalyResult is the verdict for one (model, chip-class) bucket.
type ThroughputAnomalyResult struct {
	Model         string
	ChipClass     string
	ActiveParams  float64
	BytesPerParam float64
	BandwidthGBps float64
	ObservedTPS   float64
	ExpectedTPS   float64
	Ratio         float64 // ObservedTPS / ExpectedTPS (0 when not evaluable)
	Samples       int
	Evaluated     bool   // false ⇒ skipped (see SkipReason)
	SkipReason    string // why Evaluated is false ("" when evaluated)
	Anomalous     bool   // Evaluated && Ratio < RatioThreshold
}

// EvaluateThroughputAnomaly computes the expected decode TPS for the input's
// model/chip class and flags the bucket as anomalous when the observed decode is
// below cfg.RatioThreshold of expected, with at least cfg.MinSamples samples. It
// is pure: it reads only the package tables and the input.
func EvaluateThroughputAnomaly(in ThroughputAnomalyInput, cfg ThroughputAnomalyConfig) ThroughputAnomalyResult {
	cfg = cfg.withDefaults()
	res := ThroughputAnomalyResult{
		Model:       in.Model,
		ChipClass:   in.ChipClass,
		ObservedTPS: in.ObservedTPS,
		Samples:     in.Samples,
	}

	class, ok := LookupModelDecodeClass(in.Model)
	if !ok {
		res.SkipReason = "unknown_model"
		return res
	}
	res.ActiveParams = class.ActiveParams
	res.BytesPerParam = class.BytesPerParam

	bw := in.BandwidthGBps
	if bw <= 0 {
		bw = ChipBandwidthForClass(in.ChipClass)
	}
	res.BandwidthGBps = bw
	if bw <= 0 {
		res.SkipReason = "unknown_chip"
		return res
	}
	if in.ObservedTPS <= 0 {
		res.SkipReason = "no_observation"
		return res
	}
	if in.Samples < cfg.MinSamples {
		res.SkipReason = "insufficient_samples"
		return res
	}

	expected := ExpectedDecodeTPS(class.ActiveParams, class.BytesPerParam, bw, cfg.Efficiency)
	res.ExpectedTPS = expected
	if expected <= 0 {
		res.SkipReason = "no_expectation"
		return res
	}
	res.Ratio = in.ObservedTPS / expected
	res.Evaluated = true
	res.Anomalous = res.Ratio < cfg.RatioThreshold
	return res
}
