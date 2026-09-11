package api

import (
	"io"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestInputTokenFloorDefersScalingUntilCostAdmission(t *testing.T) {
	t.Setenv(envQueueBeforeShed, "false")
	for _, ep := range inputFloorEndpoints {
		for _, mode := range []string{"unfunded", "over_quota", "short_input", "hard_ttft", "capacity", "admitted", "funded_capacity", "funded_hard_ttft"} {
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
					if p.BackendCapacity != nil && !strings.HasSuffix(mode, "capacity") {
						p.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = 0
					}
					p.Mu().Unlock()
				}
				if strings.HasSuffix(mode, "hard_ttft") {
					srv.ttftHardReject = true
				}
				if strings.HasSuffix(mode, "capacity") || strings.HasSuffix(mode, "hard_ttft") {
					srv.registry.Disconnect(h.providers[0].registryID)
				}
				srv.SetBilling(billing.NewService(srv.store, payments.NewLedger(srv.store), quietLogger(), billing.Config{MockMode: true}))
				if mode == "over_quota" {
					srv.consumerTokenLimiter = ratelimit.NewTokenLimiter(0.001, 100, 0.001, 100)
					if ok, _, _ := srv.consumerTokenLimiter.Allow("pressure-account", 100, 100); !ok {
						t.Fatal("failed to exhaust test quota")
					}
				}
				if mode == "admitted" || strings.HasPrefix(mode, "funded_") {
					srv.consumerTokenLimiter = ratelimit.NewTokenLimiter(0.001, 100, 0.001, 100)
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
				expected := map[string]int{"unfunded": 402, "over_quota": 429, "short_input": 400, "hard_ttft": 402, "capacity": 402, "admitted": 502, "funded_capacity": 429, "funded_hard_ttft": 429}[mode]
				if w.Code != expected {
					t.Fatalf("status=%d want=%d body=%s", w.Code, expected, w.Body.String())
				}
				if strings.HasPrefix(mode, "funded_") {
					if balance := srv.store.GetBalance("pressure-account"); balance != 1000000 {
						t.Fatalf("terminal 429 left balance reservation: %d", balance)
					}
					if stat, _ := srv.consumerTokenLimiter.OutputStat("pressure-account"); stat.Remaining != 68 {
						t.Fatalf("quota charged more than once: %+v", stat)
					}
				}
				found := false
				for _, snapshot := range srv.registry.TriggerWarmPool() {
					if snapshot.Model != runtimeDefaultsDesiredModel {
						continue
					}
					found = true
					if mode == "funded_capacity" {
						if snapshot.CapacityRejects != 1 {
							t.Fatalf("eligible capacity 429 lost pressure: %+v", snapshot)
						}
					} else if mode == "admitted" || mode == "funded_hard_ttft" {
						if snapshot.TTFTMisses != 1 {
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

func TestInputTokenFloorKeepsAdmittedBuildIfFallbackCapacityChanges(t *testing.T) {
	t.Setenv(envQueueBeforeShed, "true")
	h := newRuntimeDefaultsAliasHarness(t, map[string]any{"min_input_tokens": 0}, map[string]any{"min_input_tokens": 64})
	srv := h.coordinator
	srv.registry.Disconnect(h.providers[0].registryID)
	previous := registerBuildsProvider(srv, "late-previous", runtimeDefaultsPreviousModel)
	previous.Mu().Lock()
	previous.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = 1000
	previous.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 1000
	previous.Mu().Unlock()
	desired := srv.registry.GetProvider("runtime-defaults-desired-provider")
	desired.Mu().Lock()
	desired.PrefillTPS = 0.2
	desired.Mu().Unlock()
	srv.ttftHardReject = true
	admissions := 0
	gate := &admissionPressureGate{s: srv, fixedBuildAfterAdmission: true, admitRequest: func(model string) bool {
		admissions++
		// Simulate capacity appearing while a database-backed cost gate runs.
		previous.Mu().Lock()
		previous.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = 0
		previous.Mu().Unlock()
		return true
	}}
	w := httptest.NewRecorder()
	req := httptest.NewRequest("POST", "/v1/chat/completions", nil)
	params := inferenceAdmissionParams{
		model: runtimeDefaultsDesiredModel, publicModel: runtimeDefaultsAlias, pressure: gate,
		estimatedPromptTokens: 5, requestedMaxTokens: 32, deadline: 5 * time.Second,
		refundReservation: func() {}, onModelFallback: func(string) bool { t.Error("changed to a floor-ineligible build after cost admission"); return false },
	}
	parsed := map[string]any{"model": runtimeDefaultsDesiredModel}
	model, handled := srv.runInferenceAdmission(w, req, parsed, params)
	if handled || model != runtimeDefaultsDesiredModel || admissions != 1 {
		t.Fatalf("initial queue admission: handled=%v model=%s admissions=%d", handled, model, admissions)
	}
	// Revalidation sees newly available capacity, but the charged build is fixed.
	desired.Mu().Lock()
	desired.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = 0
	desired.Mu().Unlock()
	w = httptest.NewRecorder()
	model, handled = srv.runInferenceAdmission(w, req, parsed, params)
	if !handled || w.Code != 429 || model != runtimeDefaultsDesiredModel || admissions != 1 {
		t.Fatalf("handled=%v status=%d model=%s admissions=%d body=%s", handled, w.Code, model, admissions, w.Body.String())
	}
}
