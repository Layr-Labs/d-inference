package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

func TestSelfRouteRoutingBlockersHTTP(t *testing.T) {
	for _, tc := range []struct {
		name                             string
		change                           func(*registry.Provider)
		wantCode, wantReason, retryAfter string
	}{
		{"runtime", func(p *registry.Provider) { p.RuntimeVerified = false }, "model_routing_blocked", "runtime_unverified", ""},
		{"template", func(p *registry.Provider) { p.Models[0].TemplateRenderOK = new(bool) }, "model_routing_blocked", "template_render_failed", ""},
		{"loaded_not_advertised", func(p *registry.Provider) {
			p.Models = nil
			p.BackendCapacity = nil
			p.CurrentModel = "self-route-blocked-model"
		}, "model_routing_blocked", "model_not_advertised", ""},
		{"absent", func(p *registry.Provider) { p.Models = nil; p.BackendCapacity = nil; p.CurrentModel = "" }, "model_not_loaded", "load it on your node", "15"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srv, st, ledger := billingTestServer(t)
			ts := httptest.NewServer(srv.Handler())
			defer ts.Close()
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			const owner, model = "blocked-owner", "self-route-blocked-model"
			key, _, err := st.CreateAPIKey(owner, store.APIKeyCreate{Name: "self"})
			if err != nil {
				t.Fatal(err)
			}
			conn, id, _ := setupProviderForBilling(t, ctx, ts, srv.registry, model)
			defer conn.Close(websocket.StatusNormalClosure, "")
			setOwnedProvider(srv, owner)
			p := srv.registry.GetProvider(id)
			p.Mu().Lock()
			tc.change(p)
			p.Mu().Unlock()
			request, err := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(`{"model":"`+model+`","messages":[{"role":"user","content":"hello"}]}`))
			if err != nil {
				t.Fatal(err)
			}
			request.Header.Set("Authorization", "Bearer "+key)
			request.Header.Set("Content-Type", "application/json")
			request.Header.Set("X-Darkbloom-Route", "self")
			response, err := http.DefaultClient.Do(request)
			if err != nil {
				t.Fatal(err)
			}
			defer response.Body.Close()
			var body struct {
				Error struct{ Code, Message string }
			}
			if err := json.NewDecoder(response.Body).Decode(&body); err != nil {
				t.Fatal(err)
			}
			if response.StatusCode != http.StatusServiceUnavailable || body.Error.Code != tc.wantCode || !strings.Contains(body.Error.Message, tc.wantReason) {
				t.Fatalf("status=%d error=%+v, want 503 %s (%s)", response.StatusCode, body.Error, tc.wantCode, tc.wantReason)
			}
			if got := response.Header.Get("Retry-After"); got != tc.retryAfter {
				t.Fatalf("Retry-After=%q, want %q", got, tc.retryAfter)
			}
			if ledger.Balance(owner) != 0 || len(ledger.Usage(owner)) != 0 {
				t.Fatal("blocked self-route was charged or dispatched")
			}
		})
	}
}
