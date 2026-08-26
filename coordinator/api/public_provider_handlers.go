package api

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// publicHardware is the privacy-safe hardware subset for the public provider
// profile. Strips MemoryAvailableGB (live telemetry), CPUCores, and
// MemoryBandwidthGBs (not useful for public comparison).
type publicHardware struct {
	MachineModel string `json:"machine_model,omitempty"`
	ChipName     string `json:"chip_name,omitempty"`
	ChipFamily   string `json:"chip_family,omitempty"`
	ChipTier     string `json:"chip_tier,omitempty"`
	MemoryGB     int    `json:"memory_gb,omitempty"`
	GPUCores     int    `json:"gpu_cores,omitempty"`
}

// publicReputation is the privacy-safe reputation snapshot. Strips uptime
// (correlates with presence patterns) and FailedJobs (surfaced via Score).
type publicReputation struct {
	Score             float64 `json:"score"`
	TotalJobs         int     `json:"total_jobs"`
	SuccessfulJobs    int     `json:"successful_jobs"`
	AvgResponseTimeMs int64   `json:"avg_response_time_ms,omitempty"`
	ChallengesPassed  int     `json:"challenges_passed"`
}

// publicProviderProfile is the wire response for GET /v1/providers/{pseudonym}.
// It exposes only fields providers implicitly consent to share by joining the
// network. Earnings, wallet addresses, SE public keys, runtime hashes, and
// system internals are never included.
type publicProviderProfile struct {
	Pseudonym               string           `json:"pseudonym"`
	Status                  string           `json:"status"`
	TrustLevel              string           `json:"trust_level"`
	Hardware                publicHardware   `json:"hardware"`
	WarmModels              []string         `json:"warm_models"`
	MaxConcurrency          int              `json:"max_concurrency"`
	Reputation              publicReputation `json:"reputation"`
	LifetimeTokensGenerated int64            `json:"lifetime_tokens_generated"`
}

// providerCandidate is an intermediate snapshot taken inside ForEachProvider
// under p.Mu() to avoid holding any lock after the iteration step.
type providerCandidate struct {
	status          string
	trustLevel      string
	hardware        protocol.Hardware
	warmModels      []string
	maxConcurrency  int
	reputation      registry.Reputation
	tokensGenerated int64
}

// handlePublicProviderProfile returns a privacy-safe profile for a provider
// identified by pseudonym. All machines belonging to the same account share
// the same pseudonym; when multiple are live the profile aggregates across
// all of them (best trust, union of warm models, summed reputation).
//
// GET /v1/providers/{pseudonym}
//
// Returns 404 when no live provider with that pseudonym is connected.
func (s *Server) handlePublicProviderProfile(w http.ResponseWriter, r *http.Request) {
	requestedPseudonym := r.PathValue("pseudonym")
	if requestedPseudonym == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "pseudonym required"))
		return
	}

	cacheKey := "public_provider:" + requestedPseudonym
	if cached, ok := s.readCache.Get(cacheKey); ok {
		writeCachedJSON(w, cached)
		return
	}

	profile := s.buildPublicProfile(requestedPseudonym)
	if profile == nil {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "provider not found or offline"))
		return
	}

	body, err := json.Marshal(profile)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to encode response"))
		return
	}
	s.readCache.Set(cacheKey, body, 30*time.Second)
	writeCachedJSON(w, body)
}

// buildPublicProfile iterates the live registry and aggregates a public profile
// for all providers belonging to the account identified by pseudonym.
// Returns nil when no matching live provider is found.
func (s *Server) buildPublicProfile(requestedPseudonym string) *publicProviderProfile {
	var candidates []providerCandidate

	s.registry.ForEachProvider(func(p *registry.Provider) {
		p.Mu().Lock()
		defer p.Mu().Unlock()

		if pseudonym(p.AccountID) != requestedPseudonym {
			return
		}

		wm := make([]string, len(p.WarmModels))
		copy(wm, p.WarmModels)

		candidates = append(candidates, providerCandidate{
			status:          string(p.Status),
			trustLevel:      string(p.TrustLevel),
			hardware:        p.Hardware,
			warmModels:      wm,
			maxConcurrency:  concurrencyFromCapacity(p.BackendCapacity, p.Hardware.MemoryGB),
			reputation:      p.Reputation,
			tokensGenerated: p.Stats.TokensGenerated,
		})
	})

	if len(candidates) == 0 {
		return nil
	}

	bestStatus := mergedProviderStatus(candidates)
	bestTrust := mergedTrustLevel(candidates)
	allModels := mergedWarmModels(candidates)
	hw := hardwareForProviders(candidates)

	totalConcurrency := 0
	aggRep := registry.Reputation{}
	var bestLatencyCandidate *providerCandidate
	totalTokens := int64(0)

	for i := range candidates {
		c := &candidates[i]
		totalConcurrency += c.maxConcurrency
		aggRep.TotalJobs += c.reputation.TotalJobs
		aggRep.SuccessfulJobs += c.reputation.SuccessfulJobs
		aggRep.FailedJobs += c.reputation.FailedJobs
		aggRep.ChallengesPassed += c.reputation.ChallengesPassed
		aggRep.ChallengesFailed += c.reputation.ChallengesFailed
		totalTokens += c.tokensGenerated
		// Use the machine with the most jobs as the representative latency source.
		if c.reputation.AvgResponseTime > 0 &&
			(bestLatencyCandidate == nil || c.reputation.TotalJobs > bestLatencyCandidate.reputation.TotalJobs) {
			bestLatencyCandidate = c
		}
	}
	if bestLatencyCandidate != nil {
		aggRep.AvgResponseTime = bestLatencyCandidate.reputation.AvgResponseTime
	}

	return &publicProviderProfile{
		Pseudonym:      requestedPseudonym,
		Status:         bestStatus,
		TrustLevel:     bestTrust,
		Hardware:       hw,
		WarmModels:     allModels,
		MaxConcurrency: totalConcurrency,
		Reputation: publicReputation{
			Score:             aggRep.Score(),
			TotalJobs:         aggRep.TotalJobs,
			SuccessfulJobs:    aggRep.SuccessfulJobs,
			AvgResponseTimeMs: aggRep.AvgResponseTime.Milliseconds(),
			ChallengesPassed:  aggRep.ChallengesPassed,
		},
		LifetimeTokensGenerated: totalTokens,
	}
}

// mergedProviderStatus returns the best operational status across candidates:
// "online"/"serving" > "untrusted" > "offline".
func mergedProviderStatus(candidates []providerCandidate) string {
	best := "offline"
	for _, c := range candidates {
		switch c.status {
		case "online", "serving":
			return c.status
		case "untrusted":
			if best == "offline" {
				best = "untrusted"
			}
		}
	}
	return best
}

// mergedTrustLevel returns the highest trust level across candidates:
// hardware > self_signed > none.
func mergedTrustLevel(candidates []providerCandidate) string {
	best := string(registry.TrustNone)
	for _, c := range candidates {
		if c.trustLevel == string(registry.TrustHardware) {
			return string(registry.TrustHardware)
		}
		if c.trustLevel == string(registry.TrustSelfSigned) {
			best = string(registry.TrustSelfSigned)
		}
	}
	return best
}

// mergedWarmModels returns the union of warm models across candidates,
// preserving order of first occurrence.
func mergedWarmModels(candidates []providerCandidate) []string {
	seen := make(map[string]bool)
	var result []string
	for _, c := range candidates {
		for _, m := range c.warmModels {
			if !seen[m] {
				seen[m] = true
				result = append(result, m)
			}
		}
	}
	if result == nil {
		return []string{}
	}
	return result
}

// concurrencyFromCapacity mirrors registry.Provider.maxConcurrency() but reads
// only already-copied values so it is safe to call while holding p.Mu().
// Using the unexported method would require a re-entrant lock acquisition,
// which deadlocks — this inline copy avoids that.
func concurrencyFromCapacity(cap *protocol.BackendCapacity, memGB int) int {
	const defaultConcurrent = 4 // mirrors registry.DefaultMaxConcurrent
	if cap == nil {
		return defaultConcurrent
	}
	for _, slot := range cap.Slots {
		if slot.ActiveTokenBudgetMax > 0 {
			return 24
		}
	}
	mem := cap.TotalMemoryGB
	if mem <= 0 {
		mem = float64(memGB)
	}
	switch {
	case mem <= 24:
		return 2
	case mem <= 48:
		return 4
	case mem <= 96:
		return 6
	case mem <= 128:
		return 8
	default:
		return 12
	}
}

// hardwareForProviders returns the hardware of the first online/serving
// candidate, falling back to the first candidate overall.
func hardwareForProviders(candidates []providerCandidate) publicHardware {
	hw := candidates[0].hardware
	for _, c := range candidates {
		if c.status == "online" || c.status == "serving" {
			hw = c.hardware
			break
		}
	}
	return publicHardware{
		MachineModel: hw.MachineModel,
		ChipName:     hw.ChipName,
		ChipFamily:   hw.ChipFamily,
		ChipTier:     hw.ChipTier,
		MemoryGB:     hw.MemoryGB,
		GPUCores:     hw.GPUCores,
	}
}
