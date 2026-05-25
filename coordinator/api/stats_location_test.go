package api

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestStatsAggregatesProviderLocationsWithPrivacyFloor(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := registry.New(logger)
	st := store.NewMemory("")
	srv := NewServer(reg, st, logger)

	addProviderForStats(t, reg, "sf-1", "hardware", &store.ProviderLocation{
		City:        "San Francisco",
		Region:      "California",
		RegionCode:  "CA",
		Country:     "United States",
		CountryCode: "US",
		Latitude:    37.7749,
		Longitude:   -122.4194,
		UpdatedAt:   time.Now().UTC(),
	})
	addProviderForStats(t, reg, "sf-2", "none", &store.ProviderLocation{
		City:        "San Francisco",
		Region:      "California",
		RegionCode:  "CA",
		Country:     "United States",
		CountryCode: "US",
		Latitude:    37.7749,
		Longitude:   -122.4194,
		UpdatedAt:   time.Now().UTC(),
	})
	addProviderForStats(t, reg, "nyc-1", "hardware", &store.ProviderLocation{
		City:        "New York",
		Region:      "New York",
		RegionCode:  "NY",
		Country:     "United States",
		CountryCode: "US",
		Latitude:    40.7128,
		Longitude:   -74.0060,
		UpdatedAt:   time.Now().UTC(),
	})
	addProviderForStats(t, reg, "unknown-1", "hardware", nil)

	rr := httptest.NewRecorder()
	srv.handleStats(rr, httptest.NewRequest(http.MethodGet, "/v1/stats", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rr.Code, rr.Body.String())
	}

	var body struct {
		ProviderLocations               []publicProviderLocationBucket `json:"provider_locations"`
		ProviderRegions                 []publicProviderLocationBucket `json:"provider_regions"`
		UnknownLocationProviders        int                            `json:"unknown_location_providers"`
		SuppressedCityLocationProviders int                            `json:"suppressed_city_location_providers"`
		LocationPrivacyMinProviders     int                            `json:"location_privacy_min_providers"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}

	if body.LocationPrivacyMinProviders != minProvidersPerCityBucket {
		t.Fatalf("privacy floor = %d", body.LocationPrivacyMinProviders)
	}
	if body.UnknownLocationProviders != 1 {
		t.Fatalf("unknown providers = %d, want 1", body.UnknownLocationProviders)
	}
	if body.SuppressedCityLocationProviders != 1 {
		t.Fatalf("suppressed city providers = %d, want 1", body.SuppressedCityLocationProviders)
	}
	if len(body.ProviderLocations) != 1 {
		t.Fatalf("city buckets = %d, want 1: %#v", len(body.ProviderLocations), body.ProviderLocations)
	}
	sf := body.ProviderLocations[0]
	if sf.City != "San Francisco" || sf.Providers != 2 || sf.HardwareAttested != 1 {
		t.Fatalf("unexpected city bucket: %#v", sf)
	}
	if len(body.ProviderRegions) != 2 {
		t.Fatalf("region buckets = %d, want 2: %#v", len(body.ProviderRegions), body.ProviderRegions)
	}
	if strings.Contains(strings.ToLower(rr.Body.String()), "203.0.113") {
		t.Fatal("stats response leaked an IP-shaped test fixture")
	}
}

func TestStatsAggregatesRequestLocationsWithPrivacyFloor(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := registry.New(logger)
	st := store.NewMemory("")
	srv := NewServer(reg, st, logger)

	sf := &store.ProviderLocation{
		City:        "San Francisco",
		Region:      "California",
		RegionCode:  "CA",
		Country:     "United States",
		CountryCode: "US",
		Latitude:    37.7749,
		Longitude:   -122.4194,
		UpdatedAt:   time.Now().UTC(),
	}
	nyc := &store.ProviderLocation{
		City:        "New York",
		Region:      "New York",
		RegionCode:  "NY",
		Country:     "United States",
		CountryCode: "US",
		Latitude:    40.7128,
		Longitude:   -74.0060,
		UpdatedAt:   time.Now().UTC(),
	}
	for i := 0; i < minRequestsPerCityBucket; i++ {
		providerID := "provider-a"
		if i%2 == 1 {
			providerID = "provider-b"
		}
		st.RecordUsageWithCostAndLocation(providerID, "consumer", "model", "sf", 10, 20, 0, sf)
	}
	for i := 0; i < minRequestsPerCityBucket-1; i++ {
		st.RecordUsageWithCostAndLocation("provider-c", "consumer", "model", "nyc", 5, 10, 0, nyc)
	}
	st.RecordUsageWithCostAndLocation("provider-d", "consumer", "model", "unknown", 1, 2, 0, nil)

	rr := httptest.NewRecorder()
	srv.handleStats(rr, httptest.NewRequest(http.MethodGet, "/v1/stats", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rr.Code, rr.Body.String())
	}

	var body struct {
		RequestLocations                  []publicRequestLocationBucket `json:"request_locations"`
		RequestRegions                    []publicRequestLocationBucket `json:"request_regions"`
		UnknownRequestLocationRequests    int64                         `json:"unknown_request_location_requests"`
		SuppressedRequestCityRequests     int64                         `json:"suppressed_request_city_requests"`
		RequestLocationPrivacyMinRequests int                           `json:"request_location_privacy_min_requests"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}

	if body.RequestLocationPrivacyMinRequests != minRequestsPerCityBucket {
		t.Fatalf("request privacy floor = %d", body.RequestLocationPrivacyMinRequests)
	}
	if body.UnknownRequestLocationRequests != 1 {
		t.Fatalf("unknown request locations = %d, want 1", body.UnknownRequestLocationRequests)
	}
	if body.SuppressedRequestCityRequests != int64(minRequestsPerCityBucket-1) {
		t.Fatalf("suppressed city requests = %d, want %d", body.SuppressedRequestCityRequests, minRequestsPerCityBucket-1)
	}
	if len(body.RequestLocations) != 1 {
		t.Fatalf("request city buckets = %d, want 1: %#v", len(body.RequestLocations), body.RequestLocations)
	}
	if got := body.RequestLocations[0]; got.City != "San Francisco" || got.Requests != int64(minRequestsPerCityBucket) || got.Providers != 2 {
		t.Fatalf("unexpected request city bucket: %#v", got)
	}
	if len(body.RequestRegions) != 2 {
		t.Fatalf("request region buckets = %d, want 2: %#v", len(body.RequestRegions), body.RequestRegions)
	}
}

func TestStatsAggregatesRequestFlowsToProviderLocations(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := registry.New(logger)
	st := store.NewMemory("")
	srv := NewServer(reg, st, logger)

	providerLoc := &store.ProviderLocation{
		City:        "San Francisco",
		Region:      "California",
		RegionCode:  "CA",
		Country:     "United States",
		CountryCode: "US",
		Latitude:    37.7749,
		Longitude:   -122.4194,
		UpdatedAt:   time.Now().UTC(),
	}
	consumerLoc := &store.ProviderLocation{
		City:        "New York",
		Region:      "New York",
		RegionCode:  "NY",
		Country:     "United States",
		CountryCode: "US",
		Latitude:    40.7128,
		Longitude:   -74.0060,
		UpdatedAt:   time.Now().UTC(),
	}
	addProviderForStats(t, reg, "provider-sf", "hardware", providerLoc)
	for i := 0; i < 5; i++ {
		st.RecordUsageWithCostAndLocation("provider-sf", "consumer", "model", "flow", 10, 20, 0, consumerLoc)
	}

	rr := httptest.NewRecorder()
	srv.handleStats(rr, httptest.NewRequest(http.MethodGet, "/v1/stats", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rr.Code, rr.Body.String())
	}

	var body struct {
		RequestFlows []publicRequestFlowBucket `json:"request_flows"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if len(body.RequestFlows) != 1 {
		t.Fatalf("request flows = %d, want 1: %#v", len(body.RequestFlows), body.RequestFlows)
	}
	flow := body.RequestFlows[0]
	if flow.Requests != 5 || flow.From.Kind != "consumer" || flow.To.Kind != "provider" {
		t.Fatalf("unexpected flow: %#v", flow)
	}
	if flow.From.City != "New York" || flow.To.City != "San Francisco" {
		t.Fatalf("unexpected flow endpoints: %#v", flow)
	}
}

func addProviderForStats(
	t *testing.T,
	reg *registry.Registry,
	id string,
	trust string,
	loc *store.ProviderLocation,
) {
	t.Helper()
	p := reg.Register(id, nil, &protocol.RegisterMessage{
		Hardware: protocol.Hardware{
			MachineModel:       "Mac15,14",
			ChipName:           "Apple M3 Ultra",
			ChipFamily:         "M3",
			ChipTier:           "Ultra",
			MemoryGB:           96,
			CPUCores:           protocol.CPUCores{Total: 28, Performance: 20, Efficiency: 8},
			GPUCores:           60,
			MemoryBandwidthGBs: 819,
		},
		Models: []protocol.ModelInfo{{ID: "mlx-community/gemma-4-26b-a4b-it-8bit"}},
	})
	p.Mu().Lock()
	p.TrustLevel = registry.TrustLevel(trust)
	if trust == string(registry.TrustHardware) {
		p.Attested = true
	}
	if loc != nil {
		cp := *loc
		p.Location = &cp
	}
	p.Mu().Unlock()
}
