package api

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func reportFirstContentIdleCapacity(t *testing.T, reg *registry.Registry, fp *failoverProvider, model string, observed, isolated float64) {
	t.Helper()
	zero, initialized := int64(0), true
	if !reg.Heartbeat(fp.registryID, &protocol.HeartbeatMessage{
		Status: "idle", ActiveModel: &model,
		SystemMetrics: protocol.SystemMetrics{ThermalState: "nominal"},
		BackendCapacity: &protocol.BackendCapacity{
			TotalMemoryGB: 64,
			Slots: []protocol.BackendSlotCapacity{{
				Model: model, State: "idle", MaxConcurrency: 4, ActiveTokenBudgetMax: 200_000,
				ObservedPrefillTPS: observed, ObservedDecodeTPS: 100,
				Telemetry: &protocol.SlotTelemetry{
					QueuedPrefillTokens: &zero, PartialPrefillRows: &zero,
					IsolatedPrefillTPS: &isolated, EWMAInitialized: &initialized,
				},
			}},
		},
	}) {
		t.Fatal("idle capacity heartbeat was not applied")
	}
}

// These are real HTTP/encrypted WebSocket requests with scripted inference.
// They prove selection and completed delivery, not measured provider speed.
func TestFirstContentRoutingHTTPPrefersFeasibleProvider(t *testing.T) {
	t.Setenv(envProfiler, "on")
	registry.ResetTTFTCalibration()
	t.Cleanup(registry.ResetTTFTCalibration)
	for _, tc := range []struct {
		name, mode   string
		cheapRefuses bool
		wantCheap    int32
		wantFast     int32
	}{
		{"off preserves cost winner", registry.FirstContentRoutingOff, false, 1, 0},
		{"shadow preserves cost winner", registry.FirstContentRoutingShadow, false, 1, 0},
		{"off retries after deadline refusal", registry.FirstContentRoutingOff, true, 1, 1},
		{"prefer avoids deadline refusal", registry.FirstContentRoutingPrefer, true, 0, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			reg, _, srv, ts := setupTTFTFailoverServerWithConfig(t, ServerConfig{FirstContentDeadlineBase: 9 * time.Second})
			t.Cleanup(srv.Close)
			srv.SetTTFTHardReject(false)
			if err := reg.ConfigureFirstContentRouting(tc.mode); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			const model = "gpt-oss-first-content-http"
			type observation struct {
				provider              string
				estimated, calibrated int
				budget                int64
				decision              registry.RoutingDecision
			}
			observations := make(chan observation, 2)
			script := func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
				got := observation{provider: fp.name, budget: req.FirstContentBudgetMS}
				if p := reg.GetProvider(fp.registryID); p != nil {
					if pr := p.GetPending(req.RequestID); pr != nil {
						got.estimated, got.calibrated = pr.EstimatedPromptTokens, pr.FirstContentPromptTokens
						if pr.Profile != nil && pr.Profile.DecisionSet {
							got.decision = pr.Profile.Decision
						}
					}
				}
				observations <- got
				if tc.cheapRefuses && fp.name == "cheap" {
					fp.sendTypedInferenceError(ctx, req, protocol.FailureCodeCapacity, errorReasonDeadlineUnreachable, http.StatusServiceUnavailable)
					return
				}
				fp.serveFull(ctx, req, model, markerFor(fp.name))
			}
			cheap := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
				Name: "cheap", Version: "0.9.2", DecodeTPS: 100,
				Models: []failoverModelSpec{{ID: model}}, Script: script,
			})
			fast := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
				Name: "fast", Version: "0.9.2", DecodeTPS: 100,
				Models: []failoverModelSpec{{ID: model}}, Script: script,
			})
			// Encryption/base64 makes this long prompt exceed the WebSocket
			// client's default read limit before the provider script sees it.
			cheap.conn.SetReadLimit(1 << 20)
			fast.conn.SetReadLimit(1 << 20)
			// Ordinary cost favors 4000 over 500 TPS, while the isolated rates
			// make only the second provider feasible for the calibrated prompt.
			reportFirstContentIdleCapacity(t, reg, cheap, model, 4000, 100)
			reportFirstContentIdleCapacity(t, reg, fast, model, 500, 1800)
			parsed := map[string]any{
				"model": model, "stream": true, "max_tokens": 128,
				"messages": []any{map[string]any{"role": "user", "content": strings.Repeat("a", 32_000)}},
			}
			estimated := estimatePromptTokens(parsed)
			body, err := json.Marshal(parsed)
			if err != nil {
				t.Fatal(err)
			}
			status, response, err := postChat(ctx, ts.URL, "test-key", string(body))
			if err != nil {
				t.Fatal(err)
			}
			winner := "cheap"
			if tc.wantFast > 0 {
				winner = "fast"
			}
			assertCleanFailoverStream(t, status, response, markerFor(winner))
			if cheap.dispatches.Load() != tc.wantCheap || fast.dispatches.Load() != tc.wantFast {
				t.Fatalf("dispatches cheap=%d fast=%d, want %d/%d; response=%s", cheap.dispatches.Load(), fast.dispatches.Load(), tc.wantCheap, tc.wantFast, response)
			}
			for range tc.wantCheap + tc.wantFast {
				got := <-observations
				if got.estimated != estimated || got.calibrated != int(float64(estimated)*1.3) || got.calibrated <= got.estimated {
					t.Fatalf("dispatch lost separate calibrated prompt estimate: %+v; original=%d", got, estimated)
				}
				if got.budget <= 0 {
					t.Fatalf("dispatch lost inherited first-content clock: %+v", got)
				}
				if tc.mode == registry.FirstContentRoutingPrefer && (got.decision.FirstContent.Status != "feasible" || got.decision.FirstContent.PromptTokens != got.calibrated) {
					t.Fatalf("completed preferred dispatch lacks feasible calibrated decision: %+v", got)
				}
				if tc.mode == registry.FirstContentRoutingShadow && got.decision.FirstContent.Status != "infeasible" {
					t.Fatalf("shadow must observe infeasibility while preserving the old choice: %+v", got)
				}
			}
		})
	}
}
