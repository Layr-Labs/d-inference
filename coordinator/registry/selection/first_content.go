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

// Select projects eligible inputs without retaining their owners. Ordinary
// fleets use stack storage; large fleets spill once, never once per candidate.
// The draw remains caller-owned so ranking owns no random-generator state.
func Select[T any](pool []T, project func(T) Candidate, draw func(int) int, affinity string) Decision {
	if len(pool) == 0 {
		return Decision{Winner: -1, RunnerUp: -1, Path: None}
	}
	var inline [512]Candidate
	values := inline[:0]
	if len(pool) > len(inline) {
		values = make([]Candidate, 0, len(pool))
	}
	for _, candidate := range pool {
		values = append(values, project(candidate))
	}
	ranking := Rank(values)
	return ranking.Choose(values, draw(ranking.Choices), affinity)
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
	// Every pass reads candidates in place; copying each one per pass costs
	// more than the comparisons on a fleet-sized pool.
	result.bestRank = pool[0].RankMs()
	for i := 1; i < len(pool); i++ {
		// Keep the strict comparison: unlike min, it never adopts a NaN rank.
		if rank := pool[i].RankMs(); rank < result.bestRank {
			result.bestRank = rank
		}
	}
	for i := range pool {
		c := &pool[i]
		if !result.near(c) {
			continue
		}
		result.NearTieSize++
		if result.NearTieSize == 1 || c.ServiceMs < result.work {
			result.work = c.ServiceMs
		}
	}
	for i := range pool {
		c := &pool[i]
		if result.workTie(c) && c.CachedTokens > 0 && c.CacheSavedMs > 0 {
			result.credited = true
			result.creditWeight = max(result.creditWeight, c.CacheEvidenceWeight)
		}
	}
	for i := range pool {
		if result.equivalent(&pool[i]) {
			result.Choices++
		}
	}
	return result
}

func (r Ranking) near(c *Candidate) bool {
	return c.RankMs() <= r.bestRank+FastBandMs
}

func (r Ranking) workTie(c *Candidate) bool {
	return r.near(c) && c.ServiceMs == r.work
}

func (r Ranking) equivalent(c *Candidate) bool {
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
	for i := range pool {
		if !r.equivalent(&pool[i]) {
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
	for i := range pool {
		if i != result.Winner && (result.RunnerUp < 0 || pool[i].RankMs() < pool[result.RunnerUp].RankMs()) {
			result.RunnerUp = i
		}
	}
	return result
}
