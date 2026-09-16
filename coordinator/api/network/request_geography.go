package network

import (
	"sort"
	"time"
)

// aggregateRequestLocations builds privacy-floored city and region
// buckets from usage records with request-origin locations. A failed query
// makes request locations unavailable without affecting the core snapshot.
func (s *Controller) aggregateRequestLocations(since time.Time) (
	cityBuckets []publicRequestLocationBucket,
	regionBuckets []publicRequestLocationBucket,
	unknownRequests int64,
	suppressedCityRequests int64,
	err error,
) {
	locBuckets, err := s.store().UsageLocationBuckets(since)
	if err != nil {
		return nil, nil, 0, 0, err
	}

	// Count requests without any location by subtracting located requests
	// from total requests in the window.
	var locatedRequests int64
	for _, b := range locBuckets {
		locatedRequests += b.Requests
	}
	// Total usage records in the window (SQL COUNT, no row transfer).
	var totalInWindow int64
	totalInWindow, err = s.store().UsageCountSince(since)
	if err != nil {
		return nil, nil, 0, 0, err
	}
	unknownRequests = max(0, totalInWindow-locatedRequests)

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
