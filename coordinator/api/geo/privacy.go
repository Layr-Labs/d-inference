package geo

import (
	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func ConsumerSafeLocation(loc *store.ProviderLocation) *types.ProviderApproxLocation {
	if loc == nil {
		return nil
	}
	if loc.Region == "" && loc.RegionCode == "" && loc.Country == "" && loc.CountryCode == "" && loc.Timezone == "" {
		return nil
	}
	return &types.ProviderApproxLocation{
		Region:      loc.Region,
		RegionCode:  loc.RegionCode,
		Country:     loc.Country,
		CountryCode: loc.CountryCode,
		Timezone:    loc.Timezone,
	}
}
