package api

import (
	"io"
	"log/slog"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// waitColdKickIdle blocks until the cold-kick single-flight pass has completed
// (inFlight cleared) or the deadline elapses.
func waitColdKickIdle(t *testing.T, st *coldKickState) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		st.mu.Lock()
		idle := !st.inFlight
		st.mu.Unlock()
		if idle {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("cold kick did not return to idle in time")
}

func TestEnvEnabledDefaultTrue(t *testing.T) {
	cases := []struct {
		val  string
		set  bool
		want bool
	}{
		{set: false, want: true}, // unset → default true
		{val: "", set: true, want: true},
		{val: "true", set: true, want: true},
		{val: "1", set: true, want: true},
		{val: "yes", set: true, want: true},
		{val: "garbage", set: true, want: true}, // malformed → default-safe true
		{val: "false", set: true, want: false},
		{val: "FALSE", set: true, want: false},
		{val: "0", set: true, want: false},
		{val: "no", set: true, want: false},
		{val: "off", set: true, want: false},
		{val: " off ", set: true, want: false}, // trimmed
	}
	const name = "EIGENINFERENCE_W3_FLAG_TEST"
	for _, c := range cases {
		if c.set {
			t.Setenv(name, c.val)
		}
		if got := envEnabledDefaultTrue(name); got != c.want {
			t.Errorf("envEnabledDefaultTrue(%q set=%v) = %v, want %v", c.val, c.set, got, c.want)
		}
	}
}

func TestQueueBeforeShedFlagDefaultsOn(t *testing.T) {
	s := &Server{}
	if !s.queueBeforeShedEnabled() {
		t.Fatal("queueBeforeShedEnabled default = false, want true")
	}
	t.Setenv(envQueueBeforeShed, "false")
	if s.queueBeforeShedEnabled() {
		t.Fatal("queueBeforeShedEnabled with =false = true, want false")
	}
}

func TestEnvEnabledDefaultFalse(t *testing.T) {
	cases := []struct {
		val  string
		set  bool
		want bool
	}{
		{set: false, want: false}, // unset → default false
		{val: "", set: true, want: false},
		{val: "true", set: true, want: true},
		{val: "TRUE", set: true, want: true},
		{val: "1", set: true, want: true},
		{val: "yes", set: true, want: true},
		{val: "on", set: true, want: true},
		{val: " on ", set: true, want: true}, // trimmed
		{val: "garbage", set: true, want: false},
		{val: "false", set: true, want: false},
		{val: "0", set: true, want: false},
		{val: "no", set: true, want: false},
		{val: "off", set: true, want: false},
	}
	const name = "EIGENINFERENCE_W3_OPTIN_FLAG_TEST"
	for _, c := range cases {
		if c.set {
			t.Setenv(name, c.val)
		}
		if got := envEnabledDefaultFalse(name); got != c.want {
			t.Errorf("envEnabledDefaultFalse(%q set=%v) = %v, want %v", c.val, c.set, got, c.want)
		}
	}
}

// Cold-dispatch is now opt-in (default OFF): it drove the routing-v2 meltdown,
// so it must be explicitly enabled.
func TestColdDispatchFlagDefaultsOff(t *testing.T) {
	s := &Server{}
	if s.coldDispatchEnabled() {
		t.Fatal("coldDispatchEnabled default = true, want false (opt-in)")
	}
	t.Setenv(envColdDispatch, "true")
	if !s.coldDispatchEnabled() {
		t.Fatal("coldDispatchEnabled with =true = false, want true")
	}
}

// coldSpillAvailable / kickColdDispatch must be safe to call on a Server without
// a wired registry (defensive nil-guards), and kickColdDispatch must respect the
// flag.
func TestColdDispatchHelpersNilSafe(t *testing.T) {
	s := &Server{}
	if s.coldSpillAvailable("m", registry.RequestTraits{}, false, nil) {
		t.Fatal("coldSpillAvailable with nil registry = true, want false")
	}
	// Must not panic with a nil registry / disabled flag.
	s.kickColdDispatch("m")
	t.Setenv(envColdDispatch, "false")
	s.kickColdDispatch("m")
}

// A storm of kicks while a swap pass is in flight must coalesce into exactly one
// trigger execution — this is the core anti-write-lock-storm property. Kicks
// arriving within minInterval of the pass completing must also be dropped.
func TestColdKickCoalescesInFlight(t *testing.T) {
	logger := discardLogger()
	var st coldKickState
	var runs int32
	started := make(chan struct{})
	release := make(chan struct{})
	blocking := func() {
		atomic.AddInt32(&runs, 1)
		close(started) // only the single admitted pass reaches here
		<-release      // hold the pass in flight
	}

	// First kick admits the single in-flight pass.
	st.kick(time.Hour, logger, blocking)
	<-started // pass is now executing and blocked

	// 1000 kicks while the pass is in flight must ALL drop (no write-lock storm).
	for i := 0; i < 1000; i++ {
		st.kick(time.Hour, logger, func() { atomic.AddInt32(&runs, 1) })
	}
	if got := atomic.LoadInt32(&runs); got != 1 {
		t.Fatalf("in-flight coalescing: trigger ran %d times during one pass, want 1", got)
	}

	close(release)
	waitColdKickIdle(t, &st)

	// Within minInterval of completion, further kicks are still dropped.
	for i := 0; i < 100; i++ {
		st.kick(time.Hour, logger, func() { atomic.AddInt32(&runs, 1) })
	}
	if got := atomic.LoadInt32(&runs); got != 1 {
		t.Fatalf("min-interval drop: trigger ran %d times within interval, want 1", got)
	}
}

// With a zero min-interval, sequential (non-overlapping) kicks each run, so the
// debounce never permanently wedges the swap machinery.
func TestColdKickRunsAgainAfterInterval(t *testing.T) {
	logger := discardLogger()
	var st coldKickState
	var runs int32
	trig := func() { atomic.AddInt32(&runs, 1) }

	st.kick(0, logger, trig)
	waitColdKickIdle(t, &st)
	if got := atomic.LoadInt32(&runs); got != 1 {
		t.Fatalf("first kick ran %d times, want 1", got)
	}

	st.kick(0, logger, trig)
	waitColdKickIdle(t, &st)
	if got := atomic.LoadInt32(&runs); got != 2 {
		t.Fatalf("second kick ran total %d times, want 2", got)
	}
}

func TestColdDispatchMinInterval(t *testing.T) {
	t.Setenv(envColdDispatchMinInterval, "")
	if got := coldDispatchMinInterval(); got != defaultColdDispatchMinInterval {
		t.Fatalf("unset = %v, want default %v", got, defaultColdDispatchMinInterval)
	}
	t.Setenv(envColdDispatchMinInterval, "250ms")
	if got := coldDispatchMinInterval(); got != 250*time.Millisecond {
		t.Fatalf("override = %v, want 250ms", got)
	}
	t.Setenv(envColdDispatchMinInterval, "not-a-duration")
	if got := coldDispatchMinInterval(); got != defaultColdDispatchMinInterval {
		t.Fatalf("malformed = %v, want default %v", got, defaultColdDispatchMinInterval)
	}
	t.Setenv(envColdDispatchMinInterval, "-5s")
	if got := coldDispatchMinInterval(); got != defaultColdDispatchMinInterval {
		t.Fatalf("negative = %v, want default %v", got, defaultColdDispatchMinInterval)
	}
	t.Setenv(envColdDispatchMinInterval, "0s")
	if got := coldDispatchMinInterval(); got != 0 {
		t.Fatalf("zero = %v, want 0", got)
	}
}
