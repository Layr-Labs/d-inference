package readiness

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// (d) The in-flight counter increments/decrements back to 0, and SetDraining is
// deterministic. Exercises the owning Controller methods directly.
func TestInflight_AndSetDrainingAreDeterministic(t *testing.T) {
	srv := New(Dependencies{TrustSafetyStatus: func() (bool, string) { return false, "" }})

	if n := srv.Inflight(); n != 0 {
		t.Fatalf("initial Inflight() = %d, want 0", n)
	}
	if n := srv.incInflight(); n != 1 {
		t.Fatalf("after inc Inflight() = %d, want 1", n)
	}
	if n := srv.Inflight(); n != 1 {
		t.Fatalf("Inflight() = %d, want 1", n)
	}
	if n := srv.decInflight(); n != 0 {
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

	// A request through the actual gate leaves the count at 0 after a downstream
	// rejection. API tests separately exercise the real authentication middleware.
	srv.Gate(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	})(httptest.NewRecorder(), httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil))
	if n := srv.Inflight(); n != 0 {
		t.Fatalf("Inflight() = %d after a completed request, want 0", n)
	}
}

// (e) DrainGraceFromEnv parses EIGENINFERENCE_DRAIN_GRACE, falling back to the
// default for unset/empty/invalid/negative values and honoring an explicit "0"
// (no wait — Shutdown is called immediately).
func TestDrainGraceFromEnv(t *testing.T) {
	cases := []struct {
		name string
		val  string
		want time.Duration
	}{
		{"unset", "", DefaultDrainGrace},
		{"valid_seconds", "90s", 90 * time.Second},
		{"valid_minutes", "2m", 2 * time.Minute},
		{"zero_disables_wait", "0", 0},
		{"invalid_falls_back", "not-a-duration", DefaultDrainGrace},
		{"negative_falls_back", "-5s", DefaultDrainGrace},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("EIGENINFERENCE_DRAIN_GRACE", tc.val)
			if got := DrainGraceFromEnv(); got != tc.want {
				t.Fatalf("DrainGraceFromEnv() = %v, want %v", got, tc.want)
			}
		})
	}
}

// (e) WaitForInflightZero returns immediately when nothing is in flight, times
// out (false) while a request is still in flight, and returns true once the count
// drops to 0 before the deadline.
func TestWaitForInflightZero(t *testing.T) {
	srv := New(Dependencies{TrustSafetyStatus: func() (bool, string) { return false, "" }})

	// Already zero → true immediately.
	if !srv.WaitForInflightZero(context.Background()) {
		t.Fatal("WaitForInflightZero() = false with inflight 0, want true")
	}

	// One in flight, short deadline → times out false.
	srv.incInflight()
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if srv.WaitForInflightZero(ctx) {
		t.Fatal("WaitForInflightZero() = true while a request is in flight, want false")
	}

	// Drop to 0 from another goroutine → returns true before the deadline.
	go func() {
		time.Sleep(20 * time.Millisecond)
		srv.decInflight()
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
