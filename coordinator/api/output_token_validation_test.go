package api

import (
	"bytes"
	"encoding/json"
	"io"
	"math"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestGenericOutputTokenOverflowRejectedBeforeAdmission(t *testing.T) {
	for _, endpoint := range []string{"/v1/completions", "/v1/messages"} {
		for _, quota := range []string{"full", "unlimited"} {
			for _, tc := range []struct {
				name              string
				copies, maxTokens int
			}{
				{"negative_wrap", math.MaxInt, 2},
				{"positive_wrap", math.MaxInt/2 + 2, 4},
				{"default_limit", math.MaxInt, 0},
			} {
				t.Run(endpoint+"/"+quota+"/"+tc.name, func(t *testing.T) {
					srv, st := testBillingServer(t)
					t.Cleanup(srv.Close)
					seedActiveModel(t, st, "test-model", "test-model")
					limit := int64(100)
					if quota == "unlimited" {
						limit = 0
					}
					rawKey, _, err := st.CreateAPIKey("test-account", store.APIKeyCreate{OTPMLimit: &limit})
					if err != nil {
						t.Fatal(err)
					}
					if err := st.Credit("test-account", 1_000_000, store.LedgerDeposit, "fixture"); err != nil {
						t.Fatal(err)
					}
					srv.SetKeyLimiters(nil, ratelimit.NewKeyTokenLimiter())
					srv.SyncModelCatalog()
					ts := httptest.NewServer(srv.Handler())
					t.Cleanup(ts.Close)
					client := ts.Client()
					client.Timeout = 5 * time.Second
					body := map[string]any{"model": "test-model", "n": tc.copies}
					if endpoint == "/v1/completions" {
						body["prompt"] = "Hello"
					} else {
						body["messages"] = []any{map[string]any{"role": "user", "content": "Hello"}}
					}
					if tc.maxTokens > 0 {
						body["max_tokens"] = tc.maxTokens
					}
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
					var payload struct {
						Error struct{ Type, Param string }
					}
					if err := json.Unmarshal(response, &payload); err != nil {
						t.Fatal(err)
					}
					if resp.StatusCode != http.StatusBadRequest || payload.Error.Type != "invalid_request_error" || payload.Error.Param != "n" {
						t.Errorf("overflow must fail before admission: status=%d body=%s", resp.StatusCode, response)
					}
					// A refunded reservation still appends ledger records. Require
					// no billing mutation at all, even with a full quota bucket.
					if entries := st.LedgerHistory("test-account"); len(entries) != 1 || entries[0].Type != store.LedgerDeposit {
						t.Errorf("overflow reached billing: ledger=%+v", entries)
					}
				})
			}
		}
	}
}
