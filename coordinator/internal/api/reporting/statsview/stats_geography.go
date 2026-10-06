package statsview

import (
	"encoding/json"
	"time"
)

const GeographyCacheKey = "stats:geography:v1"

type statsGeographyStatus string

const (
	GeographyAvailable   statsGeographyStatus = "available"
	GeographyUnavailable statsGeographyStatus = "unavailable"
)

// A geography refresh publishes the outcome of each input independently.
// Unavailable values are null, never successful empty arrays or zero counts.
// UpdatedAt is the observation start, separate from the core snapshot's time.
type Geography struct {
	UpdatedAt        string                  `json:"geography_snapshot_at"`
	LocationsStatus  statsGeographyStatus    `json:"request_locations_status"`
	FlowsStatus      statsGeographyStatus    `json:"request_flows_status"`
	Locations        []RequestLocationBucket `json:"request_locations"`
	Regions          []RequestLocationBucket `json:"request_regions"`
	UnknownRequests  *int64                  `json:"unknown_request_location_requests"`
	SuppressedCities *int64                  `json:"suppressed_request_city_requests"`
	Flows            []RequestFlowBucket     `json:"request_flows"`
}

func unavailableStatsGeography() Geography {
	return Geography{
		LocationsStatus: GeographyUnavailable,
		FlowsStatus:     GeographyUnavailable,
	}
}

// cachedStatsGeography is read-only and never starts or waits for SQL work.
// If the refresher has not completed yet, or its entry expired, report unknown.
func (s *Stats) cachedStatsGeography() Geography {
	if body, ok := s.readCache.Get(GeographyCacheKey); ok {
		var geography Geography
		if json.Unmarshal(body, &geography) == nil {
			return geography
		}
	}
	return unavailableStatsGeography()
}

func (s *Stats) RefreshStatsGeography() ([]byte, bool) {
	return s.RefreshCachedEntry(&s.statsGeographyRefresh, GeographyCacheKey, s.computeStatsGeography)
}

func (s *Stats) computeStatsGeography() ([]byte, error) {
	observedAt := time.Now()
	since := observedAt.Add(-24 * time.Hour)
	geography := unavailableStatsGeography()
	geography.UpdatedAt = observedAt.UTC().Format(time.RFC3339Nano)

	locations, regions, unknown, suppressed, err := s.aggregateRequestLocations(since)
	if err == nil {
		geography.LocationsStatus = GeographyAvailable
		geography.Locations = locations
		geography.Regions = regions
		geography.UnknownRequests = &unknown
		geography.SuppressedCities = &suppressed
	} else {
		s.recordStatsGeographyFailure("request_locations", err)
	}

	flows, err := s.aggregateRequestFlows(since)
	if err == nil {
		geography.FlowsStatus = GeographyAvailable
		geography.Flows = flows
	} else {
		s.recordStatsGeographyFailure("request_flows", err)
	}
	// Query failures are a valid availability response, not a failed refresh:
	// replace previous geographic figures so clients cannot mistake them for
	// fresh or empty data. Core stats retain their own failure/expiry rules.
	return json.Marshal(geography)
}

func (s *Stats) recordStatsGeographyFailure(section string, err error) {
	s.logger.Warn("stats geography unavailable", "section", section, "error", err)
	s.ddIncr("cache.refresh_failed", []string{"key:" + GeographyCacheKey, "section:" + section})
}

func (g Geography) addTo(response map[string]any) {
	response["geography_snapshot_at"] = g.UpdatedAt
	response["request_locations_status"] = g.LocationsStatus
	response["request_flows_status"] = g.FlowsStatus
	response["request_locations"] = g.Locations
	response["request_regions"] = g.Regions
	response["unknown_request_location_requests"] = g.UnknownRequests
	response["suppressed_request_city_requests"] = g.SuppressedCities
	response["request_flows"] = g.Flows
	response["request_location_privacy_min_requests"] = MinRequestsPerCityBucket
}
