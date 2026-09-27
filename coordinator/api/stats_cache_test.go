package api

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type statsDelayedStore struct {
	store.Store
	delay time.Duration
}

func (s statsDelayedStore) UsageTotals() (store.UsageTotals, error) {
	time.Sleep(s.delay)
	return s.Store.UsageTotals()
}

// Keep these fake-clock tests on the actual handler, cache and registry without
// unrelated server workers; StartCacheRefreshers is started explicitly below.
func newStatsSnapshotServer(st store.Store) *Server {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	return &Server{
		registry:  registry.New(logger),
		store:     st,
		logger:    logger,
		readCache: newTTLCache(),
	}
}

func readStatsSnapshot(t *testing.T, srv *Server) ([]byte, time.Time, int64) {
	t.Helper()
	rr := httptest.NewRecorder()
	srv.handleStats(rr, httptest.NewRequest(http.MethodGet, "/v1/stats", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rr.Code, rr.Body.String())
	}
	var body struct {
		SnapshotAt string `json:"snapshot_at"`
		Requests   int64  `json:"total_requests"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	capturedAt, err := time.Parse(time.RFC3339Nano, body.SnapshotAt)
	if err != nil {
		t.Fatalf("invalid snapshot_at %q: %v", body.SnapshotAt, err)
	}
	return rr.Body.Bytes(), capturedAt, body.Requests
}

func TestStatsCachePreservesSourceTimeUntilSuccessfulRefresh(t *testing.T) {
	for _, delay := range []time.Duration{0, 7 * time.Second} {
		t.Run(delay.String(), func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				memory := store.NewMemory(store.Config{})
				srv := newStatsSnapshotServer(statsDelayedStore{Store: memory, delay: delay})
				startedAt := time.Now()
				initialBody, capturedAt, _ := readStatsSnapshot(t, srv)
				if !capturedAt.Equal(startedAt) {
					t.Fatalf("snapshot_at = %v, want observation start %v", capturedAt, startedAt)
				}
				memory.RecordUsageWithCostAndLocation("provider", "consumer", "model", "request", 10, 20, 0, nil)
				time.Sleep(startedAt.Add(30*time.Second - time.Nanosecond).Sub(time.Now()))
				cachedBody, _, _ := readStatsSnapshot(t, srv)
				if !bytes.Equal(cachedBody, initialBody) {
					t.Fatal("cache hit changed the body or source timestamp")
				}

				// Handlers remain reads after the freshness interval. The periodic
				// owner replaces successful bytes; the safety TTL permits failures.
				time.Sleep(2 * time.Nanosecond)
				cachedBody, _, _ = readStatsSnapshot(t, srv)
				if !bytes.Equal(cachedBody, initialBody) {
					t.Fatal("handler recomputed warm stats instead of preserving owner state")
				}
				refreshStartedAt := time.Now()
				if _, ok := srv.refreshStats(); !ok {
					t.Fatal("refresh failed")
				}
				_, refreshedAt, requests := readStatsSnapshot(t, srv)
				if !refreshedAt.Equal(refreshStartedAt) || requests != 1 {
					t.Fatalf("refreshed snapshot: captured_at=%v want=%v requests=%d", refreshedAt, refreshStartedAt, requests)
				}
			})
		})
	}
}

func TestStatsRefreshCadenceLeavesNetworkTotalsAtOneMinute(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		memory := store.NewMemory(store.Config{})
		st := &countingStatsStore{Store: memory}
		srv := newStatsSnapshotServer(st)
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		startedAt := time.Now()
		srv.StartCacheRefreshers(ctx)
		synctest.Wait()
		initialBody, capturedAt, _ := readStatsSnapshot(t, srv)
		if !capturedAt.Equal(startedAt) || st.locationCalls.Load() != 1 || st.totalsCalls.Load() != 4 {
			t.Fatal("refreshers did not prime stats and all four totals windows")
		}
		memory.RecordUsageWithCostAndLocation("provider", "consumer", "model", "request", 10, 20, 0, nil)

		time.Sleep(30*time.Second - time.Nanosecond)
		synctest.Wait()
		beforeTick, _, _ := readStatsSnapshot(t, srv)
		if !bytes.Equal(beforeTick, initialBody) || st.locationCalls.Load() != 1 {
			t.Fatal("stats refreshed before 30 seconds")
		}
		time.Sleep(time.Nanosecond)
		synctest.Wait()
		_, refreshedAt, requests := readStatsSnapshot(t, srv)
		if !refreshedAt.Equal(startedAt.Add(30*time.Second)) || requests != 1 || st.locationCalls.Load() != 2 || st.totalsCalls.Load() != 4 {
			t.Fatalf("30s cadence: captured_at=%v requests=%d stats_queries=%d totals_queries=%d", refreshedAt, requests, st.locationCalls.Load(), st.totalsCalls.Load())
		}
		time.Sleep(30 * time.Second)
		synctest.Wait()
		_, refreshedAt, _ = readStatsSnapshot(t, srv)
		if !refreshedAt.Equal(startedAt.Add(time.Minute)) || st.locationCalls.Load() != 3 || st.totalsCalls.Load() != 8 {
			t.Fatalf("60s cadence: captured_at=%v stats_queries=%d totals_queries=%d", refreshedAt, st.locationCalls.Load(), st.totalsCalls.Load())
		}
		cancel()
		synctest.Wait()
	})
}

func TestStatsFailedRefreshPreservesTimestampAndSafetyExpiry(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		st := &countingStatsStore{Store: store.NewMemory(store.Config{})}
		srv := newStatsSnapshotServer(st)
		startedAt := time.Now()
		initialBody, capturedAt, _ := readStatsSnapshot(t, srv)
		st.usageTotalsFail.Store(true)
		time.Sleep(45 * time.Second)
		stale, ok := srv.refreshStats()
		if !ok || !bytes.Equal(stale, initialBody) {
			t.Fatal("failed refresh did not retain the last complete source snapshot")
		}
		served, staleAt, _ := readStatsSnapshot(t, srv)
		if !bytes.Equal(served, initialBody) || !staleAt.Equal(capturedAt) {
			t.Fatal("warm response relabelled an old snapshot as freshly observed")
		}

		// A failed attempt must not reset the upstream's existing safety TTL.
		time.Sleep(startedAt.Add(5*time.Minute - time.Nanosecond).Sub(time.Now()))
		served, _, _ = readStatsSnapshot(t, srv)
		if !bytes.Equal(served, initialBody) {
			t.Fatal("unexpired success disappeared during the outage")
		}
		time.Sleep(2 * time.Nanosecond)
		rr := httptest.NewRecorder()
		srv.handleStats(rr, httptest.NewRequest(http.MethodGet, "/v1/stats", nil))
		if rr.Code != http.StatusServiceUnavailable {
			t.Fatalf("expired source with failed refresh: status=%d, body=%s", rr.Code, rr.Body.String())
		}
		st.usageTotalsFail.Store(false)
		recoveryAt := time.Now()
		_, recoveredAt, _ := readStatsSnapshot(t, srv)
		if !recoveredAt.Equal(recoveryAt) {
			t.Fatalf("recovery snapshot_at=%v, want %v", recoveredAt, recoveryAt)
		}
	})
}
