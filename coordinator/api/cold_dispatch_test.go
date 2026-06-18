package api

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

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

func TestColdDispatchFlagDefaultsOn(t *testing.T) {
	s := &Server{}
	if !s.coldDispatchEnabled() {
		t.Fatal("coldDispatchEnabled default = false, want true")
	}
	t.Setenv(envColdDispatch, "off")
	if s.coldDispatchEnabled() {
		t.Fatal("coldDispatchEnabled with =off = true, want false")
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
