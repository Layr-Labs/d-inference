package api

import (
	"io"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestInputTokenFloorDefersScalingUntilCostAdmission(t *testing.T) {
	for _, ep := range inputFloorEndpoints {
		for _, mode := range []string{"unfunded", "over_quota", "short_input", "hard_ttft", "capacity", "admitted"} {
			t.Run(ep.path+"/"+mode, func(t *testing.T) {
				desiredFloor, previousFloor := 0, 64
				if mode == "short_input" {
					desiredFloor, previousFloor = 64, 0
				}
				h := newRuntimeDefaultsAliasHarness(t, map[string]any{"min_input_tokens": desiredFloor}, map[string]any{"min_input_tokens": previousFloor})
				srv := h.coordinator
				cfg := registry.ReadConfig().WarmPool
				cfg.Enabled = true
				cfg.ObserveOnly = false
				cfg.MaxLoadsPerTick = 0
				cfg.MaxGlobalPendingLoads = 0 // diagnostics without any provider load actions
				srv.registry.ConfigureWarmPool(cfg)
				srv.registry.RecordWarmPoolSpeculativeStarted(runtimeDefaultsDesiredModel) // observable bucket even without pressure
				for _, id := range []string{"runtime-defaults-desired-provider", h.providers[0].registryID} {
					p := srv.registry.GetProvider(id)
					p.Mu().Lock()
					p.PrefillTPS = 0.2
					if p.BackendCapacity != nil && mode != "capacity" {
						p.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = 0
					}
					p.Mu().Unlock()
				}
				if mode == "hard_ttft" {
					srv.ttftHardReject = true
				}
				if mode == "capacity" || mode == "hard_ttft" {
					srv.registry.Disconnect(h.providers[0].registryID)
				}
				srv.SetBilling(billing.NewService(srv.store, payments.NewLedger(srv.store), quietLogger(), billing.Config{MockMode: true}))
				if mode == "over_quota" {
					srv.consumerTokenLimiter = ratelimit.NewTokenLimiter(0.001, 100, 0.001, 100)
					if ok, _, _ := srv.consumerTokenLimiter.Allow("pressure-account", 100, 100); !ok {
						t.Fatal("failed to exhaust test quota")
					}
				}
				if mode == "admitted" {
					if err := srv.store.Credit("pressure-account", 1000000, store.LedgerDeposit, "test"); err != nil {
						t.Fatal(err)
					}
				}
				body := inputFloorBody(runtimeDefaultsAlias, ep.field, "hi")
				req := tokenReqWithKey("pressure-account", "", &store.APIKey{ID: "pressure-key"})
				req.URL.Path = ep.path
				req.Body = io.NopCloser(strings.NewReader(body))
				req.ContentLength = int64(len(body))
				w := httptest.NewRecorder()
				switch ep.path {
				case "/v1/messages":
					srv.handleAnthropicMessages(w, req)
				case "/v1/completions":
					srv.handleCompletions(w, req)
				default:
					srv.handleChatCompletions(w, req)
				}
				expected := map[string]int{"unfunded": 402, "over_quota": 429, "short_input": 400, "hard_ttft": 429, "capacity": 400, "admitted": 502}[mode]
				// Capacity can shed before final floor/cost validation, depending on queue configuration.
				if mode == "capacity" && w.Code != 429 && w.Code != 402 {
					t.Fatalf("capacity request status=%d body=%s", w.Code, w.Body.String())
				}
				if mode != "capacity" && w.Code != expected {
					t.Fatalf("status=%d want=%d body=%s", w.Code, expected, w.Body.String())
				}
				found := false
				for _, snapshot := range srv.registry.TriggerWarmPool() {
					if snapshot.Model != runtimeDefaultsDesiredModel {
						continue
					}
					found = true
					if mode == "admitted" {
						if snapshot.TTFTMisses == 0 {
							t.Fatal("admitted request lost its deferred TTFT pressure")
						}
					} else if snapshot.CapacityRejects != 0 || snapshot.TTFTMisses != 0 {
						t.Fatalf("unadmitted request scaled pool: %+v", snapshot)
					}
				}
				if !found {
					t.Fatal("missing diagnostic bucket")
				}
			})
		}
	}
}
