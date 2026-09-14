package main

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// TestPprofListener pins the EIGENINFERENCE_PPROF_ADDR contract from the
// 2026-09-01 incident review (the running binary had NO pprof, which made the
// CPU-collapse diagnosis slow): by default nothing serves /debug/pprof/ — in
// particular the PUBLIC coordinator mux must not — and when the env-gated
// dedicated listener is started it serves the pprof index on its own port.
func TestPprofListener(t *testing.T) {
	// Default off: the public coordinator mux exposes no pprof routes.
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	srv := api.NewServer(registry.New(logger), store.NewMemory(store.Config{}), api.ServerConfig{}, logger)
	public := httptest.NewServer(srv.Handler())
	defer public.Close()
	resp, err := http.Get(public.URL + "/debug/pprof/")
	if err != nil {
		t.Fatalf("public mux request: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("public mux /debug/pprof/ = %d, want 404 (pprof must never mount on the public mux)", resp.StatusCode)
	}

	// Env set: the dedicated listener serves the pprof index.
	ln, err := startPprofListener("127.0.0.1:0")
	if err != nil {
		t.Fatalf("startPprofListener: %v", err)
	}
	defer ln.Close()
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err = client.Get("http://" + ln.Addr().String() + "/debug/pprof/")
	if err != nil {
		t.Fatalf("pprof listener request: %v", err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("pprof listener /debug/pprof/ = %d, want 200", resp.StatusCode)
	}
	if !strings.Contains(string(body), "goroutine") {
		t.Errorf("pprof index missing profile listing; body=%.200s", string(body))
	}

	// A malformed address surfaces the listen error instead of half-starting.
	if _, err := startPprofListener("not-an-address"); err == nil {
		t.Error("startPprofListener(not-an-address) = nil error, want listen failure")
	}
}

// TestPprofListenerEnablesContentionProfiles: the mutex and block profiles are
// off in the Go runtime by default (mutex.pprof and block.pprof come back
// empty); enabling the pprof listener turns them on at a sampling rate that
// is negligible in production, and the listener serves both endpoints.
func TestPprofListenerEnablesContentionProfiles(t *testing.T) {
	previous := runtime.SetMutexProfileFraction(-1)
	t.Cleanup(func() {
		runtime.SetMutexProfileFraction(previous)
		runtime.SetBlockProfileRate(0)
	})

	enableContentionProfiling()
	if got := runtime.SetMutexProfileFraction(-1); got != 100 {
		t.Fatalf("mutex profile fraction = %d, want 100", got)
	}

	ln, err := startPprofListener("127.0.0.1:0")
	if err != nil {
		t.Fatalf("startPprofListener: %v", err)
	}
	defer ln.Close()
	client := &http.Client{Timeout: 5 * time.Second}
	for _, profile := range []string{"mutex", "block"} {
		resp, err := client.Get("http://" + ln.Addr().String() + "/debug/pprof/" + profile + "?debug=1")
		if err != nil {
			t.Fatalf("%s profile: %v", profile, err)
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("/debug/pprof/%s = %d, want 200", profile, resp.StatusCode)
		}
		if !strings.Contains(string(body), "sampling period") && !strings.Contains(string(body), "cycles/second") {
			t.Fatalf("/debug/pprof/%s body is not a %s profile: %.200s", profile, profile, body)
		}
	}
}
