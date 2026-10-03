package operations

import (
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// Every request reaching next must already count as in-flight, even while the
// drain state changes concurrently. No request may leak its count on exit.
func TestDrainGate_ConcurrentNoInflightLeak(t *testing.T) {
	srv := &Handler{
		Drain:             &Drain{},
		trustSafetyStatus: func() (bool, string) { return false, "" },
		writeTokenRateLimited: func(w http.ResponseWriter, _, _ string, _ time.Duration) {
			w.WriteHeader(http.StatusTooManyRequests)
		},
	}
	var ranUncounted atomic.Int64
	gate := srv.DrainGate(func(w http.ResponseWriter, r *http.Request) {
		if srv.Inflight() < 1 {
			ranUncounted.Add(1)
		}
		w.WriteHeader(http.StatusOK)
	})
	const workers = 64
	const iters = 50
	stop := make(chan struct{})
	var flipper sync.WaitGroup
	flipper.Add(1)
	go func() {
		defer flipper.Done()
		for {
			select {
			case <-stop:
				return
			default:
				srv.SetDraining(true)
				srv.SetDraining(false)
			}
		}
	}()
	var work sync.WaitGroup
	for i := 0; i < workers; i++ {
		work.Add(1)
		go func() {
			defer work.Done()
			for j := 0; j < iters; j++ {
				w := httptest.NewRecorder()
				r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
				gate(w, r)
			}
		}()
	}
	work.Wait()
	close(stop)
	flipper.Wait()
	srv.SetDraining(false)
	if n := srv.Inflight(); n != 0 {
		t.Fatalf("Inflight() = %d after all requests, want 0 (counter leak)", n)
	}
	if n := ranUncounted.Load(); n != 0 {
		t.Fatalf("%d requests reached next() while Inflight()<1 (count-before-check violated)", n)
	}
}
