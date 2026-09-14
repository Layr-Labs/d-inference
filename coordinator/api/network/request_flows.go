package network

import (
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// aggregateRequestFlows builds directional request flow buckets between
// consumer and provider regions. Uses a SQL JOIN via UsageFlowBuckets to
// avoid loading all usage rows + all provider rows into Go memory (the
// previous approach held two pool connections for up to 10s each).
func (s *Controller) aggregateRequestFlows(since time.Time) ([]publicRequestFlowBucket, error) {
	// Build live provider location map from the registry so recently-
	// connected providers (not yet persisted) are included.
	providerLocs := make(map[string]*store.ProviderLocation)
	s.registry().ForEachProvider(func(p *registry.Provider) {
		if p.Location != nil {
			cp := *p.Location
			providerLocs[p.ID] = &cp
		}
	})

	buckets, err := s.store().UsageFlowBuckets(since, providerLocs)
	if err != nil {
		return nil, err
	}

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
	return out, nil
}
