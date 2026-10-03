// Package selection ranks detached candidate values. It owns neither provider
// state nor random generators; the registry supplies the tie-breaking draw.
package selection

const FastBandMs = 100.0

// Candidate contains only the values used to rank an already eligible provider.
type Candidate struct {
	ProviderID                                      string
	ExpectedMs, HealthMs, CapacityRateMs, ServiceMs float64
	CachedTokens, CacheSavedMs, CacheEvidenceWeight float64
	AffinityEligible                                bool
}

// RankMs retains health/capacity derating separately from elapsed-time forecasts.
func (c Candidate) RankMs() float64 {
	return c.ExpectedMs + c.HealthMs + c.CapacityRateMs
}

type Path uint8

const (
	None Path = iota
	UniqueMin
	TiePending
	Random
	PrefixAffinity
	CacheCredit
)

// Ranking describes the fast-band/service-work equivalence class. The same
// candidate slice must be passed to Choose after drawing Intn(Choices).
type Ranking struct {
	NearTieSize, Choices         int
	bestRank, work, creditWeight float64
	credited                     bool
}

// Rank chooses least committed whole-Mac service inside the 100 ms fast band,
// then prefers validated cache benefit and the strongest evidence weight.
func Rank(pool []Candidate) Ranking {
	var result Ranking
	if len(pool) == 0 {
		return result
	}
	best := pool[0]
	for _, c := range pool[1:] {
		if c.RankMs() < best.RankMs() {
			best = c
		}
	}
	result.bestRank = best.RankMs()
	for _, c := range pool {
		if !result.near(c) {
			continue
		}
		result.NearTieSize++
		if result.NearTieSize == 1 || c.ServiceMs < result.work {
			result.work = c.ServiceMs
		}
	}
	for _, c := range pool {
		if result.workTie(c) && c.CachedTokens > 0 && c.CacheSavedMs > 0 {
			result.credited = true
			result.creditWeight = max(result.creditWeight, c.CacheEvidenceWeight)
		}
	}
	for _, c := range pool {
		if result.equivalent(c) {
			result.Choices++
		}
	}
	return result
}

func (r Ranking) near(c Candidate) bool {
	return c.RankMs() <= r.bestRank+FastBandMs
}

func (r Ranking) workTie(c Candidate) bool {
	return r.near(c) && c.ServiceMs == r.work
}

func (r Ranking) equivalent(c Candidate) bool {
	return r.workTie(c) && (!r.credited || (c.CachedTokens > 0 && c.CacheSavedMs > 0 && c.CacheEvidenceWeight == r.creditWeight))
}

// Decision refers to indices in the unchanged input pool; -1 means no candidate.
type Decision struct {
	Winner, RunnerUp, NearTieSize int
	Path                          Path
}

// Choose applies the caller's uniform draw, then optional stable cache affinity.
// For a nonempty pool draw must be in [0, Choices). The runner-up is the first
// minimum-rank candidate other than the winner, including outside the fast band.
func (r Ranking) Choose(pool []Candidate, draw int, affinity string) Decision {
	result := Decision{Winner: -1, RunnerUp: -1, NearTieSize: r.NearTieSize}
	if len(pool) == 0 {
		return result
	}
	for i, c := range pool {
		if !r.equivalent(c) {
			continue
		}
		if draw == 0 {
			result.Winner = i
			break
		}
		draw--
	}
	switch {
	case r.NearTieSize == 1:
		result.Path = UniqueMin
	case r.credited:
		result.Path = CacheCredit
	case r.Choices > 1:
		result.Path = Random
	default:
		result.Path = TiePending
	}
	if affinity != "" && r.Choices > 1 {
		if preferred := r.affinityWinner(pool, affinity); preferred >= 0 {
			result.Winner, result.Path = preferred, PrefixAffinity
		}
	}
	for i, c := range pool {
		if i != result.Winner && (result.RunnerUp < 0 || c.RankMs() < pool[result.RunnerUp].RankMs()) {
			result.RunnerUp = i
		}
	}
	return result
}
