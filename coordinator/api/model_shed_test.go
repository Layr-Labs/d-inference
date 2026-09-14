package api

import (
	"bytes"
	"encoding/json"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func modelShedRequest() *http.Request {
	return httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{}`))
}

func waitForRejectionCount(t *testing.T, srv *Server, want int) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if got := len(srv.store.RejectionRecordsSince(time.Time{})); got >= want {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("rejection records = %d, want >= %d", len(srv.store.RejectionRecordsSince(time.Time{})), want)
}

func TestModelShedRejectsRequestedAlias(t *testing.T) {
	srv, st := testServer(t)
	srv.SetRejectModels(map[string]bool{"gemma-4-26b": true})
	w := httptest.NewRecorder()

	if !exerciseModelShedRoute(t, srv, w, modelShedRequest(), map[string]any{"temperature": 0.2}, selfRoutePolicy{}, "gemma-4-26b", "gemma-4-26b-qat-4bit", true, 1200, 256, false, true) {
		t.Fatal("shedIfModelRejected = false, want true")
	}
	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429", w.Code)
	}
	if w.Header().Get("Retry-After") == "" {
		t.Fatal("Retry-After header missing")
	}
	if !strings.Contains(w.Body.String(), "rate_limit_exceeded") {
		t.Fatalf("body = %s, want rate_limit_exceeded", w.Body.String())
	}
	waitForRejectionCount(t, srv, 1)
	recs := st.RejectionRecordsSince(time.Time{})
	if got := recs[0].ReasonCode; got != "model_shed" {
		t.Fatalf("ReasonCode = %q, want model_shed", got)
	}
	if got := recs[0].RequestedModel; got != "gemma-4-26b" {
		t.Fatalf("RequestedModel = %q", got)
	}
	if got := recs[0].ResolvedModel; got != "gemma-4-26b-qat-4bit" {
		t.Fatalf("ResolvedModel = %q", got)
	}
	if !recs[0].Stream || !recs[0].HasTools || recs[0].RetryAfterMs <= 0 {
		t.Fatalf("record fields = %+v", recs[0])
	}
}

func TestModelShedRejectsResolvedConcreteModel(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetRejectModels(map[string]bool{"gemma-4-26b-qat-4bit": true})
	w := httptest.NewRecorder()

	if !exerciseModelShedRoute(t, srv, w, modelShedRequest(), nil, selfRoutePolicy{}, "gemma-4-26b", "gemma-4-26b-qat-4bit", false, 100, 64, false, false) {
		t.Fatal("shedIfModelRejected = false, want true")
	}
	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429", w.Code)
	}
}

func TestModelShedDoesNotRejectOtherModels(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetRejectModels(map[string]bool{"gemma-4-26b": true})
	w := httptest.NewRecorder()

	if exerciseModelShedRoute(t, srv, w, modelShedRequest(), nil, selfRoutePolicy{}, "gpt-oss-20b", "gpt-oss-20b", false, 100, 64, false, false) {
		t.Fatal("shedIfModelRejected = true for non-shed model")
	}
	if w.Code == http.StatusTooManyRequests {
		t.Fatal("non-shed model was written as a 429")
	}
}

func TestModelShedPolicySelfRouteBypassesPreferOwnerSheds(t *testing.T) {
	srv, st := testServer(t)
	srv.SetRejectModels(map[string]bool{"gemma-4-26b": true})
	self := httptest.NewRecorder()
	prefer := httptest.NewRecorder()

	if exerciseModelShedRoute(t, srv, self, modelShedRequest(), nil, selfRoutePolicy{Enabled: true}, "gemma-4-26b", "gemma-4-26b-qat-4bit", false, 100, 64, false, false) {
		t.Fatal("exclusive self-route should bypass model shed")
	}
	if !exerciseModelShedRoute(t, srv, prefer, modelShedRequest(), nil, selfRoutePolicy{Prefer: true}, "gemma-4-26b", "gemma-4-26b-qat-4bit", false, 100, 64, false, false) {
		t.Fatal("prefer-owner should be model-shed because it can fall back to public fleet")
	}
	waitForRejectionCount(t, srv, 1)
	rec := st.RejectionRecordsSince(time.Time{})[0]
	if !rec.PreferOwner || rec.SelfRouteOnly {
		t.Fatalf("policy telemetry = %+v", rec)
	}
}

// exerciseModelShedRoute preserves the shed status/journal assertions through
// the authenticated production route. A real, unfunded billing service gives
// non-shed public requests a bounded 402 after the gate; exclusive self-route
// reaches its existing no-linked-machine response. Neither path dispatches.
func exerciseModelShedRoute(t *testing.T, srv *Server, w *httptest.ResponseRecorder, r *http.Request, parsed map[string]any, policy selfRoutePolicy, publicModel, model string, stream bool, promptTokens, maxTokens int, requiresVision, hasTools bool) bool {
	t.Helper()
	body := make(map[string]any, len(parsed)+5)
	for key, value := range parsed {
		body[key] = value
	}
	body["model"] = publicModel
	if policy.Enabled {
		// With no owned machine, alias selection ends before the shed gate.
		// A concrete build plus its actual reject entry reaches that gate and
		// distinguishes exclusive bypass from the subsequent 409 preflight.
		body["model"] = model
		srv.SetRejectModels(map[string]bool{publicModel: true, model: true})
	}
	body["messages"] = []any{map[string]any{"role": "user", "content": strings.Repeat("x", max(1, promptTokens-4)*4)}}
	body["max_tokens"] = maxTokens
	body["stream"] = stream
	if requiresVision {
		t.Fatal("model-shed fixture must remain text-only")
	}
	if hasTools {
		body["tools"] = []any{map[string]any{"type": "function", "function": map[string]any{"name": "lookup", "parameters": map[string]any{"type": "object"}}}}
	}
	raw, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: model}})
	if publicModel != model {
		srv.registry.SetModelAliases(map[string]registry.AliasTarget{publicModel: {Desired: model}})
	}
	p := registerBuildsProvider(srv, "model-shed-fixture", model)
	p.Mu().Lock()
	p.Version = "0.7.6"
	p.Mu().Unlock()
	srv.SetBilling(billing.NewService(srv.store, payments.NewLedger(srv.store), srv.logger, billing.Config{MockMode: true}))
	request := httptest.NewRequest(r.Method, r.URL.String(), bytes.NewReader(raw))
	request.Header = r.Header.Clone()
	request.Header.Set("Authorization", "Bearer test-key")
	if policy.Enabled {
		request.Header.Set("X-Darkbloom-Route", "self")
	} else if policy.Prefer {
		request.Header.Set("X-Darkbloom-Route", "prefer")
	}
	srv.Handler().ServeHTTP(w, request)
	if w.Code != http.StatusTooManyRequests && w.Code != http.StatusPaymentRequired && w.Code != http.StatusConflict {
		t.Fatalf("model-shed fixture did not reach its policy or downstream balance/ownership gate: status=%d body=%s", w.Code, w.Body.String())
	}
	return w.Code == http.StatusTooManyRequests
}
