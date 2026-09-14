package throughput

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

// AnomalyConfig holds the detector tunables.
type AnomalyConfig struct {
	Efficiency     float64 // sustained fraction of peak bandwidth
	RatioThreshold float64 // observed/expected below this ⇒ anomaly
	MinSamples     int     // minimum observations before flagging
}

// DefaultAnomalyConfig returns the built-in defaults.
func DefaultAnomalyConfig() AnomalyConfig {
	return AnomalyConfig{
		Efficiency:     DefaultDecodeEfficiency,
		RatioThreshold: DefaultAnomalyRatioThreshold,
		MinSamples:     DefaultAnomalyMinSamples,
	}
}

// withDefaults replaces invalid fields with their defaults, so a partially
// populated config (or the zero value) still behaves sensibly.
func (c AnomalyConfig) withDefaults() AnomalyConfig {
	if !finitePositive(c.Efficiency) {
		c.Efficiency = DefaultDecodeEfficiency
	}
	if !finitePositive(c.RatioThreshold) {
		c.RatioThreshold = DefaultAnomalyRatioThreshold
	}
	if c.MinSamples <= 0 {
		c.MinSamples = DefaultAnomalyMinSamples
	}
	return c
}

// AnomalyInput is one aggregated (model, chip-class) decode
// observation for the fleet.
type AnomalyInput struct {
	Model     string
	ChipClass string
	// BandwidthGBps overrides the chip table when > 0 (e.g. a provider-reported
	// memory_bandwidth_gbs). 0 means "look the class up in chipBandwidthGBps".
	BandwidthGBps float64
	// ObservedTPS is the representative (e.g. median) observed decode TPS.
	ObservedTPS float64
	// Samples is the number of observations behind ObservedTPS.
	Samples int
}

// AnomalyResult is the verdict for one (model, chip-class) bucket.
type AnomalyResult struct {
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

// EvaluateAnomaly computes the expected decode TPS for the input's
// model/chip class and flags the bucket as anomalous when the observed decode is
// below cfg.RatioThreshold of expected, with at least cfg.MinSamples samples. It
// is pure: it reads only the package tables and the input.
func (p Policy) EvaluateAnomaly(in AnomalyInput, cfg AnomalyConfig) AnomalyResult {
	cfg = cfg.withDefaults()
	res := AnomalyResult{
		Model:       in.Model,
		ChipClass:   in.ChipClass,
		ObservedTPS: in.ObservedTPS,
		Samples:     in.Samples,
	}

	class, ok := p.LookupModelDecodeClass(in.Model)
	if !ok {
		res.SkipReason = "unknown_model"
		return res
	}
	res.ActiveParams = class.ActiveParams
	res.BytesPerParam = class.BytesPerParam

	bw := in.BandwidthGBps
	if !finitePositive(bw) {
		bw = p.ChipBandwidthForClass(in.ChipClass)
	}
	res.BandwidthGBps = bw
	if !finitePositive(bw) {
		res.SkipReason = "unknown_chip"
		return res
	}
	if !finitePositive(in.ObservedTPS) {
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
