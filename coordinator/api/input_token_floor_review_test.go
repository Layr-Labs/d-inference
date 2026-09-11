package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestInputTokenFloorEmptyInputIgnoresRequestOptions(t *testing.T) {
	for _, ep := range inputFloorEndpoints {
		t.Run(ep.path, func(t *testing.T) {
			srv, st := testServerWithConfig(t, ServerConfig{DefaultMinInputTokens: 32})
			t.Cleanup(srv.Close)
			seedRuntimeDefaultsModel(t, st, "floor-test", nil)
			srv.SyncModelCatalog()
			body := map[string]any{"model": "floor-test", "max_tokens": 9999, "stream": true, "temperature": 0.5, "top_p": 0.9, "seed": 123456789, "unrelated_option": strings.Repeat("x", 256)}
			if ep.field == "messages" {
				body[ep.field] = []any{}
			} else {
				body[ep.field] = ""
			}
			tokens, _ := routingShape(body)
			if tokens != 0 {
				t.Fatalf("prompt-field estimate=%d", tokens)
			}
			if estimatePromptTokens(body) < 32 {
				t.Fatal("fixture must trigger whole-body routing fallback")
			}
			raw, _ := json.Marshal(body)
			req := httptest.NewRequest(http.MethodPost, ep.path, strings.NewReader(string(raw)))
			req.Header.Set("Authorization", "Bearer test-key")
			w := httptest.NewRecorder()
			srv.Handler().ServeHTTP(w, req)
			if w.Code != 400 {
				t.Fatalf("empty input accepted: %d %s", w.Code, w.Body.String())
			}
			// Empty chat arrays already fail required-message validation. Empty scalar
			// inputs reach the floor and must count only the empty user-message framing.
			if ep.field != "messages" && (!strings.Contains(w.Body.String(), "input_too_short") || !strings.Contains(w.Body.String(), "estimated 4 input tokens")) {
				t.Fatalf("wrong floor response: %s", w.Body.String())
			}
		})
	}
}

func TestInputTokenFloorAllowsLowerAliasFallback(t *testing.T) {
	for _, ep := range inputFloorEndpoints {
		for _, mode := range []string{"capacity", "hard_ttft"} {
			t.Run(ep.path+"/"+mode, func(t *testing.T) {
				h := newRuntimeDefaultsAliasHarness(t, map[string]any{"min_input_tokens": 64}, map[string]any{"min_input_tokens": 0})
				if mode == "hard_ttft" {
					h.coordinator.ttftHardReject = true
					desired := h.coordinator.registry.GetProvider("runtime-defaults-desired-provider")
					desired.Mu().Lock()
					desired.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = 0
					desired.PrefillTPS = 0.2
					desired.Mu().Unlock()
				}
				postRuntimeDefaultsEndpoint(t, h, ep.path, inputFloorBody(runtimeDefaultsAlias, ep.field, "hello"))
				readRuntimeDefaultsProviderBody(t, h.providers[0])
			})
		}
	}
}

func TestInputTokenFloorDoesNotFallbackOnlyForLowerMinimum(t *testing.T) {
	for _, ep := range inputFloorEndpoints {
		t.Run(ep.path, func(t *testing.T) {
			h := newRuntimeDefaultsAliasHarness(t, map[string]any{"min_input_tokens": 64}, map[string]any{"min_input_tokens": 0})
			desired := h.coordinator.registry.GetProvider("runtime-defaults-desired-provider")
			desired.Mu().Lock()
			desired.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = 0
			desired.Mu().Unlock()
			req, _ := http.NewRequestWithContext(h.ctx, http.MethodPost, h.server.URL+ep.path, strings.NewReader(inputFloorBody(runtimeDefaultsAlias, ep.field, "hello")))
			req.Header.Set("Authorization", "Bearer test-key")
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			raw, err := io.ReadAll(resp.Body)
			resp.Body.Close()
			if err != nil {
				t.Fatal(err)
			}
			if resp.StatusCode != 400 || !strings.Contains(string(raw), "input_too_short") {
				t.Fatalf("status=%d body=%s", resp.StatusCode, raw)
			}
			select {
			case <-h.providers[0].bodies:
				t.Fatal("floor alone must not cause fallback")
			default:
			}
		})
	}
}

type inputFloorFailingReadStore struct {
	store.Store
	failModel string
}

func (s inputFloorFailingReadStore) GetModelRegistryRecord(id string) (*store.ModelRegistryRecord, error) {
	if id == s.failModel {
		return nil, errors.New("injected registry failure")
	}
	return s.Store.GetModelRegistryRecord(id)
}

func TestInputTokenFloorStoreErrorsDoNotBecomeDefaults(t *testing.T) {
	for _, ep := range inputFloorEndpoints {
		for _, floor := range []int{0, 64} {
			t.Run(fmt.Sprintf("%s/min=%d", ep.path, floor), func(t *testing.T) {
				srv, st := testServerWithConfig(t, ServerConfig{DefaultMinInputTokens: 32})
				t.Cleanup(srv.Close)
				seedRuntimeDefaultsModel(t, st, "floor-test", map[string]any{"min_input_tokens": floor})
				srv.SyncModelCatalog()
				srv.store = inputFloorFailingReadStore{Store: st, failModel: "floor-test"}
				req := httptest.NewRequest(http.MethodPost, ep.path, strings.NewReader(inputFloorBody("floor-test", ep.field, "hello")))
				req.Header.Set("Authorization", "Bearer test-key")
				w := httptest.NewRecorder()
				srv.Handler().ServeHTTP(w, req)
				if w.Code != 503 || !strings.Contains(w.Body.String(), "service_unavailable") {
					t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
				}
				if len(st.UsageRecords()) != 0 {
					t.Fatal("failed policy read dispatched/billed")
				}
			})
		}
	}
}

func TestInputTokenFloorFallbackStoreError(t *testing.T) {
	for _, ep := range inputFloorEndpoints {
		t.Run(ep.path, func(t *testing.T) {
			h := newRuntimeDefaultsAliasHarness(t, map[string]any{"min_input_tokens": 0}, map[string]any{"min_input_tokens": 64})
			h.coordinator.store = inputFloorFailingReadStore{Store: h.coordinator.store, failModel: runtimeDefaultsPreviousModel}
			req, _ := http.NewRequestWithContext(h.ctx, http.MethodPost, h.server.URL+ep.path, strings.NewReader(inputFloorBody(runtimeDefaultsAlias, ep.field, "hello")))
			req.Header.Set("Authorization", "Bearer test-key")
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			raw, err := io.ReadAll(resp.Body)
			resp.Body.Close()
			if err != nil {
				t.Fatal(err)
			}
			if resp.StatusCode != 503 {
				t.Fatalf("status=%d body=%s", resp.StatusCode, raw)
			}
			select {
			case <-h.providers[0].bodies:
				t.Fatal("failed policy read reached provider")
			default:
			}
		})
	}
}

func TestInputTokenFloorRejectionTelemetry(t *testing.T) {
	for _, media := range []bool{false, true} {
		t.Run(map[bool]string{false: "text", true: "vision tools"}[media], func(t *testing.T) {
			srv, st := testServerWithConfig(t, ServerConfig{DefaultMinInputTokens: 1024})
			t.Cleanup(srv.Close)
			seedRuntimeDefaultsModel(t, st, "floor-test", nil)
			srv.SyncModelCatalog()
			provider := registerBuildsProvider(srv, "floor-provider", "floor-test")
			provider.Mu().Lock()
			provider.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 4096
			provider.Mu().Unlock()
			content := []any{map[string]any{"type": "text", "text": "hi"}}
			parsed := map[string]any{"messages": []any{map[string]any{"role": "user", "content": content}}, "max_tokens": 32}
			if media {
				content = append(content, map[string]any{"type": "image_url", "image_url": map[string]any{"url": "data:image/png;base64,eA=="}})
				parsed["messages"] = []any{map[string]any{"role": "user", "content": content}}
				parsed["tools"] = []any{map[string]any{"type": "function", "function": map[string]any{"name": "test"}}}
			}
			tokens, _ := routingShape(parsed)
			req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
			if !srv.rejectShortInput(httptest.NewRecorder(), req, parsed, "floor-test", "floor-test", tokens, nil) {
				t.Fatal("expected rejection")
			}
			waitForAdaptiveCondition(t, time.Second, func() bool { return len(st.RejectionRecordsSince(time.Time{})) == 1 })
			rec := st.RejectionRecordsSince(time.Time{})[0]
			if rec.RequiresVision != media || rec.HasTools != media {
				t.Fatalf("lost traits: %+v", rec)
			}
			if rec.CouldHaveServed == nil {
				t.Fatal("missing counterfactual")
			}
			if !media && !*rec.CouldHaveServed {
				t.Fatal("routable text provider should be counted")
			}
		})
	}
}
