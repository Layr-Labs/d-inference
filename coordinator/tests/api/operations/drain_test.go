package operations_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/api/operations"
)

func TestDrainGraceFromEnv(t *testing.T) {
	cases := []struct {
		name string
		val  string
		want time.Duration
	}{
		{"unset", "", production.DefaultDrainGrace},
		{"valid_seconds", "90s", 90 * time.Second},
		{"valid_minutes", "2m", 2 * time.Minute},
		{"zero_disables_wait", "0", 0},
		{"invalid_falls_back", "not-a-duration", production.DefaultDrainGrace},
		{"negative_falls_back", "-5s", production.DefaultDrainGrace},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("EIGENINFERENCE_DRAIN_GRACE", tc.val)
			if got := production.DrainGraceFromEnv(); got != tc.want {
				t.Fatalf("DrainGraceFromEnv() = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestWaitForInflightZero(t *testing.T) {
	srv := &production.Drain{}

	// Already zero → true immediately.
	if !srv.WaitForInflightZero(context.Background()) {
		t.Fatal("WaitForInflightZero() = false with inflight 0, want true")
	}

	// One in flight, short deadline → times out false.
	finish := startInflight(t, srv)
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if srv.WaitForInflightZero(ctx) {
		t.Fatal("WaitForInflightZero() = true while a request is in flight, want false")
	}

	// Drop to 0 from another goroutine → returns true before the deadline.
	go func() {
		time.Sleep(20 * time.Millisecond)
		finish()
	}()
	ctx2, cancel2 := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel2()
	if !srv.WaitForInflightZero(ctx2) {
		t.Fatal("WaitForInflightZero() = false after inflight dropped to 0, want true")
	}
	if n := srv.Inflight(); n != 0 {
		t.Fatalf("Inflight() = %d at end, want 0", n)
	}
}

func TestInflightAndSetDrainingState(t *testing.T) {
	srv := &production.Drain{}

	if n := srv.Inflight(); n != 0 {
		t.Fatalf("initial Inflight() = %d, want 0", n)
	}
	finish := startInflight(t, srv)
	if n := srv.Inflight(); n != 1 {
		t.Fatalf("after inc Inflight() = %d, want 1", n)
	}
	if n := srv.Inflight(); n != 1 {
		t.Fatalf("Inflight() = %d, want 1", n)
	}
	finish()
	if n := srv.Inflight(); n != 0 {
		t.Fatalf("after dec Inflight() = %d, want 0", n)
	}

	if srv.IsDraining() {
		t.Fatal("IsDraining() = true by default, want false")
	}
	srv.SetDraining(true)
	if !srv.IsDraining() {
		t.Fatal("IsDraining() = false after SetDraining(true)")
	}
	srv.SetDraining(false)
	if srv.IsDraining() {
		t.Fatal("IsDraining() = true after SetDraining(false)")
	}

}

// Keep a real ingress handler running until finish is called.
func startInflight(t *testing.T, drain *production.Drain) func() {
	t.Helper()
	started, release, done := make(chan struct{}), make(chan struct{}), make(chan struct{})
	srv := production.New(production.Dependencies{Drain: drain, TrustSafety: func() (bool, string) { return false, "" }})
	go func() {
		defer close(done)
		srv.DrainGate(func(http.ResponseWriter, *http.Request) {
			close(started)
			<-release
		})(httptest.NewRecorder(), httptest.NewRequest(http.MethodPost, "/", nil))
	}()
	<-started
	return func() { close(release); <-done }
}
