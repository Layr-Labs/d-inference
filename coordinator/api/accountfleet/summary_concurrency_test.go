package accountfleet

import (
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
	srv.store = func() Store { return st }
	srv.readCache().Set("me:summary:windows:a", []byte(`{}`), -time.Second)
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
