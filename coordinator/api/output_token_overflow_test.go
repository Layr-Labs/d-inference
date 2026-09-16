package api

import (
	"bytes"
	"encoding/json"
	"io"
	"math"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestGenericOutputTokenOverflowCannotBypassKeyQuota(t *testing.T) {
	for _, endpoint := range []string{"/v1/completions", "/v1/messages"} {
		t.Run(endpoint, func(t *testing.T) {
			st := store.NewMemory(store.Config{})
			seedActiveModel(t, st, "test-model", "test-model")
			limit := int64(100)
			rawKey, _, err := st.CreateAPIKey("test-account", store.APIKeyCreate{OTPMLimit: &limit})
			if err != nil {
				t.Fatal(err)
			}
			logger := quietLogger()
			srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
			t.Cleanup(srv.Close)
			srv.SetKeyLimiters(nil, ratelimit.NewKeyTokenLimiter())
			srv.SyncModelCatalog()
			ts := httptest.NewServer(srv.Handler())
			t.Cleanup(ts.Close)
			client := ts.Client()
			client.Timeout = 5 * time.Second
			body := map[string]any{"model": "test-model"}
			if endpoint == "/v1/completions" {
				body["prompt"] = "Hello"
			} else {
				body["messages"] = []any{map[string]any{"role": "user", "content": "Hello"}}
			}
			for _, tc := range []struct {
				name              string
				copies, maxTokens int
				status            int
				quotaRejected     bool
			}{
				// The limiter admits at most one burst per request, even when
				// its estimate is larger. Spend half a burst first so a normal
				// oversized estimate is refused while a wrapped value fits.
				{"spend_half_burst", 1, 50, http.StatusTooManyRequests, false},
				{"ordinary_over_quota", 1, 101, http.StatusTooManyRequests, true},
				{"negative_wrap", math.MaxInt, 2, http.StatusBadRequest, false},
				{"positive_wrap", math.MaxInt/2 + 2, 4, http.StatusBadRequest, false},
			} {
				t.Run(tc.name, func(t *testing.T) {
					body["n"], body["max_tokens"] = tc.copies, tc.maxTokens
					data, err := json.Marshal(body)
					if err != nil {
						t.Fatal(err)
					}
					req, err := http.NewRequest(http.MethodPost, ts.URL+endpoint, bytes.NewReader(data))
					if err != nil {
						t.Fatal(err)
					}
					req.Header.Set("Authorization", "Bearer "+rawKey)
					req.Header.Set("Content-Type", "application/json")
					resp, err := client.Do(req)
					if err != nil {
						t.Fatal(err)
					}
					defer resp.Body.Close()
					response, err := io.ReadAll(resp.Body)
					if err != nil {
						t.Fatal(err)
					}
					quotaRejected := strings.Contains(string(response), "output_tokens")
					if resp.StatusCode != tc.status || quotaRejected != tc.quotaRejected {
						t.Fatalf("quotaRejected=%v, want %v: status=%d body=%s", quotaRejected, tc.quotaRejected, resp.StatusCode, response)
					}
				})
			}
		})
	}
}
