package network

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
	srv.store = func() Store { return st }
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
			srv.Totals(rr, httptest.NewRequest(http.MethodGet, "/v1/network/totals?window="+window, nil))
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
