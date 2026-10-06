package geo_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/geo"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestConsumerSafeLocationOmitsPreciseGeo(t *testing.T) {
	t.Parallel()
	if geo.ConsumerSafeLocation(nil) != nil {
		t.Fatal("nil location must stay omitted")
	}
	if geo.ConsumerSafeLocation(&store.ProviderLocation{}) != nil {
		t.Fatal("empty location must stay omitted")
	}
	got := geo.ConsumerSafeLocation(&store.ProviderLocation{
		City: "Austin", Region: "Texas", CountryCode: "US", Latitude: 30.2672, Source: "ip-api-pro",
	})
	if got == nil || got.Region != "Texas" || got.CountryCode != "US" {
		t.Fatalf("coarse location = %+v", got)
	}
	if geo.ConsumerSafeLocation(&store.ProviderLocation{
		City: "Austin", Latitude: 30.2672, Longitude: -97.7431, Source: "ip-api-pro",
	}) != nil {
		t.Fatal("city/coords-only location must stay omitted")
	}
}
