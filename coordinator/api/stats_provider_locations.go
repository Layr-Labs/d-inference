package api

import (
	"sort"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// providerLocationSnapshot is detached during the same locked fleet walk as
// provider rows and verification totals. Later store reads cannot change it.
type providerLocationSnapshot struct {
	location         store.ProviderLocation
	hasLocation      bool
	verification     registry.Verification
	hardwareAttested int
	gpuCores         int
	memoryGB         int
}

// aggregateProviderLocations builds privacy-floored city and region buckets
// from the exact fleet snapshot used for provider rows and verification totals.
func aggregateProviderLocations(snapshots []providerLocationSnapshot) (
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
		verification     verificationMethodCounts
		gpuCores         int
		memoryGB         int
	}
	type regionAgg struct {
		key              regionKey
		latSum, lngSum   float64
		coordCount       int
		providers        int
		hardwareAttested int
		verification     verificationMethodCounts
		gpuCores         int
		memoryGB         int
	}
	cities := make(map[cityKey]*cityAgg)
	regions := make(map[regionKey]*regionAgg)

	for _, snapshot := range snapshots {
		if !snapshot.hasLocation || snapshot.location.CountryCode == "" {
			unknownProviders++
			continue
		}
		loc := snapshot.location

		ck := cityKey{loc.City, loc.Region, loc.RegionCode, loc.Country, loc.CountryCode}
		ca, ok := cities[ck]
		if !ok {
			ca = &cityAgg{key: ck}
			cities[ck] = ca
		}
		ca.providers++
		ca.verification.add(snapshot.verification)
		ca.hardwareAttested += snapshot.hardwareAttested
		ca.gpuCores += snapshot.gpuCores
		ca.memoryGB += snapshot.memoryGB
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
		ra.verification.add(snapshot.verification)
		ra.hardwareAttested += snapshot.hardwareAttested
		ra.gpuCores += snapshot.gpuCores
		ra.memoryGB += snapshot.memoryGB
		if loc.Latitude != 0 || loc.Longitude != 0 {
			ra.latSum += loc.Latitude
			ra.lngSum += loc.Longitude
			ra.coordCount++
		}
	}

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
			Verification:     ca.verification,
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
			Verification:     ra.verification,
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
