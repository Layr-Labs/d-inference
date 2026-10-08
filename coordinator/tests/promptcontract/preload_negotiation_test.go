package promptcontract_test

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/preload"
	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/sidecar"
)

func TestPreloadContinuityNegotiationNeverSilentlyDowngrades(t *testing.T) {
	for _, tc := range []struct {
		name               string
		code               int
		body               string
		required, fallback bool
	}{
		{"legacy", 404, "404 page not found\n", false, true},
		{"negotiated404", 404, "404 page not found\n", true, false},
		{"malformed404", 404, "unexpected", false, false},
		{"missingMarker", 200, "report", false, false},
		{"malformed", 200, "{", false, false},
		{"conflict", 409, "busy", false, false},
		{"serverFailure", 500, "failed", false, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			id := strings.Repeat("a", 64)
			var legacy atomic.Int64
			server, socket := startUnixHTTPServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/v1/preload" {
					legacy.Add(1)
					_ = json.NewEncoder(w).Encode(readinessReport([]string{id}, ""))
					return
				}
				w.WriteHeader(tc.code)
				if tc.body == "report" {
					_ = json.NewEncoder(w).Encode(readinessReport([]string{id}, ""))
				} else {
					_, _ = w.Write([]byte(tc.body))
				}
			}))
			t.Cleanup(func() { _ = server.Close() })
			client := sidecar.NewClient(sidecar.ClientConfig{SocketPath: socket})
			t.Cleanup(client.Close)
			_, err := client.PreloadContinuous(context.Background(), []string{id}, tc.required)
			if tc.fallback {
				if err != nil || legacy.Load() != 1 {
					t.Fatalf("legacy fallback: %v calls=%d", err, legacy.Load())
				}
			} else if err == nil || legacy.Load() != 0 {
				t.Fatalf("unsafe downgrade: %v calls=%d", err, legacy.Load())
			}
			if tc.name == "missingMarker" && !errors.Is(err, sidecar.ErrContinuityProtocol) {
				t.Fatal(err)
			}
		})
	}
}

func TestPreloadStaleProtocolFailureWithdrawsSameChildAuthority(t *testing.T) {
	a, b := strings.Repeat("a", 64), strings.Repeat("b", 64)
	entered, release := make(chan struct{}), make(chan struct{})
	var releaseOnce sync.Once
	open := func() { releaseOnce.Do(func() { close(release) }) }
	f := newReadinessControllerFixture(t, func(ctx context.Context, call int64, ids []string) sidecar.PreloadReport {
		report := readinessReport(ids, b)
		if call == 1 {
			report.ContinuityVersion = 1 // The child negotiates continuity.
			return report
		}
		if call == 2 {
			close(entered)
		}
		select {
		case <-release:
		case <-ctx.Done():
		}
		return report // No marker: this child has lost the negotiated protocol.
	})
	t.Cleanup(open)
	f.continuity.Store(true)
	var admissible atomic.Bool
	admissible.Store(true)
	activeControllerSource(t, f.controller, &admissible)
	now := new(atomic.Int64)
	clock := func() time.Duration { return time.Duration(now.Load()) }
	f.policyClock.Store(&clock)
	f.verified(a, b)
	c := f.controller
	c.Reconcile(context.Background())
	if !c.ReadyFor(a) {
		t.Fatal("setup did not publish healthy member")
	}
	// Reproduce a response barrier after selection invalidation. An ordinary
	// stale success keeps only the incumbent; loss of the protocol cannot.
	now.Store(int64(time.Hour)) // The fixture's failure backoff has elapsed.
	done := make(chan struct{})
	go func() { defer close(done); c.Reconcile(context.Background()) }()
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("retry preload never reached its response barrier")
	}
	_, verified := f.provisioner.VerifiedPreloadArtifacts()
	index := slices.IndexFunc(verified, func(artifact preload.VerifiedPreloadArtifact) bool { return artifact.PromptContractID == a })
	if index < 0 {
		t.Fatal("setup lost the healthy member's verified identity")
	}
	// Admissibility drift changes the selection key under the held response and
	// leaves the native set alone, so the response completes a stale operation.
	admissible.Store(false)
	if state := c.PlanningState(verified[index]); !state.Acknowledged || state.Participating {
		t.Fatalf("setup did not invalidate the selection around a retained healthy member: %+v", state)
	}
	open()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("held retry did not drain")
	}
	status := c.Status()
	retained, ready := status.ContractCount, status.Ready
	if retained != 0 || ready || c.ReadyFor(a) {
		t.Fatal("stale protocol failure retained authority")
	}
}
