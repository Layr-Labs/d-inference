package memory

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

// UsageLocationBuckets returns approximate request-origin aggregates (in-memory).
func (s *Store) UsageLocationBuckets(since time.Time) ([]contracts.UsageLocationBucket, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	type bucketKey struct {
		City        string
		Region      string
		RegionCode  string
		Country     string
		CountryCode string
	}
	type agg struct {
		key                              bucketKey
		latSum, lngSum                   float64
		coordCount                       int
		requests, promptTok, completeTok int64
		providers                        map[string]struct{}
	}
	buckets := make(map[bucketKey]*agg)
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
		loc := r.RequestLocation
		k := bucketKey{
			City:        loc.City,
			Region:      loc.Region,
			RegionCode:  loc.RegionCode,
			Country:     loc.Country,
			CountryCode: loc.CountryCode,
		}
		b, ok := buckets[k]
		if !ok {
			b = &agg{key: k, providers: make(map[string]struct{})}
			buckets[k] = b
		}
		b.requests++
		b.promptTok += int64(r.PromptTokens)
		b.completeTok += int64(r.CompletionTokens)
		if loc.Latitude != 0 || loc.Longitude != 0 {
			b.latSum += loc.Latitude
			b.lngSum += loc.Longitude
			b.coordCount++
		}
		if r.ProviderID != "" {
			b.providers[r.ProviderID] = struct{}{}
		}
	}
	out := make([]contracts.UsageLocationBucket, 0, len(buckets))
	for _, b := range buckets {
		var lat, lng float64
		if b.coordCount > 0 {
			lat = b.latSum / float64(b.coordCount)
			lng = b.lngSum / float64(b.coordCount)
		}
		out = append(out, contracts.UsageLocationBucket{
			City:             b.key.City,
			Region:           b.key.Region,
			RegionCode:       b.key.RegionCode,
			Country:          b.key.Country,
			CountryCode:      b.key.CountryCode,
			Latitude:         lat,
			Longitude:        lng,
			Requests:         b.requests,
			PromptTokens:     b.promptTok,
			CompletionTokens: b.completeTok,
			Providers:        len(b.providers),
		})
	}
	return out, nil
}
