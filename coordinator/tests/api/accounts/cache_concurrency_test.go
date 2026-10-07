package accounts_test

import (
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/api/accounts"
	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type blockingDashboardStore struct {
	store.Store
	entered chan string
	release chan struct{}
	calls   atomic.Int64
}

func TestSummaryConcurrentExpiredMissesCoalescePerAccount(t *testing.T) {
	_, base := newMeTestServer(t)
	st := &blockingDashboardStore{Store: base, entered: make(chan string, 64), release: make(chan struct{})}
	cache := readcache.New()
	logger := slog.New(slog.DiscardHandler)
	srv := production.New(production.Dependencies{Store: st, Registry: registry.New(logger), Logger: logger, ReadCache: cache, LatestReleasedVersion: func() string { return "0.9.4" }})
	cache.Set("me:summary:windows:a", []byte(`{}`), -time.Second)
	read := func(account string) error {
		w := httptest.NewRecorder()
		srv.HandleMySummary(w, reqWithUser(http.MethodGet, "/v1/me/summary", "", account))
		if w.Code != http.StatusOK {
			return fmt.Errorf("summary status = %d: %s", w.Code, w.Body.String())
		}
		return nil
	}
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
			errs <- read("a")
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
	go func() { defer close(otherDone); errs <- read("b") }()
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
