package api

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

// Connect two owned providers and request each explicitly. A selector ignored
// by either HTTP handler cannot pass the provider-id assertions for both calls.
func TestSelfRouteMachineDispatch(t *testing.T) {
	for _, endpoint := range []struct{ path, input string }{
		{"/v1/chat/completions", `"messages":[{"role":"user","content":"hello"}]`},
		{"/v1/responses", `"input":"hello"`},
		{"/v1/completions", `"prompt":"hello"`},
		{"/v1/messages", `"messages":[{"role":"user","content":"hello"}]`},
	} {
		for _, keyOnly := range []bool{false, true} {
			name := endpoint.path
			if keyOnly {
				name += "/key-only"
			}
			t.Run(name, func(t *testing.T) {
				srv, st, ledger := billingTestServer(t)
				ts := httptest.NewServer(srv.Handler())
				defer ts.Close()
				ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
				defer cancel()
				const owner, model = "machine-owner", "local-machine-model"
				raw, _, err := st.CreateAPIKey(owner, store.APIKeyCreate{SelfRouteOnly: keyOnly})
				if err != nil {
					t.Fatal(err)
				}
				ids := make([]string, 0, 2)
				done := make([]<-chan struct{}, 0, 2)
				for i := 0; i < 2; i++ {
					before := make(map[string]bool)
					for _, id := range srv.registry.ProviderIDs() {
						before[id] = true
					}
					conn, _, pubKey := setupProviderForBilling(t, ctx, ts, srv.registry, model)
					defer conn.Close(websocket.StatusNormalClosure, "")
					for _, id := range srv.registry.ProviderIDs() {
						if !before[id] {
							ids = append(ids, id)
						}
					}
					done = append(done, serveOneInference(ctx, t, conn, pubKey, protocol.UsageInfo{PromptTokens: 1, CompletionTokens: 1}))
				}
				setOwnedProvider(srv, owner)
				if len(ids) != 2 {
					t.Fatalf("registered %d machines", len(ids))
				}
				for _, id := range ids {
					body := `{"model":"` + model + `","stream":true,"max_tokens":8,` + endpoint.input + `}`
					req, err := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+endpoint.path, strings.NewReader(body))
					if err != nil {
						t.Fatal(err)
					}
					req.Header.Set("Authorization", "Bearer "+raw)
					req.Header.Set(selfRouteMachineHeader, " "+id+" ")
					if !keyOnly {
						req.Header.Set("X-Darkbloom-Route", "self")
					}
					resp, err := http.DefaultClient.Do(req)
					if err != nil {
						t.Fatal(err)
					}
					responseBody, _ := io.ReadAll(resp.Body)
					resp.Body.Close()
					if resp.StatusCode != http.StatusOK {
						t.Fatalf("status=%d: %s", resp.StatusCode, responseBody)
					}
					if got := resp.Header.Get("X-Provider-Id"); got != id {
						t.Fatalf("provider=%q, want selected %q", got, id)
					}
				}
				for _, ch := range done {
					<-ch
				}
				if balance := ledger.Balance(owner); balance != 0 {
					t.Fatalf("owner balance=%d, want zero", balance)
				}
			})
		}
	}
}

func TestSelfRouteMachineValidationAndAvailability(t *testing.T) {
	srv, st, _ := billingTestServer(t)
	owner := "machine-owner"
	raw, _, err := st.CreateAPIKey(owner, store.APIKeyCreate{})
	if err != nil {
		t.Fatal(err)
	}
	foreign := srv.registry.Register("foreign", nil, &protocol.RegisterMessage{})
	foreign.Mu().Lock()
	foreign.AccountID = "someone-else"
	foreign.Mu().Unlock()
	for _, tc := range []struct {
		name, route string
		values      []string
		status      int
		code        string
	}{
		{"unknown", "self", []string{"missing"}, 503, "machine_offline"},
		{"foreign", "self", []string{"foreign"}, 503, "machine_offline"},
		{"offline", "self", []string{"offline"}, 503, "machine_offline"},
		{"ordinary routing", "", []string{"offline"}, 400, "invalid_request_error"},
		{"prefer", "prefer", []string{"offline"}, 400, "invalid_request_error"},
		{"empty", "self", []string{" "}, 400, "invalid_request_error"},
		{"duplicate", "self", []string{"offline", "offline"}, 400, "invalid_request_error"},
		{"comma separated", "self", []string{"offline,foreign"}, 400, "invalid_request_error"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{"model":"local-model","messages":[{"role":"user","content":"hi"}]}`))
			req.Header.Set("Authorization", "Bearer "+raw)
			req.Header.Set("X-Darkbloom-Route", tc.route)
			for _, v := range tc.values {
				req.Header.Add(selfRouteMachineHeader, v)
			}
			response := httptest.NewRecorder()
			srv.Handler().ServeHTTP(response, req)
			if response.Code != tc.status || !strings.Contains(response.Body.String(), tc.code) {
				t.Fatalf("status=%d body=%s, want %d/%s", response.Code, response.Body, tc.status, tc.code)
			}
		})
	}
}

func TestSelfRouteMachinePreflight(t *testing.T) {
	srv, st, _ := billingTestServer(t)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	const owner = "machine-owner"
	raw, _, err := st.CreateAPIKey(owner, store.APIKeyCreate{})
	if err != nil {
		t.Fatal(err)
	}
	conn, id, _ := setupProviderForBilling(t, ctx, ts, srv.registry, "selected-model")
	defer conn.Close(websocket.StatusNormalClosure, "")
	other, _, _ := setupProviderForBilling(t, ctx, ts, srv.registry, "other-model")
	defer other.Close(websocket.StatusNormalClosure, "")
	setOwnedProvider(srv, owner)
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{"model":"other-model","messages":[{"role":"user","content":"hi"}]}`))
	req.Header.Set("Authorization", "Bearer "+raw)
	req.Header.Set("X-Darkbloom-Route", "self")
	req.Header.Set(selfRouteMachineHeader, id)
	response := httptest.NewRecorder()
	srv.Handler().ServeHTTP(response, req)
	if response.Code != 503 || !strings.Contains(response.Body.String(), "model_not_loaded") {
		t.Fatalf("preflight=%d: %s", response.Code, response.Body)
	}
}

func TestSelfRouteMachineRetryTraits(t *testing.T) {
	d := dispatchState{policy: selfRoutePolicy{enabled: true, ownerAccountID: "owner", providerID: "selected"}, lastFailedVersion: "0.9.16"}
	if got := d.traits().TargetProviderID; got != "selected" {
		t.Fatalf("retry target=%q", got)
	}
	d.lastFailureDeadline = true
	if got := d.traits().TargetProviderID; got != "selected" {
		t.Fatalf("deadline retry target=%q", got)
	}
}

func TestSelfRouteMachineCORS(t *testing.T) {
	srv, _ := testServer(t)
	req := httptest.NewRequest(http.MethodOptions, "/v1/chat/completions", nil)
	req.Header.Set("Origin", "https://console.darkbloom.dev")
	req.Header.Set("Access-Control-Request-Method", "POST")
	req.Header.Set("Access-Control-Request-Headers", "authorization,x-darkbloom-route,x-darkbloom-machine")
	response := httptest.NewRecorder()
	srv.Handler().ServeHTTP(response, req)
	if response.Code != http.StatusNoContent {
		t.Fatalf("preflight status=%d", response.Code)
	}
	allowed := response.Header().Get("Access-Control-Allow-Headers")
	for _, header := range []string{"X-Darkbloom-Route", selfRouteMachineHeader} {
		if !strings.Contains(allowed, header) {
			t.Fatalf("allowed headers %q missing %s", allowed, header)
		}
	}
}
