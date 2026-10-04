package reporting_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	statsview "github.com/eigeninference/d-inference/coordinator/internal/api/reporting/statsview"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func readStatsGeography(t *testing.T, srv *reportingFixture) statsview.Geography {
	t.Helper()
	if _, ok := srv.RefreshStats(); !ok {
		t.Fatal("core stats failed because of geography")
	}
	rr := httptest.NewRecorder()
	srv.HandleStats(rr, httptest.NewRequest(http.MethodGet, "/v1/stats", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("stats status = %d: %s", rr.Code, rr.Body.String())
	}
	var result statsview.Geography
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
			if good.LocationsStatus != statsview.GeographyAvailable || good.FlowsStatus != statsview.GeographyAvailable || len(good.Locations) == 0 || len(good.Flows) == 0 {
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
			srv.RefreshStatsGeography()
			partial := readStatsGeography(t, srv)
			if name != "flows" {
				if partial.LocationsStatus != statsview.GeographyUnavailable || partial.Locations != nil || partial.Regions != nil || partial.UnknownRequests != nil || partial.SuppressedCities != nil {
					t.Fatalf("failed locations exposed stale or zero figures: %+v", partial)
				}
			} else if partial.LocationsStatus != statsview.GeographyAvailable || len(partial.Locations) == 0 {
				t.Fatal("flow failure hid valid request locations")
			}
			if name != "locations" {
				if partial.FlowsStatus != statsview.GeographyUnavailable || partial.Flows != nil {
					t.Fatalf("failed flows exposed stale or empty figures: %+v", partial)
				}
			} else if partial.FlowsStatus != statsview.GeographyAvailable || len(partial.Flows) == 0 {
				t.Fatal("location failure hid valid request flows")
			}
			flag.Store(false)
			srv.RefreshStatsGeography()
			recovered := readStatsGeography(t, srv)
			if recovered.LocationsStatus != statsview.GeographyAvailable || recovered.FlowsStatus != statsview.GeographyAvailable || len(recovered.Locations) == 0 || len(recovered.Flows) == 0 {
				t.Fatal("geography did not recover")
			}
		})
	}
}

func TestStatsGeographyEmptyAndExpiredAreDifferent(t *testing.T) {
	srv := newStatsSnapshotServer(memory.NewMemory(store.Config{}))
	cold := readStatsGeography(t, srv)
	if cold.LocationsStatus != statsview.GeographyUnavailable || cold.FlowsStatus != statsview.GeographyUnavailable || cold.UnknownRequests != nil {
		t.Fatal("cold geography must be unavailable")
	}
	srv.RefreshStatsGeography()
	empty := readStatsGeography(t, srv)
	if empty.LocationsStatus != statsview.GeographyAvailable || empty.FlowsStatus != statsview.GeographyAvailable || empty.Locations == nil || empty.Flows == nil || empty.UnknownRequests == nil || *empty.UnknownRequests != 0 {
		t.Fatalf("valid empty geography must remain distinguishable: %+v", empty)
	}
	if _, err := time.Parse(time.RFC3339Nano, empty.UpdatedAt); err != nil {
		t.Fatalf("geography needs its own source timestamp: %v", err)
	}
	srv.readCache.Set(statsview.GeographyCacheKey, []byte(`{}`), -time.Second)
	expired := readStatsGeography(t, srv)
	if expired.LocationsStatus != statsview.GeographyUnavailable || expired.Locations != nil || expired.UnknownRequests != nil {
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
	st := &blockedGeographyStore{Store: memory.NewMemory(store.Config{}), started: make(chan struct{}), release: make(chan struct{})}
	srv := newStatsSnapshotServer(st)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		srv.RunCacheRefreshLoop(ctx, time.Hour, func() { srv.RefreshStatsGeography() })
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
		srv.HandleStats(rr, httptest.NewRequest(http.MethodGet, "/v1/stats", nil))
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
