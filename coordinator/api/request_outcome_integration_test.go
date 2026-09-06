package api

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

func awaitRequestOutcomes(t *testing.T, s store.RequestOutcomeStore, n int) []store.RequestOutcomeRecord {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		rows, err := s.RequestOutcomes(context.Background(), time.Time{}, time.Now().Add(time.Second), 100)
		if err != nil {
			t.Fatal(err)
		}
		done := len(rows) == n
		for _, r := range rows {
			done = done && r.FinalizedAt != nil
		}
		if done {
			return rows
		}
		if time.Now().After(deadline) {
			t.Fatalf("request ledger did not settle: %+v", rows)
		}
		time.Sleep(10 * time.Millisecond)
	}
}
func nativeOutcomeBody(endpoint, model string, stream bool) string {
	switch endpoint {
	case "/v1/responses":
		return fmt.Sprintf(`{"model":%q,"input":"hello","stream":%t,"max_output_tokens":16}`, model, stream)
	case "/v1/completions":
		return fmt.Sprintf(`{"model":%q,"prompt":"hello","stream":%t,"max_tokens":16}`, model, stream)
	default:
		return fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":"hello"}],"stream":%t,"max_tokens":16}`, model, stream)
	}
}

var outcomeEndpoints = []string{"/v1/chat/completions", "/v1/responses", "/v1/completions", "/v1/messages"}

func TestRequestOutcomesAllEndpointsWithoutProfiler(t *testing.T) {
	t.Setenv(envProfiler, "off")
	reg, st, srv, ts := setupTTFTFailoverServer(t)
	t.Cleanup(srv.Close)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	const model = "request-outcome-model"
	startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{Name: "outcome-provider", Version: "0.8.10", DecodeTPS: 200, Models: []failoverModelSpec{{ID: model}}, Script: func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
		fp.serveFull(ctx, req, model, "observed answer")
	}})
	count := 0
	ids := map[string]bool{}
	for _, endpoint := range outcomeEndpoints {
		for _, stream := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/%t", endpoint, stream), func(t *testing.T) {
				req, _ := http.NewRequestWithContext(ctx, "POST", ts.URL+endpoint, strings.NewReader(nativeOutcomeBody(endpoint, model, stream)))
				req.Header.Set("Authorization", "Bearer test-key")
				req.Header.Set("Content-Type", "application/json")
				req.Header.Set("X-Request-ID", "client-controlled-same-id")
				res, err := http.DefaultClient.Do(req)
				if err != nil {
					t.Fatal(err)
				}
				body, _ := io.ReadAll(res.Body)
				res.Body.Close()
				if res.StatusCode != 200 {
					t.Fatalf("%d %s", res.StatusCode, body)
				}
				if strings.Contains(res.Header.Get("X-Timing"), "pre_handler_us") {
					t.Fatal("profiler-off header changed")
				}
				count++
				rows := awaitRequestOutcomes(t, st, count)
				r := rows[len(rows)-1]
				if r.Termination != "completed" || r.ProviderOutcome != "completed" || !r.EgressCompleted || !r.ContentWriteCompleted || !r.ProviderContentObserved {
					t.Fatalf("completion evidence missing: %+v body=%s", r, body)
				}
				if r.Endpoint != endpoint || r.Stream == nil || *r.Stream != stream || r.CoordRequestID == "client-controlled-same-id" || ids[r.CoordRequestID] {
					t.Fatalf("identity/mode %+v", r)
				}
				ids[r.CoordRequestID] = true
				sent := 0
				for _, a := range r.Attempts {
					if a.WriteCompleted {
						sent++
					}
				}
				if sent != 1 {
					t.Fatalf("dispatch count=%d %+v", sent, r)
				}
			})
		}
	}
	if n := len(st.RequestProfilesSince(time.Time{})); n != 0 {
		t.Fatalf("disabled profiler wrote %d heavy profiles", n)
	}
}

func TestRequestOutcomesAllEarlyExits(t *testing.T) {
	t.Setenv(envProfiler, "off")
	_, st, srv, ts := setupTTFTFailoverServer(t)
	t.Cleanup(srv.Close)
	count := 0
	for _, endpoint := range outcomeEndpoints {
		for _, stream := range []bool{false, true} {
			for _, kind := range []string{"auth", "validation", "drain", "sealed_transport"} {
				t.Run(fmt.Sprintf("%s/%t/%s", endpoint, stream, kind), func(t *testing.T) {
					body := nativeOutcomeBody(endpoint, "missing", stream)
					if kind == "validation" {
						body = "{"
					}
					req, _ := http.NewRequest("POST", ts.URL+endpoint, strings.NewReader(body))
					req.Header.Set("Content-Type", "application/json")
					if kind != "auth" {
						req.Header.Set("Authorization", "Bearer test-key")
					}
					if kind == "drain" {
						srv.SetDraining(true)
						defer srv.SetDraining(false)
					}
					if kind == "sealed_transport" {
						req.Header.Set("Content-Type", SealedContentType)
					}
					res, err := http.DefaultClient.Do(req)
					if err != nil {
						t.Fatal(err)
					}
					io.Copy(io.Discard, res.Body)
					res.Body.Close()
					if res.StatusCode < 400 {
						t.Fatalf("unexpected %d", res.StatusCode)
					}
					count++
					rows := awaitRequestOutcomes(t, st, count)
					r := rows[len(rows)-1]
					if r.Termination != "rejected" || r.HTTPStatus != res.StatusCode || r.RawStage != kind || r.AttemptsTotal != 0 || r.ContentWriteCompleted || r.EgressCompleted {
						t.Fatalf("early exit %+v", r)
					}
				})
			}
		}
	}
}

func TestRequestOutcomesProviderErrorAfterContentAllEndpoints(t *testing.T) {
	for _, endpoint := range outcomeEndpoints {
		for _, stream := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/%t", endpoint, stream), func(t *testing.T) {
				t.Setenv(envProfiler, "off")
				reg, st, srv, ts := setupTTFTFailoverServer(t)
				t.Cleanup(srv.Close)
				ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
				defer cancel()
				const model = "outcome-error-model"
				startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{Name: "error-provider", Version: "0.8.10", DecodeTPS: 200, Models: []failoverModelSpec{{ID: model}}, Script: func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
					fp.sendContentChunk(ctx, req, model, "some content")
					time.Sleep(30 * time.Millisecond)
					fp.sendInferenceError(ctx, req, "provider failed", 500)
				}})
				req, _ := http.NewRequestWithContext(ctx, "POST", ts.URL+endpoint, strings.NewReader(nativeOutcomeBody(endpoint, model, stream)))
				req.Header.Set("Authorization", "Bearer test-key")
				req.Header.Set("Content-Type", "application/json")
				res, err := http.DefaultClient.Do(req)
				if err != nil {
					t.Fatal(err)
				}
				io.Copy(io.Discard, res.Body)
				res.Body.Close()
				r := awaitRequestOutcomes(t, st, 1)[0]
				want := "rejected"
				if stream {
					want = "interrupted_response"
				}
				if r.Termination != want || r.ProviderOutcome != "error" || !r.ProviderContentObserved || r.ContentWriteCompleted != stream || r.EgressCompleted {
					t.Fatalf("error evidence %+v", r)
				}
			})
		}
	}
}

func TestRequestOutcomesZeroTokenCompletionAllEndpoints(t *testing.T) {
	reg, st, srv, ts := setupTTFTFailoverServer(t)
	t.Cleanup(srv.Close)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	const model = "zero-outcome-model"
	startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{Name: "empty-provider", Version: "0.8.10", DecodeTPS: 200, Models: []failoverModelSpec{{ID: model}}, Script: func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
		fp.sendComplete(ctx, req, protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 0})
	}})
	count := 0
	for _, endpoint := range outcomeEndpoints {
		for _, stream := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/%t", endpoint, stream), func(t *testing.T) {
				req, _ := http.NewRequestWithContext(ctx, "POST", ts.URL+endpoint, strings.NewReader(nativeOutcomeBody(endpoint, model, stream)))
				req.Header.Set("Authorization", "Bearer test-key")
				res, err := http.DefaultClient.Do(req)
				if err != nil {
					t.Fatal(err)
				}
				body, _ := io.ReadAll(res.Body)
				res.Body.Close()
				if res.StatusCode != 200 {
					t.Fatalf("zero completion %d %s", res.StatusCode, body)
				}
				count++
				r := awaitRequestOutcomes(t, st, count)[count-1]
				if r.Termination != "completed" || r.ProviderOutcome != "completed" || !r.EgressCompleted || r.ProviderContentObserved || r.ContentWriteCompleted {
					t.Fatalf("zero-token evidence %+v", r)
				}
			})
		}
	}
}

func TestRequestOutcomesRateLimitAllEndpoints(t *testing.T) {
	for _, endpoint := range outcomeEndpoints {
		for _, stream := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/%t", endpoint, stream), func(t *testing.T) {
				_, st, srv, ts := setupTTFTFailoverServer(t)
				t.Cleanup(srv.Close)
				key, err := st.CreateKey()
				if err != nil {
					t.Fatal(err)
				}
				limiter := ratelimit.New(ratelimit.Config{RPS: .001, Burst: 1})
				limiter.Allow(store.LegacyAccountID(key))
				srv.SetRateLimiter(limiter)
				req, _ := http.NewRequest("POST", ts.URL+endpoint, strings.NewReader(nativeOutcomeBody(endpoint, "m", stream)))
				req.Header.Set("Authorization", "Bearer "+key)
				res, err := http.DefaultClient.Do(req)
				if err != nil {
					t.Fatal(err)
				}
				io.Copy(io.Discard, res.Body)
				res.Body.Close()
				r := awaitRequestOutcomes(t, st, 1)[0]
				if r.HTTPStatus != 429 || r.Termination != "rejected" || r.RawStage != "rate_limit" || r.AttemptsTotal != 0 {
					t.Fatalf("rate limit %+v", r)
				}
			})
		}
	}
}

func TestRequestOutcomesBalanceModelAndPreflightAllEndpoints(t *testing.T) {
	for _, stage := range []string{"balance", "model_resolution", "preflight_capacity"} {
		t.Run(stage, func(t *testing.T) {
			reg, st, srv, ts := setupTTFTFailoverServer(t)
			t.Cleanup(srv.Close)
			reg.SetModelCatalog([]registry.CatalogEntry{{ID: "known-outcome-model"}})
			if stage == "balance" {
				srv.SetBilling(billing.NewService(st, srv.ledger, srv.logger, billing.Config{MockMode: true}))
			}
			count := 0
			for _, endpoint := range outcomeEndpoints {
				for _, stream := range []bool{false, true} {
					t.Run(fmt.Sprintf("%s/%t", endpoint, stream), func(t *testing.T) {
						model := "known-outcome-model"
						if stage == "model_resolution" {
							model = "missing-outcome-model"
						}
						req, _ := http.NewRequest("POST", ts.URL+endpoint, strings.NewReader(nativeOutcomeBody(endpoint, model, stream)))
						req.Header.Set("Authorization", "Bearer test-key")
						res, err := http.DefaultClient.Do(req)
						if err != nil {
							t.Fatal(err)
						}
						io.Copy(io.Discard, res.Body)
						res.Body.Close()
						count++
						r := awaitRequestOutcomes(t, st, count)[count-1]
						if r.Termination != "rejected" || r.RawStage != stage || r.AttemptsTotal != 0 || r.ContentWriteCompleted {
							t.Fatalf("%s evidence %+v", stage, r)
						}
					})
				}
			}
		})
	}
}

// Accounting identity is independent without changing the public correlation header.
func TestRequestOutcomeInferenceIdentityPreservesHeader(t *testing.T) {
	t.Setenv(envProfiler, "off")
	srv := &Server{logger: quietLogger()}
	seen := make(map[string]bool)
	for _, endpoint := range outcomeEndpoints {
		for _, supplied := range []string{"", "client-id"} {
			var canonical, logged string
			h := srv.loggingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				canonical = coordRequestIDFromContext(r.Context())
				logged = requestIDFromContext(r.Context())
				w.WriteHeader(http.StatusNoContent)
			}))
			req := httptest.NewRequest(http.MethodPost, endpoint, nil)
			req.Header.Set("X-Request-ID", supplied)
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			public := rec.Header().Get("X-Request-ID")
			if public != logged || (supplied != "" && public != supplied) || (supplied == "" && len(public) != 12) {
				t.Fatalf("public correlation changed: supplied=%q header=%q log=%q", supplied, public, logged)
			}
			if _, err := uuid.Parse(canonical); err != nil || canonical == public || seen[canonical] {
				t.Fatalf("canonical identity not independent: %q, %v", canonical, err)
			}
			seen[canonical] = true
		}
	}
}
