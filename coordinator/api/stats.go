package api

import (
	"encoding/json"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Privacy floor constants: aggregated location buckets with fewer entries
// than these thresholds are suppressed from public stats to prevent
// de-anonymization of individual providers or consumers.
const (
	minProvidersPerCityBucket = 2
	minRequestsPerCityBucket  = 5
	minRequestsPerFlowBucket  = 5
)

// publicProviderLocationBucket is the privacy-safe shape returned to
// callers in the provider_locations array.
type publicProviderLocationBucket struct {
	Key              string   `json:"key"`
	Scope            string   `json:"scope"`
	City             string   `json:"city,omitempty"`
	Region           string   `json:"region,omitempty"`
	RegionCode       string   `json:"region_code,omitempty"`
	Country          string   `json:"country,omitempty"`
	CountryCode      string   `json:"country_code,omitempty"`
	Latitude         float64  `json:"latitude,omitempty"`
	Longitude        float64  `json:"longitude,omitempty"`
	Providers        int      `json:"providers"`
	HardwareAttested int      `json:"hardware_attested"`
	GPUCores         int      `json:"gpu_cores"`
	MemoryGB         int      `json:"memory_gb"`
	Models           []string `json:"models,omitempty"`
}

// publicRequestLocationBucket is the privacy-safe shape returned for
// request-origin location aggregation.
type publicRequestLocationBucket struct {
	Key              string  `json:"key"`
	Scope            string  `json:"scope"`
	City             string  `json:"city,omitempty"`
	Region           string  `json:"region,omitempty"`
	RegionCode       string  `json:"region_code,omitempty"`
	Country          string  `json:"country,omitempty"`
	CountryCode      string  `json:"country_code,omitempty"`
	Latitude         float64 `json:"latitude,omitempty"`
	Longitude        float64 `json:"longitude,omitempty"`
	Requests         int64   `json:"requests"`
	PromptTokens     int64   `json:"prompt_tokens"`
	CompletionTokens int64   `json:"completion_tokens"`
	Providers        int     `json:"providers"`
}

// publicRequestFlowBucket represents a directional flow of requests
// between a consumer region and a provider region.
type publicRequestFlowBucket struct {
	Key              string       `json:"key"`
	From             flowEndpoint `json:"from"`
	To               flowEndpoint `json:"to"`
	Requests         int64        `json:"requests"`
	PromptTokens     int64        `json:"prompt_tokens"`
	CompletionTokens int64        `json:"completion_tokens"`
}

type flowEndpoint struct {
	Key         string  `json:"key"`
	Kind        string  `json:"kind"` // "consumer" or "provider"
	City        string  `json:"city,omitempty"`
	Region      string  `json:"region,omitempty"`
	RegionCode  string  `json:"region_code,omitempty"`
	Country     string  `json:"country,omitempty"`
	CountryCode string  `json:"country_code,omitempty"`
	Latitude    float64 `json:"latitude,omitempty"`
	Longitude   float64 `json:"longitude,omitempty"`
}

// handleStats returns aggregate platform statistics for the frontend dashboard.
//
// Cached for 60s — the underlying SQL aggregation runs in <5ms but this
// endpoint is hit by every dashboard refresh and the homepage live ticker.
func (s *Server) handleStats(w http.ResponseWriter, r *http.Request) {
	const cacheKey = "stats:v1"
	if cached, ok := s.readCache.Get(cacheKey); ok {
		writeCachedJSON(w, cached)
		return
	}
	var (
		totalRequests    int64
		totalTokensGen   int64
		totalGPUCores    int
		totalCPUCores    int
		totalMemoryGB    int
		totalBandwidthGB float64
		providers        []map[string]any
		modelMap         = map[string]int{} // model ID → provider count
		activePowerWatts float64            // sum of estimated watts over online public providers
	)

	s.registry.ForEachProvider(func(p *registry.Provider) {
		// Private-only providers serve only their owner's self-route traffic and
		// are not part of the public fleet, so they must not inflate public
		// totals, provider counts, per-model provider counts, or active power.
		if p.PrivateOnly {
			return
		}
		activePowerWatts += registry.EstimateMachineWatts(p.Hardware.ChipFamily, p.Hardware.ChipTier, p.Hardware.GPUCores)
		totalRequests += p.Stats.RequestsServed
		totalTokensGen += p.Stats.TokensGenerated
		totalGPUCores += p.Hardware.GPUCores
		totalCPUCores += p.Hardware.CPUCores.Total
		totalMemoryGB += p.Hardware.MemoryGB
		totalBandwidthGB += p.Hardware.MemoryBandwidthGBs

		status := string(p.Status)
		if status == "" {
			status = "online"
		}

		// Collect available model IDs for this provider. p.Models is replaced
		// copy-on-write by UpdateModelWeightHashes on the challenge goroutine, so
		// its slice header must be read under p.mu; copy the IDs out and reuse the
		// local slice for both the per-provider list and the model histogram below.
		p.Mu().Lock()
		provModels := make([]string, 0, len(p.Models))
		for _, m := range p.Models {
			provModels = append(provModels, m.ID)
		}
		p.Mu().Unlock()

		lastChallengeVerified := ""
		if last := p.GetLastChallengeVerified(); !last.IsZero() {
			lastChallengeVerified = last.UTC().Format(time.RFC3339)
		}

		prov := map[string]any{
			"id":                      p.ID,
			"chip":                    p.Hardware.ChipName,
			"chip_family":             p.Hardware.ChipFamily,
			"chip_tier":               p.Hardware.ChipTier,
			"machine_model":           p.Hardware.MachineModel,
			"memory_gb":               p.Hardware.MemoryGB,
			"gpu_cores":               p.Hardware.GPUCores,
			"cpu_cores":               p.Hardware.CPUCores,
			"memory_bandwidth_gbs":    p.Hardware.MemoryBandwidthGBs,
			"status":                  status,
			"trust_level":             string(p.TrustLevel),
			"decode_tps":              p.DecodeTPS,
			"requests_served":         p.Stats.RequestsServed,
			"tokens_generated":        p.Stats.TokensGenerated,
			"models":                  provModels,
			"current_model":           p.CurrentModel,
			"attested":                p.Attested,
			"mda_verified":            p.MDAVerified,
			"acme_verified":           p.ACMEVerified,
			"runtime_verified":        p.RuntimeVerified,
			"certificate_available":   len(p.MDACertChain) > 0,
			"last_challenge_verified": lastChallengeVerified,
			"failed_challenges":       p.FailedChallenges,
		}
		providers = append(providers, prov)

		for _, id := range provModels {
			modelMap[id]++
		}
	})

	var models []map[string]any
	for id, count := range modelMap {
		models = append(models, map[string]any{
			"id":        id,
			"providers": count,
		})
	}
	if models == nil {
		models = []map[string]any{}
	}
	if providers == nil {
		providers = []map[string]any{}
	}

	// Read historical totals via SQL aggregation (no per-row wire transfer).
	totals := s.store.UsageTotals()
	if totals.Requests > totalRequests {
		totalRequests = totals.Requests
	}
	totalPromptTokens := totals.PromptTokens
	totalCompletionTokens := totals.CompletionTokens
	if totalTokensGen > totalCompletionTokens {
		totalCompletionTokens = totalTokensGen
	}
	totalTokens := totalPromptTokens + totalCompletionTokens

	var avgTokens float64
	if totalRequests > 0 {
		avgTokens = float64(totalTokens) / float64(totalRequests)
	}

	// Build time series via SQL bucket aggregation (last 30 minutes).
	now := time.Now()
	cutoff := now.Add(-30 * time.Minute)
	buckets := s.store.UsageTimeSeries(cutoff)

	timeSeries := make([]map[string]any, 0, len(buckets))
	for _, b := range buckets {
		timeSeries = append(timeSeries, map[string]any{
			"timestamp":         b.Minute.UTC().Format(time.RFC3339),
			"requests":          b.Requests,
			"prompt_tokens":     b.PromptTokens,
			"completion_tokens": b.CompletionTokens,
			"total_tokens":      b.PromptTokens + b.CompletionTokens,
		})
	}

	// --- Provider location aggregation ---
	providerLocations, providerRegions, unknownLocationProviders, suppressedCityProviders := s.aggregateProviderLocations()

	// --- Request location aggregation ---
	requestLocations, requestRegions, unknownRequestLocReqs, suppressedReqCityReqs := s.aggregateRequestLocations(cutoff)

	// --- Request flow aggregation ---
	requestFlows := s.aggregateRequestFlows(cutoff)

	// --- APNs code-identity coverage (for watching the grace→enforce rollout) ---
	codeAttestedProviders, _ := s.registry.CodeAttestationCoverage()
	codeAttestationEnforced := s.registry.CodeAttestationEnforced()

	resp := map[string]any{
		"total_requests":            totalRequests,
		"total_prompt_tokens":       totalPromptTokens,
		"total_completion_tokens":   totalCompletionTokens,
		"total_tokens":              totalTokens,
		"avg_tokens_per_request":    avgTokens,
		"active_providers":          len(providers),
		"active_power_watts":        activePowerWatts,
		"code_attested_providers":   codeAttestedProviders,
		"code_attestation_enforced": codeAttestationEnforced,
		"total_gpu_cores":           totalGPUCores,
		"total_cpu_cores":           totalCPUCores,
		"total_memory_gb":           totalMemoryGB,
		"total_bandwidth_gbs":       totalBandwidthGB,
		"network_capacity_tps":      0, // would need benchmark data
		"providers":                 providers,
		"models":                    models,
		"time_series":               timeSeries,

		// Location analytics (privacy-floored).
		"provider_locations":                 providerLocations,
		"provider_regions":                   providerRegions,
		"unknown_location_providers":         unknownLocationProviders,
		"suppressed_city_location_providers": suppressedCityProviders,
		"location_privacy_min_providers":     minProvidersPerCityBucket,

		"request_locations":                     requestLocations,
		"request_regions":                       requestRegions,
		"unknown_request_location_requests":     unknownRequestLocReqs,
		"suppressed_request_city_requests":      suppressedReqCityReqs,
		"request_location_privacy_min_requests": minRequestsPerCityBucket,

		"request_flows": requestFlows,
	}
	body, err := json.Marshal(resp)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to encode stats"))
		return
	}
	s.readCache.Set(cacheKey, body, time.Minute)
	writeCachedJSON(w, body)
}

// aggregateProviderLocations builds privacy-floored city and region
// buckets from the live provider fleet.
func (s *Server) aggregateProviderLocations() (
	cityBuckets []publicProviderLocationBucket,
	regionBuckets []publicProviderLocationBucket,
	unknownProviders int,
	suppressedCityProviders int,
) {
	type cityKey struct {
		City, Region, RegionCode, Country, CountryCode string
	}
	type regionKey struct {
		Region, RegionCode, Country, CountryCode string
	}
	type cityAgg struct {
		key              cityKey
		latSum, lngSum   float64
		coordCount       int
		providers        int
		hardwareAttested int
		gpuCores         int
		memoryGB         int
	}
	type regionAgg struct {
		key              regionKey
		latSum, lngSum   float64
		coordCount       int
		providers        int
		hardwareAttested int
		gpuCores         int
		memoryGB         int
	}
	cities := make(map[cityKey]*cityAgg)
	regions := make(map[regionKey]*regionAgg)

	s.registry.ForEachProvider(func(p *registry.Provider) {
		// Private-only providers are not part of the public fleet — keep them off
		// the public network map and out of its provider/hardware counts.
		if p.PrivateOnly {
			return
		}
		if p.Location == nil || p.Location.CountryCode == "" {
			unknownProviders++
			return
		}
		loc := p.Location
		hwAttested := 0
		if p.Attested && p.TrustLevel == registry.TrustHardware {
			hwAttested = 1
		}

		ck := cityKey{loc.City, loc.Region, loc.RegionCode, loc.Country, loc.CountryCode}
		ca, ok := cities[ck]
		if !ok {
			ca = &cityAgg{key: ck}
			cities[ck] = ca
		}
		ca.providers++
		ca.hardwareAttested += hwAttested
		ca.gpuCores += p.Hardware.GPUCores
		ca.memoryGB += p.Hardware.MemoryGB
		if loc.Latitude != 0 || loc.Longitude != 0 {
			ca.latSum += loc.Latitude
			ca.lngSum += loc.Longitude
			ca.coordCount++
		}

		rk := regionKey{loc.Region, loc.RegionCode, loc.Country, loc.CountryCode}
		ra, ok := regions[rk]
		if !ok {
			ra = &regionAgg{key: rk}
			regions[rk] = ra
		}
		ra.providers++
		ra.hardwareAttested += hwAttested
		ra.gpuCores += p.Hardware.GPUCores
		ra.memoryGB += p.Hardware.MemoryGB
		if loc.Latitude != 0 || loc.Longitude != 0 {
			ra.latSum += loc.Latitude
			ra.lngSum += loc.Longitude
			ra.coordCount++
		}
	})

	cityBuckets = make([]publicProviderLocationBucket, 0, len(cities))
	for _, ca := range cities {
		if ca.providers < minProvidersPerCityBucket {
			suppressedCityProviders += ca.providers
			continue
		}
		b := publicProviderLocationBucket{
			Key:              locationKey(ca.key.CountryCode, ca.key.RegionCode, ca.key.City),
			Scope:            "city",
			City:             ca.key.City,
			Region:           ca.key.Region,
			RegionCode:       ca.key.RegionCode,
			Country:          ca.key.Country,
			CountryCode:      ca.key.CountryCode,
			Providers:        ca.providers,
			HardwareAttested: ca.hardwareAttested,
			GPUCores:         ca.gpuCores,
			MemoryGB:         ca.memoryGB,
		}
		if ca.coordCount > 0 {
			b.Latitude = ca.latSum / float64(ca.coordCount)
			b.Longitude = ca.lngSum / float64(ca.coordCount)
		}
		cityBuckets = append(cityBuckets, b)
	}
	sort.Slice(cityBuckets, func(i, j int) bool {
		return cityBuckets[i].Providers > cityBuckets[j].Providers
	})

	regionBuckets = make([]publicProviderLocationBucket, 0, len(regions))
	for _, ra := range regions {
		b := publicProviderLocationBucket{
			Key:              locationKey(ra.key.CountryCode, ra.key.RegionCode, ""),
			Scope:            "region",
			Region:           ra.key.Region,
			RegionCode:       ra.key.RegionCode,
			Country:          ra.key.Country,
			CountryCode:      ra.key.CountryCode,
			Providers:        ra.providers,
			HardwareAttested: ra.hardwareAttested,
			GPUCores:         ra.gpuCores,
			MemoryGB:         ra.memoryGB,
		}
		if ra.coordCount > 0 {
			b.Latitude = ra.latSum / float64(ra.coordCount)
			b.Longitude = ra.lngSum / float64(ra.coordCount)
		}
		regionBuckets = append(regionBuckets, b)
	}
	sort.Slice(regionBuckets, func(i, j int) bool {
		return regionBuckets[i].Providers > regionBuckets[j].Providers
	})
	return
}

// aggregateRequestLocations builds privacy-floored city and region
// buckets from usage records with request-origin locations.
func (s *Server) aggregateRequestLocations(since time.Time) (
	cityBuckets []publicRequestLocationBucket,
	regionBuckets []publicRequestLocationBucket,
	unknownRequests int64,
	suppressedCityRequests int64,
) {
	locBuckets := s.store.UsageLocationBuckets(since)

	// Count requests without any location by subtracting located requests
	// from total requests in the window.
	var locatedRequests int64
	for _, b := range locBuckets {
		locatedRequests += b.Requests
	}
	// Total usage records in the window (SQL COUNT, no row transfer).
	totalInWindow := s.store.UsageCountSince(since)
	unknownRequests = totalInWindow - locatedRequests

	type cityKey struct {
		City, Region, RegionCode, Country, CountryCode string
	}
	type regionKey struct {
		Region, RegionCode, Country, CountryCode string
	}
	type cityAgg struct {
		key                              cityKey
		lat, lng                         float64
		requests, promptTok, completeTok int64
		providers                        int
	}
	type regionAgg struct {
		key                              regionKey
		latSum, lngSum                   float64
		coordCount                       int
		requests, promptTok, completeTok int64
		providers                        int
	}
	cities := make(map[cityKey]*cityAgg)
	regions := make(map[regionKey]*regionAgg)

	for _, b := range locBuckets {
		if b.CountryCode == "" {
			continue
		}
		ck := cityKey{b.City, b.Region, b.RegionCode, b.Country, b.CountryCode}
		ca, ok := cities[ck]
		if !ok {
			ca = &cityAgg{key: ck, lat: b.Latitude, lng: b.Longitude}
			cities[ck] = ca
		}
		ca.requests += b.Requests
		ca.promptTok += b.PromptTokens
		ca.completeTok += b.CompletionTokens
		ca.providers += b.Providers

		rk := regionKey{b.Region, b.RegionCode, b.Country, b.CountryCode}
		ra, ok := regions[rk]
		if !ok {
			ra = &regionAgg{key: rk}
			regions[rk] = ra
		}
		ra.requests += b.Requests
		ra.promptTok += b.PromptTokens
		ra.completeTok += b.CompletionTokens
		// Use max across city buckets as a conservative distinct-provider
		// estimate; summing would double-count providers serving multiple cities.
		if b.Providers > ra.providers {
			ra.providers = b.Providers
		}
		if b.Latitude != 0 || b.Longitude != 0 {
			ra.latSum += b.Latitude
			ra.lngSum += b.Longitude
			ra.coordCount++
		}
	}

	cityBuckets = make([]publicRequestLocationBucket, 0, len(cities))
	for _, ca := range cities {
		if ca.requests < int64(minRequestsPerCityBucket) {
			suppressedCityRequests += ca.requests
			continue
		}
		cityBuckets = append(cityBuckets, publicRequestLocationBucket{
			Key:              locationKey(ca.key.CountryCode, ca.key.RegionCode, ca.key.City),
			Scope:            "city",
			City:             ca.key.City,
			Region:           ca.key.Region,
			RegionCode:       ca.key.RegionCode,
			Country:          ca.key.Country,
			CountryCode:      ca.key.CountryCode,
			Latitude:         ca.lat,
			Longitude:        ca.lng,
			Requests:         ca.requests,
			PromptTokens:     ca.promptTok,
			CompletionTokens: ca.completeTok,
			Providers:        ca.providers,
		})
	}
	sort.Slice(cityBuckets, func(i, j int) bool {
		return cityBuckets[i].Requests > cityBuckets[j].Requests
	})

	regionBuckets = make([]publicRequestLocationBucket, 0, len(regions))
	for _, ra := range regions {
		b := publicRequestLocationBucket{
			Key:              locationKey(ra.key.CountryCode, ra.key.RegionCode, ""),
			Scope:            "region",
			Region:           ra.key.Region,
			RegionCode:       ra.key.RegionCode,
			Country:          ra.key.Country,
			CountryCode:      ra.key.CountryCode,
			Requests:         ra.requests,
			PromptTokens:     ra.promptTok,
			CompletionTokens: ra.completeTok,
			Providers:        ra.providers,
		}
		if ra.coordCount > 0 {
			b.Latitude = ra.latSum / float64(ra.coordCount)
			b.Longitude = ra.lngSum / float64(ra.coordCount)
		}
		regionBuckets = append(regionBuckets, b)
	}
	sort.Slice(regionBuckets, func(i, j int) bool {
		return regionBuckets[i].Requests > regionBuckets[j].Requests
	})
	return
}

// aggregateRequestFlows builds directional request flow buckets between
// consumer and provider regions. Uses a SQL JOIN via UsageFlowBuckets to
// avoid loading all usage rows + all provider rows into Go memory (the
// previous approach held two pool connections for up to 10s each).
func (s *Server) aggregateRequestFlows(since time.Time) []publicRequestFlowBucket {
	// Build live provider location map from the registry so recently-
	// connected providers (not yet persisted) are included.
	providerLocs := make(map[string]*store.ProviderLocation)
	s.registry.ForEachProvider(func(p *registry.Provider) {
		if p.Location != nil {
			cp := *p.Location
			providerLocs[p.ID] = &cp
		}
	})

	buckets := s.store.UsageFlowBuckets(since, providerLocs)

	out := make([]publicRequestFlowBucket, 0, len(buckets))
	for _, b := range buckets {
		if b.Requests < int64(minRequestsPerFlowBucket) {
			continue
		}
		fromKey := "consumer:" + locationKey(b.ConsumerCountryCode, b.ConsumerRegionCode, b.ConsumerCity)
		toKey := "provider:" + locationKey(b.ProviderCountryCode, b.ProviderRegionCode, b.ProviderCity)
		out = append(out, publicRequestFlowBucket{
			Key: fromKey + "->" + toKey,
			From: flowEndpoint{
				Key: fromKey, Kind: "consumer",
				City: b.ConsumerCity, Region: b.ConsumerRegion,
				RegionCode: b.ConsumerRegionCode, Country: b.ConsumerCountry,
				CountryCode: b.ConsumerCountryCode,
				Latitude:    b.ConsumerLatitude, Longitude: b.ConsumerLongitude,
			},
			To: flowEndpoint{
				Key: toKey, Kind: "provider",
				City: b.ProviderCity, Region: b.ProviderRegion,
				RegionCode: b.ProviderRegionCode, Country: b.ProviderCountry,
				CountryCode: b.ProviderCountryCode,
				Latitude:    b.ProviderLatitude, Longitude: b.ProviderLongitude,
			},
			Requests:         b.Requests,
			PromptTokens:     b.PromptTokens,
			CompletionTokens: b.CompletionTokens,
		})
	}
	sort.Slice(out, func(i, j int) bool {
		return out[i].Requests > out[j].Requests
	})
	if len(out) > 24 {
		out = out[:24]
	}
	return out
}

// locationKey builds a stable, lowercase key from country/region/city parts.
func locationKey(parts ...string) string {
	clean := make([]string, 0, len(parts))
	for _, part := range parts {
		part = strings.ToLower(strings.TrimSpace(part))
		if part != "" {
			clean = append(clean, part)
		}
	}
	return strings.Join(clean, "|")
}
