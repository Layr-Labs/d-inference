package api

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestInputTokenFloorScalarFramingParity(t *testing.T) {
	for _, n := range []int{0, 108, 112, 116} {
		text := strings.Repeat("a", n)
		for _, ep := range []promptcontract.Endpoint{promptcontract.EndpointChatCompletions, promptcontract.EndpointResponses, promptcontract.EndpointCompletions} {
			parsed := map[string]any{"model": "m"}
			switch ep {
			case promptcontract.EndpointChatCompletions:
				parsed["messages"] = []any{map[string]any{"role": "user", "content": text}}
			case promptcontract.EndpointResponses:
				parsed["input"] = text
			case promptcontract.EndpointCompletions:
				parsed["prompt"] = text
			}
			raw, _ := json.Marshal(parsed)
			lowered, err := promptcontract.LowerProviderBody(ep, raw)
			if err != nil {
				t.Fatal(err)
			}
			body, err := decodeInferenceJSONObject(lowered)
			if err != nil {
				t.Fatal(err)
			}
			want, _ := routingShape(body)
			if got := inputFloorPromptTokens(parsed, ep); got != want {
				t.Fatalf("endpoint %s length %d: %d vs lowered %d", ep, n, got, want)
			}
		}
	}
}

func TestInputTokenFloorDeferredAdmissionHasNoCharges(t *testing.T) {
	for _, ep := range inputFloorEndpoints {
		for _, reverse := range []bool{false, true} {
			for _, funded := range []bool{false, true} {
				t.Run(fmt.Sprintf("%s/reverse=%v/funded=%v", ep.path, reverse, funded), func(t *testing.T) {
					desiredFloor, previousFloor := 64, 0
					if reverse {
						desiredFloor, previousFloor = 0, 64
					}
					h := newRuntimeDefaultsAliasHarness(t, map[string]any{"min_input_tokens": desiredFloor}, map[string]any{"min_input_tokens": previousFloor})
					srv := h.coordinator
					if !reverse {
						p := srv.registry.GetProvider("runtime-defaults-desired-provider")
						p.Mu().Lock()
						p.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = 0
						p.Mu().Unlock()
					}
					srv.consumerTokenLimiter = ratelimit.NewTokenLimiter(0.001, 100, 0.001, 100)
					srv.keyTokenLimiter = ratelimit.NewKeyTokenLimiter()
					limit := int64(100)
					key := &store.APIKey{ID: "floor-test-key", ITPMLimit: &limit, OTPMLimit: &limit}
					srv.SetBilling(billing.NewService(srv.store, payments.NewLedger(srv.store), quietLogger(), billing.Config{MockMode: true}))
					balance := int64(0)
					if funded {
						balance = 1000000
						if err := srv.store.Credit("floor-account", balance, store.LedgerDeposit, "test"); err != nil {
							t.Fatal(err)
						}
					}
					body := inputFloorBody(runtimeDefaultsAlias, ep.field, "hi")
					req := tokenReqWithKey("floor-account", "", key)
					req.URL.Path = ep.path
					req.Body = io.NopCloser(strings.NewReader(body))
					req.ContentLength = int64(len(body))
					w := httptest.NewRecorder()
					switch ep.path {
					case "/v1/completions":
						srv.handleCompletions(w, req)
					case "/v1/messages":
						srv.handleAnthropicMessages(w, req)
					default:
						srv.handleChatCompletions(w, req)
					}
					if w.Code != 400 || !strings.Contains(w.Body.String(), "input_too_short") {
						t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
					}
					if ok, _, _ := srv.consumerTokenLimiter.Peek("floor-account", 100, 100); !ok {
						t.Fatal("floor rejection consumed account quota")
					}
					if ok, _, _ := srv.keyTokenLimiter.Peek(key.ID, 100, 100, float64(limit)/60, 100, float64(limit)/60, 100); !ok {
						t.Fatal("floor rejection consumed key quota")
					}
					if got := srv.store.GetBalance("floor-account"); got != balance {
						t.Fatalf("balance=%d want %d", got, balance)
					}
					select {
					case <-h.providers[0].bodies:
						t.Fatal("rejected input reached provider")
					default:
					}
				})
			}
		}
	}
}

func TestInputTokenFloorAcceptedAliasChargesOnce(t *testing.T) {
	h := newRuntimeDefaultsAliasHarness(t, map[string]any{"min_input_tokens": 0}, map[string]any{"min_input_tokens": 0})
	srv := h.coordinator
	srv.consumerTokenLimiter = ratelimit.NewTokenLimiter(0.001, 100, 0.001, 100)
	srv.keyTokenLimiter = ratelimit.NewKeyTokenLimiter()
	limit := int64(100)
	key := &store.APIKey{ID: "floor-test-key", ITPMLimit: &limit, OTPMLimit: &limit}
	for i := 0; i < 2; i++ {
		body := inputFloorBody(runtimeDefaultsAlias, "messages", "hi")
		req := tokenReqWithKey("floor-account", "", key)
		req.URL.Path = "/v1/chat/completions"
		req.Body = io.NopCloser(strings.NewReader(body))
		req.ContentLength = int64(len(body))
		w := httptest.NewRecorder()
		srv.handleChatCompletions(w, req)
		if w.Code != 200 {
			t.Fatalf("request %d status=%d body=%s", i, w.Code, w.Body.String())
		}
		readRuntimeDefaultsProviderBody(t, h.providers[0])
	}
	if stat, _ := srv.consumerTokenLimiter.OutputStat("floor-account"); stat.Remaining != 36 {
		t.Fatalf("remaining=%d want 36 (two charges of 32)", stat.Remaining)
	}
	if ok, _, _ := srv.keyTokenLimiter.Peek(key.ID, 1, 90, float64(limit)/60, 100, float64(limit)/60, 100); ok {
		t.Fatal("accepted alias did not charge key quota")
	}
}
