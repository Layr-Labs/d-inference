// Package quality owns model-specific solo-rate resolution and admission caps.
package quality

import (
	"math"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
)

const (
	DefaultOvercommit  = 1.2
	DefaultMinSamples  = 5
	SeedClassSeparator = "@"
)

type Config struct {
	Enabled         bool
	Overcommit      float64
	FloorTPS        float64
	Fallback        int
	PerModelTPS     bool
	MinSamples      int
	SoloSeed        string
	ModelOvercommit string
}

// Policy is configured under the registry lock before serving. Its seed and
// override indexes are private and reads allocate no temporary lookup keys.
type Policy struct {
	configured        bool
	config            Config
	seedByClass       map[string]map[string]float64
	seedFleet         map[string]float64
	overcommitByModel map[string]float64
}

func New(config Config) *Policy {
	p := &Policy{}
	p.Configure(config)
	return p
}

func (p *Policy) Configure(config Config) {
	config.MinSamples = max(1, config.MinSamples)
	config.Fallback = max(1, config.Fallback)
	if config.Overcommit <= 0 {
		config.Overcommit = 1
	}
	p.config = config
	p.configured = true
	seed := ParseModelFloatMap(config.SoloSeed)
	p.seedByClass = SeedByClass(seed)
	p.seedFleet = SeedFleetFallbacks(seed)
	p.overcommitByModel = ParseModelFloatMap(config.ModelOvercommit)
}

func (p *Policy) SeedForClass(model, chipClass string) (float64, bool) {
	model = strings.ToLower(model)
	if chipClass != "" && p.seedByClass != nil {
		if byClass := p.seedByClass[model]; byClass != nil {
			if rate, ok := byClass[strings.ToLower(chipClass)]; ok {
				return rate, true
			}
		}
	}
	rate, ok := p.seedFleet[model]
	return rate, ok
}

func (p *Policy) Overcommit(model string) float64 {
	if rate, ok := p.overcommitByModel[strings.ToLower(model)]; ok {
		return rate
	}
	return p.config.Overcommit
}

// SoloEvidence carries cached scalar aggregates, never the underlying rings.
// A value boundary also keeps chip-class lookup strings from escaping through
// an opaque throughput interface on every routing candidate.
type SoloEvidence struct {
	ClassTPS     float64
	ClassSamples int
	MinimumTPS   float64
	TotalSamples int
	Classes      int
}

type Rate struct {
	TPS      float64
	PerModel bool
}

// Resolve applies same-class evidence, bounded cross-class evidence, seeds,
// then provider-level fallback, preserving both trust tiers and provenance.
func (p *Policy) Resolve(samples SoloEvidence, model, chipClass string, fallback float64, destinationBound bool) Rate {
	minSamples := p.MinSamples()
	if p.PerModelEnabled() {
		classTPS, classN := samples.ClassTPS, samples.ClassSamples
		if classN >= minSamples && classTPS > 0 {
			return Rate{TPS: classTPS, PerModel: true}
		}
		seed, hasSeed := p.SeedForClass(model, chipClass)
		allTPS, allN, allClasses := samples.MinimumTPS, samples.TotalSamples, samples.Classes
		if allTPS > 0 && hasSeed && seed < allTPS {
			allTPS = seed
		}
		if allTPS > 0 && classN == 0 && destinationBound && fallback < allTPS {
			allTPS = fallback
		}
		crossClassBounded := hasSeed || classN > 0 || allClasses > 1
		if crossClassBounded && allN >= minSamples && allTPS > 0 {
			return Rate{TPS: allTPS, PerModel: true}
		}
		if classN > 0 && classTPS > 0 {
			return Rate{TPS: classTPS, PerModel: true}
		}
		if crossClassBounded && allN > 0 && allTPS > 0 {
			return Rate{TPS: allTPS, PerModel: true}
		}
		if hasSeed {
			return Rate{TPS: seed, PerModel: true}
		}
	}
	return Rate{TPS: fallback}
}

func (p *Policy) PerModelEnabled() bool {
	return !p.configured || p.config.PerModelTPS
}

// MinSamples is the configured evidence threshold used for routing and
// Autopilot's measured classification, including zero-value defaults.
func (p *Policy) MinSamples() int {
	if !p.configured {
		return DefaultMinSamples
	}
	return p.config.MinSamples
}

// Cap preserves the provider's own limit and only constrains a hardware proxy
// for dedicated models. Reviewed profiles use their measured conservative curve.
func (p *Policy) Cap(model string, base int, rate Rate, hasBenchmark, dedicated bool, loadFactor float64, profile *performance.Profile) int {
	if profile != nil {
		floor := 0.0
		if p.config.Enabled {
			floor = p.config.FloorTPS
		}
		return profile.ConcurrencyForDecodeFloor(base, floor)
	}
	if !p.config.Enabled || (!hasBenchmark && !rate.PerModel && !dedicated) {
		return base
	}
	qc := warmplan.QualityConcurrency(rate.TPS, p.config.FloorTPS, loadFactor, base, p.config.Fallback)
	capped := max(1, int(math.Ceil(float64(qc)*p.Overcommit(model))))
	return min(capped, base)
}
