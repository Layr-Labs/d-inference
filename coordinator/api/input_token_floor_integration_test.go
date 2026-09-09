package api

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

var inputFloorEndpoints = []struct{ path, field string }{
	{"/v1/chat/completions", "messages"}, {"/v1/responses", "input"}, {"/v1/completions", "prompt"}, {"/v1/messages", "messages"},
}

func inputFloorBody(model, field, content string) string {
	body := map[string]any{"model": model, "max_tokens": 32, "stream": true, "min_input_tokens": 0}
	if field == "messages" {
		body[field] = []any{map[string]any{"role": "user", "content": content}}
	} else {
		body[field] = content
	}
	raw, _ := json.Marshal(body)
	return string(raw)
}

func TestInputTokenFloorRejectsEveryEndpointBeforeRouting(t *testing.T) {
	for _, ep := range inputFloorEndpoints {
		t.Run(ep.path, func(t *testing.T) {
			t.Setenv("EIGENINFERENCE_MIN_INPUT_TOKENS", "")
			srv, st := testServerWithConfig(t, ReadServerConfig())
			t.Cleanup(srv.Close)
			seedRuntimeDefaultsModel(t, st, "floor-test", nil)
			srv.SyncModelCatalog()
			req := httptest.NewRequest(http.MethodPost, ep.path, strings.NewReader(inputFloorBody("floor-test", ep.field, "hello")))
			req.Header.Set("Authorization", "Bearer test-key")
			w := httptest.NewRecorder()
			srv.Handler().ServeHTTP(w, req)
			if w.Code != 400 || !strings.Contains(w.Body.String(), `"code":"input_too_short"`) {
				t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
			}
			if strings.Contains(w.Body.String(), "data:") {
				t.Fatal("must reject before opening a stream")
			}
			if got := st.UsageRecords(); len(got) != 0 {
				t.Fatal("rejected input was billed")
			}
		})
	}
}

func TestInputTokenFloorModelOverrideAndAliasFallback(t *testing.T) {
	for _, ep := range inputFloorEndpoints {
		for _, tc := range []struct {
			minimum int
			content string
			reject  bool
		}{
			{0, "hello", false}, {32, "hello", true}, {32, strings.Repeat("a", 128), false},
		} {
			minimum := tc.minimum
			t.Run(fmt.Sprintf("%s/min=%d/length=%d", ep.path, minimum, len(tc.content)), func(t *testing.T) {
				// Desired is capacity-exhausted. The Previous build owns the floor used
				// after fallback; an initially admitted request must not bypass it.
				harness := newRuntimeDefaultsAliasHarness(t, map[string]any{"min_input_tokens": 0}, map[string]any{"min_input_tokens": minimum})
				content := tc.content
				if len(content) == 128 && ep.field == "messages" {
					content = content[:112]
				}
				body := inputFloorBody(runtimeDefaultsAlias, ep.field, content)
				if len(tc.content) == 128 {
					var parsed map[string]any
					if err := json.Unmarshal([]byte(body), &parsed); err != nil {
						t.Fatal(err)
					}
					if got := estimatePromptTokens(parsed); got != 32 {
						t.Fatalf("boundary fixture estimated %d, want 32", got)
					}
				}
				req, err := http.NewRequestWithContext(harness.ctx, http.MethodPost, harness.server.URL+ep.path, strings.NewReader(body))
				if err != nil {
					t.Fatal(err)
				}
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
				if tc.reject {
					if resp.StatusCode != 400 || !strings.Contains(string(raw), `"code":"input_too_short"`) {
						t.Fatalf("status=%d body=%s", resp.StatusCode, raw)
					}
					select {
					case <-harness.providers[0].bodies:
						t.Fatal("below-minimum request reached the fallback provider")
					default:
					}
				} else {
					if resp.StatusCode != 200 {
						t.Fatalf("status=%d body=%s", resp.StatusCode, raw)
					}
					readRuntimeDefaultsProviderBody(t, harness.providers[0])
				}
			})
		}
	}
}

func TestInputTokenFloorAdminUpdate(t *testing.T) {
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")
	srv, st := testServer(t)
	t.Cleanup(srv.Close)
	seedRuntimeDefaultsModel(t, st, "floor-test", map[string]any{"reasoning_parser": "keep"})
	cached := store.NewCached(st, store.DefaultCacheConfig())
	srv.store = cached
	if _, err := cached.GetModelRegistryRecord("floor-test"); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		value  string
		status int
	}{{"0", 200}, {"1.5", 400}, {"-1", 400}, {`"0"`, 400}, {"null", 200}, {"64", 200}} {
		req := httptest.NewRequest(http.MethodPost, "/v1/admin/models/floor-test/runtime-parameters", strings.NewReader(`{"runtime_parameters":{"min_input_tokens":`+tc.value+`}}`))
		req.Header.Set("Authorization", "Bearer publish-secret")
		w := httptest.NewRecorder()
		srv.handleAdminModelRegistryAction(w, req)
		if w.Code != tc.status {
			t.Fatalf("%s: status=%d body=%s", tc.value, w.Code, w.Body.String())
		}
		rec, err := cached.GetModelRegistryRecord("floor-test")
		if err != nil {
			t.Fatal(err)
		}
		if rec.RuntimeParameters["reasoning_parser"] != "keep" {
			t.Fatal("partial update lost existing runtime parameter")
		}
		want := 0
		if tc.value == "null" {
			want = 32
		}
		if tc.value == "64" {
			want = 64
		}
		if got := minimumInputTokens(32, rec.RuntimeParameters); got != want {
			t.Fatalf("%s: cached minimum=%d want %d", tc.value, got, want)
		}
	}
}

func TestInputTokenFloorBeforeBalanceReservation(t *testing.T) {
	srv, st := testBillingServer(t)
	t.Cleanup(srv.Close)
	srv.defaultMinInputTokens = 32
	seedRuntimeDefaultsModel(t, st, "floor-test", nil)
	srv.SyncModelCatalog()
	// With no credit, reaching the reservation would produce 402. The floor
	// must instead reject before invoking billing.
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(inputFloorBody("floor-test", "messages", "hello")))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)
	if w.Code != 400 || !strings.Contains(w.Body.String(), `"code":"input_too_short"`) {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
}
