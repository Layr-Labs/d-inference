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

	"github.com/eigeninference/d-inference/coordinator/outcomes"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func waitRequestOutcome(t *testing.T, st *store.MemoryStore, count int) []outcomes.Record {
	t.Helper()
	until := time.Now().Add(3 * time.Second)
	for {
		rows, err := st.RequestOutcomesBetween(context.Background(), time.Time{}, time.Now().Add(time.Minute), 100)
		if err != nil {
			t.Fatal(err)
		}
		ready := len(rows) == count
		for _, r := range rows {
			ready = ready && r.FinalizedAt != nil
		}
		if ready {
			return rows
		}
		if time.Now().After(until) {
			t.Fatalf("outcomes did not settle: %+v", rows)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestRequestAccountingAllEndpointsWithProfilerDisabled(t *testing.T) {
	t.Setenv(envProfiler, "off")
	for _, endpoint := range []string{"/v1/chat/completions", "/v1/responses", "/v1/completions", "/v1/messages"} {
		for _, stream := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/stream=%t", endpoint, stream), func(t *testing.T) {
				reg, st, srv, ts := setupTTFTFailoverServer(t)
				t.Cleanup(srv.Close)
				ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
				defer cancel()
				const model = "accounting-model"
				startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
					Name: "accounting-provider", Version: "0.8.10", Models: []failoverModelSpec{{ID: model}},
					Script: fullServeScript(model),
				})
				shape := `"messages":[{"role":"user","content":"hello"}]`
				switch endpoint {
				case "/v1/responses":
					shape = `"input":"hello"`
				case "/v1/completions":
					shape = `"prompt":"hello"`
				}
				body := fmt.Sprintf(`{"model":%q,"stream":%t,"max_tokens":64,%s}`, model, stream, shape)
				r, err := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+endpoint, strings.NewReader(body))
				if err != nil {
					t.Fatal(err)
				}
				r.Header.Set("Authorization", "Bearer test-key")
				r.Header.Set("X-Request-ID", "untrusted-repeated-client-id")
				response, err := http.DefaultClient.Do(r)
				if err != nil {
					t.Fatal(err)
				}
				output, _ := io.ReadAll(response.Body)
				response.Body.Close()
				if response.StatusCode != 200 {
					t.Fatalf("status=%d body=%s", response.StatusCode, output)
				}
				row := waitRequestOutcome(t, st, 1)[0]
				if row.CoordRequestID == "" || row.CoordRequestID == "untrusted-repeated-client-id" {
					t.Fatalf("untrusted identity: %+v", row)
				}
				if row.Termination != "completed" || row.ResponseProgress != "completion_confirmed" || row.ProviderOutcome != "completed" || !row.ResponseEgressCompleted || !row.ContentEgressObserved {
					t.Fatalf("completion evidence: %+v", row)
				}
				if row.Stream == nil || *row.Stream != stream || row.Endpoint != endpoint || row.AttemptCount != 1 || row.DispatchedAttemptCount != 1 || len(row.Attempts) != 1 || !row.Attempts[0].Winning {
					t.Fatalf("request/attempt shape: %+v", row)
				}
				if len(st.RequestProfilesSince(time.Time{})) != 0 {
					t.Fatal("accounting enabled sampled profiler")
				}
			})
		}
	}
}

func TestRequestAccountingEarlyExitsAndClientIdentity(t *testing.T) {
	t.Setenv(envProfiler, "off")
	_, st, srv, _ := setupTTFTFailoverServer(t)
	t.Cleanup(srv.Close)
	for _, endpoint := range []string{"/v1/chat/completions", "/v1/responses", "/v1/completions", "/v1/messages"} {
		for _, auth := range []bool{false, true} {
			r := httptest.NewRequest(http.MethodPost, endpoint, strings.NewReader(`invalid json`))
			r.Header.Set("X-Request-ID", "same-client-id")
			if auth {
				r.Header.Set("Authorization", "Bearer test-key")
			}
			w := httptest.NewRecorder()
			srv.Handler().ServeHTTP(w, r)
			want := 401
			if auth {
				want = 400
			}
			if w.Code != want {
				t.Fatalf("%s auth=%t code=%d", endpoint, auth, w.Code)
			}
		}
	}
	rows := waitRequestOutcome(t, st, 8)
	seen := map[string]bool{}
	for _, r := range rows {
		if seen[r.CoordRequestID] || r.CoordRequestID == "same-client-id" || r.Termination != "rejected" || r.AttemptCount != 0 || r.DispatchedAttemptCount != 0 {
			t.Fatalf("early rejection: %+v", r)
		}
		seen[r.CoordRequestID] = true
	}
}

func TestRequestAccountingRefusalThenRecovery(t *testing.T) {
	t.Setenv(envProfileSampleRate, "0")
	reg, st, srv, ts := setupTTFTFailoverServer(t)
	t.Cleanup(srv.Close)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	const model = "accounting-recovery-model"
	recorder := &deadlineAttemptRecorder{}
	script := func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
		if recorder.capture(t, reg, fp, req) == 1 {
			fp.sendTypedInferenceError(ctx, req, protocol.FailureCodeCapacity, errorReasonDeadlineUnreachable, 503)
			return
		}
		fp.serveFull(ctx, req, model, "completed")
	}
	for _, name := range []string{"a", "b"} {
		startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{Name: name, Version: "0.8.10", Models: []failoverModelSpec{{ID: model}}, Script: script})
	}
	status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil || status != 200 {
		t.Fatalf("request: %d %s %v", status, body, err)
	}
	r := waitRequestOutcome(t, st, 1)[0]
	if r.Termination != "completed" || r.DeadlineRefusalCount != 1 || r.DispatchedAttemptCount != 2 || r.NormalizedCode != "" {
		t.Fatalf("recovery: %+v", r)
	}
	if r.Attempts[0].NormalizedCode != "int_provider_deadline_rejected" || r.Attempts[0].HTTPStatus == nil || *r.Attempts[0].HTTPStatus != 503 {
		t.Fatalf("refusal lost: %+v", r.Attempts)
	}
	if r.Attempts[1].RequestID == r.Attempts[0].RequestID {
		t.Fatal("attempts collapsed")
	}
}

func TestRequestAccountingPostContentErrorAcrossAdapters(t *testing.T) {
	t.Setenv(envProfiler, "off")
	for _, endpoint := range []string{"/v1/chat/completions", "/v1/responses", "/v1/completions", "/v1/messages"} {
		for _, stream := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/stream=%t", endpoint, stream), func(t *testing.T) {
				reg, st, srv, ts := setupTTFTFailoverServer(t)
				t.Cleanup(srv.Close)
				ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
				defer cancel()
				const model = "accounting-post-content-error"
				startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
					Name: "broken-provider", Version: "0.8.10", Models: []failoverModelSpec{{ID: model}},
					Script: func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
						fp.sendContentChunk(ctx, req, model, "partial output")
						time.Sleep(30 * time.Millisecond)
						fp.sendInferenceError(ctx, req, "provider kernel failed", 500)
					},
				})
				shape := `"messages":[{"role":"user","content":"hello"}]`
				switch endpoint {
				case "/v1/responses":
					shape = `"input":"hello"`
				case "/v1/completions":
					shape = `"prompt":"hello"`
				}
				body := fmt.Sprintf(`{"model":%q,"stream":%t,"max_tokens":64,%s}`, model, stream, shape)
				status, output, err := postGenericInference(ctx, ts.URL, endpoint, body)
				if err != nil {
					t.Fatal(err)
				}
				wantStatus := 500
				if stream {
					wantStatus = 200
				}
				if status != wantStatus {
					t.Fatalf("status=%d body=%s", status, output)
				}
				r := waitRequestOutcome(t, st, 1)[0]
				if r.Termination == "completed" || r.ResponseProgress != "content_observed" || r.ProviderOutcome != "error" || r.ResponseEgressCompleted || r.ContentEgressObserved != stream {
					t.Fatalf("interrupted progress conflates ingress/egress: %+v", r)
				}
				if r.NormalizedCode != "" {
					t.Fatalf("mid-response error became pre-content timeout: %+v", r)
				}
			})
		}
	}
}
