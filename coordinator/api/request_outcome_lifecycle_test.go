package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/outcomes"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"nhooyr.io/websocket"
)

func TestRequestAccountingMiddlewareRateLimitAndDrain(t *testing.T) {
	t.Setenv(envProfiler, "off")
	_, st, srv, _ := setupTTFTFailoverServer(t)
	t.Cleanup(srv.Close)
	key, err := st.CreateKey()
	if err != nil {
		t.Fatal(err)
	}
	srv.SetRateLimiter(ratelimit.New(ratelimit.Config{RPS: 0.001, Burst: 1}))
	for _, expected := range []int{400, 429} {
		r := httptest.NewRequest(http.MethodPost, "/v1/completions", strings.NewReader(`invalid`))
		r.Header.Set("Authorization", "Bearer "+key)
		w := httptest.NewRecorder()
		srv.Handler().ServeHTTP(w, r)
		if w.Code != expected {
			t.Fatalf("expected%d, got%d: %s", expected, w.Code, w.Body.String())
		}
	}
	srv.SetDraining(true)
	r := httptest.NewRequest(http.MethodPost, "/v1/responses", nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, r)
	if w.Code != 429 {
		t.Fatalf("drain status%d", w.Code)
	}
	for _, row := range waitRequestOutcome(t, st, 3) {
		if row.Termination != "rejected" || row.AttemptCount != 0 || row.DispatchedAttemptCount != 0 || row.ResponseEgressCompleted {
			t.Fatalf("pre-handler outcome: %+v", row)
		}
	}
}

func TestRequestAccountingParkedProviderCompletionRetainsDeparture(t *testing.T) {
	srv, st, _ := billingTestServer(t)
	t.Cleanup(srv.Close)
	srv.settleGrace = time.Second
	provider := srv.registry.Register("accounting-parked", nil, &protocol.RegisterMessage{Models: []protocol.ModelInfo{{ID: "parked", ModelType: "chat"}}})
	tracker := outcomes.New("parked-coordinator", "/v1/chat/completions", time.Now(), srv.requestOutcomes.submit)
	a := tracker.NewAttempt("parked-attempt", 0, "")
	a.Observe("write_completed", "", 0)
	a.Observe("content", "", 0)
	a.Observe("committed", "", 0)
	tracker.ContentWritten()
	tracker.Finish(200, true, false)
	pr := &registry.PendingRequest{RequestID: "parked-attempt", Accounting: a, Model: "parked", ConsumerKey: testConsumerID, ChunkCh: make(chan registry.ProviderChunk, 1), CompleteCh: make(chan protocol.UsageInfo, 1), ErrorCh: make(chan protocol.InferenceErrorMessage, 1)}
	parkConsumerGone(srv, provider, pr)
	srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{Type: protocol.TypeInferenceComplete, RequestID: pr.RequestID, Usage: protocol.UsageInfo{PromptTokens: 1, CompletionTokens: 1}})
	row := waitRequestOutcome(t, st, 1)[0]
	if row.Termination != "client_departure" || row.ProviderOutcome != "completed" || !row.ClientDeparted || !row.ContentEgressObserved || row.ResponseEgressCompleted || !row.ObservedAt.After(*row.FinalizedAt) {
		t.Fatalf("late completion lost independent departure: %+v", row)
	}
}

func TestRequestAccountingTypedProviderTimeoutVersusCoordinatorTimeout(t *testing.T) {
	for _, typed := range []bool{false, true} {
		name := "coordinator"
		if typed {
			name = "provider"
		}
		t.Run(name, func(t *testing.T) {
			reg, st, srv, ts := setupTTFTFailoverServerWithConfig(t, ServerConfig{FirstContentDeadlineBase: 200 * time.Millisecond})
			t.Cleanup(srv.Close)
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			const model = "accounting-timeout-model"
			startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{Name: "timeout-provider", Version: "0.8.10", Models: []failoverModelSpec{{ID: model}}, Script: func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
				if !typed {
					return
				}
				msg := protocol.InferenceErrorMessage{Type: protocol.TypeInferenceError, RequestID: req.RequestID, StatusCode: 504, FailureCode: protocol.FailureCodeGenerationFailure, TerminalCause: terminalCauseSafetyDeadline, ErrorReason: errorReasonProviderError}
				data, _ := json.Marshal(msg)
				if err := fp.conn.Write(ctx, websocket.MessageText, data); err != nil {
					t.Error(err)
				}
			}})
			status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, false, nil))
			if err != nil {
				t.Fatal(err)
			}
			want := 429
			code := "ext_first_content_timeout"
			if typed {
				want = 504
				code = ""
			}
			if status != want {
				t.Fatalf("status%d want%d: %s", status, want, body)
			}
			row := waitRequestOutcome(t, st, 1)[0]
			if row.Termination != "rejected" || row.NormalizedCode != code || row.DeadlineRefusalCount != 0 {
				t.Fatalf("timeout scope: %+v", row)
			}
		})
	}
}
