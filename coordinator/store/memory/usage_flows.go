package memory

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

// UsageFlowBuckets aggregates directional consumer→provider flows in memory.
// providerLocs supplies live provider locations from the registry; the store's
// own providerRecords are used as a fallback for disconnected providers.
func (s *Store) UsageFlowBuckets(since time.Time, providerLocs map[string]*contracts.ProviderLocation) ([]contracts.UsageFlowBucket, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	type flowKey struct {
		cCity, cRegion, cCountry string
		pCity, pRegion, pCountry string
	}
	type agg struct {
		b         contracts.UsageFlowBucket
		cLatSum   float64
		cLngSum   float64
		cCoordCnt int
		pLatSum   float64
		pLngSum   float64
		pCoordCnt int
	}

	// Resolve provider location: prefer live registry, fall back to stored records.
	resolveProviderLoc := func(providerID string) *contracts.ProviderLocation {
		if loc, ok := providerLocs[providerID]; ok && loc != nil {
			return loc
		}
		if rec, ok := s.providerRecords[providerID]; ok {
			return rec.Location
		}
		return nil
	}

	flows := make(map[flowKey]*agg)
	for _, r := range s.usage {
		ts := r.Timestamp
		if ts.IsZero() {
			ts = r.CreatedAt
		}
		if !since.IsZero() && ts.Before(since) {
			continue
		}
		if r.RequestLocation == nil {
			continue
		}
		pLoc := resolveProviderLoc(r.ProviderID)
		if pLoc == nil {
			continue
		}
		cLoc := r.RequestLocation
		k := flowKey{
			cCity: cLoc.City, cRegion: cLoc.RegionCode, cCountry: cLoc.CountryCode,
			pCity: pLoc.City, pRegion: pLoc.RegionCode, pCountry: pLoc.CountryCode,
		}
		fa, ok := flows[k]
		if !ok {
			fa = &agg{b: contracts.UsageFlowBucket{
				ConsumerCity: cLoc.City, ConsumerRegion: cLoc.Region,
				ConsumerRegionCode: cLoc.RegionCode, ConsumerCountry: cLoc.Country,
				ConsumerCountryCode: cLoc.CountryCode,
				ProviderCity:        pLoc.City, ProviderRegion: pLoc.Region,
				ProviderRegionCode: pLoc.RegionCode, ProviderCountry: pLoc.Country,
				ProviderCountryCode: pLoc.CountryCode,
			}}
			flows[k] = fa
		}
		fa.b.Requests++
		fa.b.PromptTokens += int64(r.PromptTokens)
		fa.b.CompletionTokens += int64(r.CompletionTokens)
		if cLoc.Latitude != 0 || cLoc.Longitude != 0 {
			fa.cLatSum += cLoc.Latitude
			fa.cLngSum += cLoc.Longitude
			fa.cCoordCnt++
		}
		if pLoc.Latitude != 0 || pLoc.Longitude != 0 {
			fa.pLatSum += pLoc.Latitude
			fa.pLngSum += pLoc.Longitude
			fa.pCoordCnt++
		}
	}

	out := make([]contracts.UsageFlowBucket, 0, len(flows))
	for _, fa := range flows {
		b := fa.b
		if fa.cCoordCnt > 0 {
			b.ConsumerLatitude = fa.cLatSum / float64(fa.cCoordCnt)
			b.ConsumerLongitude = fa.cLngSum / float64(fa.cCoordCnt)
		}
		if fa.pCoordCnt > 0 {
			b.ProviderLatitude = fa.pLatSum / float64(fa.pCoordCnt)
			b.ProviderLongitude = fa.pLngSum / float64(fa.pCoordCnt)
		}
		out = append(out, b)
	}
	return out, nil
}
