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

func TestTotalsColdWindowsSerializeWithBackgroundRefresh(t *testing.T) {
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
	// Hold the first query while all cold windows contend. A second entry in
	// this interval proves that independent keys escaped the shared bound.
	select {
	case <-st.entered:
		close(st.release)
		wg.Wait()
		cancel()
		<-backgroundDone
		t.Fatal("totals queries overlapped across windows")
	case <-time.After(50 * time.Millisecond):
	}
	close(st.release)
	wg.Wait()
	cancel()
	<-backgroundDone
	close(responses)
	for code := range responses {
		if code != http.StatusOK {
			t.Fatalf("totals status = %d", code)
		}
	}
	if peak := st.peak.Load(); peak != 1 {
		t.Fatalf("peak totals concurrency = %d", peak)
	}
	// Errors must release the shared query lock so a later healthy window can run.
	st.fail.Store(true)
	if _, err := srv.computeNetworkTotals("all"); err == nil {
		t.Fatal("expected store error")
	}
	st.fail.Store(false)
	if _, err := srv.computeNetworkTotals("all"); err != nil {
		t.Fatal(err)
	}
}
