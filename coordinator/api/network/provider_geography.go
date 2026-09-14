package network

import (
	"sort"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// aggregateProviderLocations builds privacy-floored city and region
// buckets from the live provider fleet.
func (s *Controller) aggregateProviderLocations() (
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

	s.registry().ForEachProvider(func(p *registry.Provider) {
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
