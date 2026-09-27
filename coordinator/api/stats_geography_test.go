package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func readStatsGeography(t *testing.T, srv *Server) statsGeography {
	t.Helper()
	if _, ok := srv.refreshStats(); !ok {
		t.Fatal("core stats failed because of geography")
	}
	rr := httptest.NewRecorder()
	srv.handleStats(rr, httptest.NewRequest(http.MethodGet, "/v1/stats", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("stats status = %d: %s", rr.Code, rr.Body.String())
	}
	var result statsGeography
	if err := json.Unmarshal(rr.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	return result
}

func TestStatsGeographyFailuresAreIndependentAndRecover(t *testing.T) {
	for _, name := range []string{"both", "locations", "flows"} {
		t.Run(name, func(t *testing.T) {
			srv, _, st := newStatsRefresherFixture(t)
			good := readStatsGeography(t, srv)
			if good.LocationsStatus != statsGeographyAvailable || good.FlowsStatus != statsGeographyAvailable || len(good.Locations) == 0 || len(good.Flows) == 0 {
				t.Fatal("fixture must contain complete geography")
			}
			var flag *atomic.Bool
			switch name {
			case "both":
				flag = &st.fail
			case "locations":
				flag = &st.usageCountFail
			case "flows":
				flag = &st.flowFail
			}
			flag.Store(true)
			srv.refreshStatsGeography()
			partial := readStatsGeography(t, srv)
			if name != "flows" {
				if partial.LocationsStatus != statsGeographyUnavailable || partial.Locations != nil || partial.Regions != nil || partial.UnknownRequests != nil || partial.SuppressedCities != nil {
					t.Fatalf("failed locations exposed stale or zero figures: %+v", partial)
				}
			} else if partial.LocationsStatus != statsGeographyAvailable || len(partial.Locations) == 0 {
				t.Fatal("flow failure hid valid request locations")
			}
			if name != "locations" {
				if partial.FlowsStatus != statsGeographyUnavailable || partial.Flows != nil {
					t.Fatalf("failed flows exposed stale or empty figures: %+v", partial)
				}
			} else if partial.FlowsStatus != statsGeographyAvailable || len(partial.Flows) == 0 {
				t.Fatal("location failure hid valid request flows")
			}
			flag.Store(false)
			srv.refreshStatsGeography()
			recovered := readStatsGeography(t, srv)
			if recovered.LocationsStatus != statsGeographyAvailable || recovered.FlowsStatus != statsGeographyAvailable || len(recovered.Locations) == 0 || len(recovered.Flows) == 0 {
				t.Fatal("geography did not recover")
			}
		})
	}
}

func TestStatsGeographyEmptyAndExpiredAreDifferent(t *testing.T) {
	srv := newStatsSnapshotServer(store.NewMemory(store.Config{}))
	cold := readStatsGeography(t, srv)
	if cold.LocationsStatus != statsGeographyUnavailable || cold.FlowsStatus != statsGeographyUnavailable || cold.UnknownRequests != nil {
		t.Fatal("cold geography must be unavailable")
	}
	srv.refreshStatsGeography()
	empty := readStatsGeography(t, srv)
	if empty.LocationsStatus != statsGeographyAvailable || empty.FlowsStatus != statsGeographyAvailable || empty.Locations == nil || empty.Flows == nil || empty.UnknownRequests == nil || *empty.UnknownRequests != 0 {
		t.Fatalf("valid empty geography must remain distinguishable: %+v", empty)
	}
	if _, err := time.Parse(time.RFC3339Nano, empty.UpdatedAt); err != nil {
		t.Fatalf("geography needs its own source timestamp: %v", err)
	}
	srv.readCache.Set(statsGeographyCacheKey, []byte(`{}`), -time.Second)
	expired := readStatsGeography(t, srv)
	if expired.LocationsStatus != statsGeographyUnavailable || expired.Locations != nil || expired.UnknownRequests != nil {
		t.Fatal("expired geography must not become fresh empty data")
	}
}

type blockedGeographyStore struct {
	store.Store
	started chan struct{}
	release chan struct{}
}

func (s *blockedGeographyStore) UsageLocationBuckets(since time.Time) ([]store.UsageLocationBucket, error) {
	close(s.started)
	<-s.release
	return s.Store.UsageLocationBuckets(since)
}

func TestStatsCoreLoadsWhileGeographyRefreshIsBlocked(t *testing.T) {
	st := &blockedGeographyStore{Store: store.NewMemory(store.Config{}), started: make(chan struct{}), release: make(chan struct{})}
	srv := newStatsSnapshotServer(st)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		srv.runCacheRefreshLoop(ctx, time.Hour, func() { srv.refreshStatsGeography() })
	}()
	defer func() {
		cancel()
		close(st.release)
		<-done
	}()
	<-st.started
	response := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		rr := httptest.NewRecorder()
		srv.handleStats(rr, httptest.NewRequest(http.MethodGet, "/v1/stats", nil))
		response <- rr
	}()
	select {
	case rr := <-response:
		if rr.Code != http.StatusOK {
			t.Fatalf("core stats unavailable during blocked geography: %d", rr.Code)
		}
	case <-time.After(time.Second):
		t.Fatal("core stats waited for geography")
	}
}
