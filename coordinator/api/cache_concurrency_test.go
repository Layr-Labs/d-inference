package api

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

type blockingDashboardStore struct {
	store.Store
	entered chan string
	release chan struct{}
	calls   atomic.Int64
}

func (s *blockingDashboardStore) AccountEarningsWindows(account string, now time.Time) (store.AccountEarningsWindows, error) {
	s.calls.Add(1)
	s.entered <- account
	<-s.release
	return s.Store.AccountEarningsWindows(account, now)
}

func TestSummaryConcurrentExpiredMissesCoalescePerAccount(t *testing.T) {
	srv, base := newMeTestServer(t)
	st := &blockingDashboardStore{Store: base, entered: make(chan string, 64), release: make(chan struct{})}
	srv.store = st
	srv.readCache.Set("me:summary:windows:a", []byte(`{}`), -time.Second)
	const callers = 30
	var ready, done sync.WaitGroup
	ready.Add(callers)
	done.Add(callers)
	start := make(chan struct{})
	errs := make(chan error, callers+1)
	for range callers {
		go func() {
			defer done.Done()
			ready.Done()
			<-start
			_, err := srv.accountEarningsWindows("a")
			errs <- err
		}()
	}
	ready.Wait()
	close(start)
	select {
	case <-st.entered:
	case <-time.After(time.Second):
		t.Fatal("first query never started")
	}
	// Other accounts must not wait behind the first account's query.
	otherDone := make(chan struct{})
	go func() { defer close(otherDone); _, err := srv.accountEarningsWindows("b"); errs <- err }()
	select {
	case account := <-st.entered:
		if account != "b" {
			close(st.release)
			done.Wait()
			<-otherDone
			t.Fatalf("duplicate account query before release: %q", account)
		}
	case <-time.After(time.Second):
		close(st.release)
		done.Wait()
		<-otherDone
		t.Fatal("different account blocked")
	}
	close(st.release)
	done.Wait()
	<-otherDone
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	if got := st.calls.Load(); got != 2 {
		t.Fatalf("aggregate calls = %d, want one per account", got)
	}
}

type serialTotalsStore struct {
	store.Store
	active  atomic.Int64
	peak    atomic.Int64
	calls   atomic.Int64
	entered chan struct{}
	release chan struct{}
	fail    atomic.Bool
}

func (s *serialTotalsStore) NetworkTotals(since time.Time) (store.NetworkTotalsRow, error) {
	active := s.active.Add(1)
	defer s.active.Add(-1)
	for peak := s.peak.Load(); active > peak; peak = s.peak.Load() {
		if s.peak.CompareAndSwap(peak, active) {
			break
		}
	}
	s.calls.Add(1)
	s.entered <- struct{}{}
	<-s.release
	if s.fail.Load() {
		return store.NetworkTotalsRow{}, errors.New("totals unavailable")
	}
	return s.Store.NetworkTotals(since)
}

// TestTotalsColdRequestsDoNotQueueBehindBackgroundRefresh: while the refresher
// holds the shared totals query, a cache miss answers 503 promptly instead of
// waiting on the in-flight compute or the query lock, and never starts a second
// aggregate. Once the refresher has filled the cache the same requests are 200.
func TestTotalsColdRequestsDoNotQueueBehindBackgroundRefresh(t *testing.T) {
	prev := coldFillWait
	coldFillWait = 200 * time.Millisecond
	t.Cleanup(func() { coldFillWait = prev })

	srv, _, base := newStatsRefresherFixture(t)
	st := &serialTotalsStore{Store: base, entered: make(chan struct{}, 16), release: make(chan struct{})}
	srv.store = st
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	backgroundDone := make(chan struct{})
	go func() { defer close(backgroundDone); srv.runNetworkTotalsRefresher(ctx, time.Hour) }()
	select {
	case <-st.entered:
	case <-time.After(time.Second):
		t.Fatal("background query never started")
	}

	// The first window's flight is in progress and the query bound is held for
	// every other window; neither may hold a request for the store timeout.
	if _, err := srv.computeNetworkTotals("all", false); !errors.Is(err, errComputeBusy) {
		t.Fatalf("request-path compute while the refresher holds the query: err=%v, want errComputeBusy", err)
	}
	started := time.Now()
	var wg sync.WaitGroup
	responses := make(chan int, len(networkTotalsWindows))
	for _, window := range networkTotalsWindows {
		wg.Add(1)
		go func() {
			defer wg.Done()
			rr := httptest.NewRecorder()
			srv.handleNetworkTotals(rr, httptest.NewRequest(http.MethodGet, "/v1/network/totals?window="+window, nil))
			responses <- rr.Code
		}()
	}
	wg.Wait()
	if elapsed := time.Since(started); elapsed > coldFillWait+time.Second {
		t.Fatalf("cold requests took %v while the refresher held the query; want prompt 503s", elapsed)
	}
	close(responses)
	for code := range responses {
		if code != http.StatusServiceUnavailable {
			t.Fatalf("cold totals status while a refresh is in flight = %d, want 503", code)
		}
	}
	if got := st.calls.Load(); got != 1 {
		t.Fatalf("store calls = %d, want 1: requests must not start their own aggregate", got)
	}

	// Let the refresher finish every window; requests then hit the cache.
	close(st.release)
	deadline := time.After(5 * time.Second)
	for st.calls.Load() < int64(len(networkTotalsWindows)) {
		select {
		case <-deadline:
			t.Fatalf("refresher completed %d/%d windows", st.calls.Load(), len(networkTotalsWindows))
		case <-time.After(10 * time.Millisecond):
		}
	}
	for _, window := range networkTotalsWindows {
		code := 0
		for attempt := 0; attempt < 100 && code != http.StatusOK; attempt++ {
			rr := httptest.NewRecorder()
			srv.handleNetworkTotals(rr, httptest.NewRequest(http.MethodGet, "/v1/network/totals?window="+window, nil))
			if code = rr.Code; code != http.StatusOK {
				time.Sleep(10 * time.Millisecond)
			}
		}
		if code != http.StatusOK {
			t.Fatalf("totals status for %s after the refresh = %d", window, code)
		}
	}
	if peak := st.peak.Load(); peak != 1 {
		t.Fatalf("peak totals concurrency = %d", peak)
	}
	cancel()
	<-backgroundDone

	// Errors must release the shared query bound so a later healthy window can run.
	st.fail.Store(true)
	if _, err := srv.computeNetworkTotals("all", true); err == nil {
		t.Fatal("expected store error")
	}
	st.fail.Store(false)
	if _, err := srv.computeNetworkTotals("all", true); err != nil {
		t.Fatal(err)
	}
}

// TestGetCachedEntryBoundsWaitOnInflightCompute: a request that finds a compute
// in flight waits at most coldFillWait, while the background refresher still
// waits for the flight to finish.
func TestGetCachedEntryBoundsWaitOnInflightCompute(t *testing.T) {
	prev := coldFillWait
	coldFillWait = 50 * time.Millisecond
	t.Cleanup(func() { coldFillWait = prev })

	srv, _ := testServer(t)
	entry := &cacheRefresher{inflight: make(chan struct{})}
	started := time.Now()
	if body, ok := srv.getCachedEntry(entry, "k", func() ([]byte, error) { t.Fatal("request must not start a second compute"); return nil, nil }); ok || body != nil {
		t.Fatalf("got cached %q while a flight is in progress and nothing is cached", body)
	}
	if elapsed := time.Since(started); elapsed < coldFillWait || elapsed > coldFillWait+time.Second {
		t.Fatalf("request waited %v, want about %v", elapsed, coldFillWait)
	}

	refreshReturned := make(chan struct{})
	go func() {
		defer close(refreshReturned)
		srv.refreshCachedEntry(entry, "k", func() ([]byte, error) { t.Error("refresh must join the flight, not start another"); return nil, nil })
	}()
	select {
	case <-refreshReturned:
		t.Fatal("refresh returned while the flight was still open")
	case <-time.After(3 * coldFillWait):
	}
	srv.readCache.Set("k", []byte(`{"filled":true}`), time.Minute)
	close(entry.inflight)
	select {
	case <-refreshReturned:
	case <-time.After(time.Second):
		t.Fatal("refresh did not return after the flight closed")
	}
}
