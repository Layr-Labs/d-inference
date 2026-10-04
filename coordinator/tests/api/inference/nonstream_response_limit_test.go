package inference_test

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/estimate"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/responselimit"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// responseLimitServer composes a server whose deployment configuration sets the
// non-streaming limits, and funds the test consumer like billingTestServer.
func responseLimitServer(t *testing.T, limits responselimit.Limits) (*serverFixture, *payments.Ledger) {
	t.Helper()
	srv, st := testServerWithConfig(t, TestServerConfig{
		NonStreamingResponseMaxBytes:  limits.MaxBytes,
		NonStreamingResponseMaxChunks: limits.MaxChunks,
	})
	if err := st.Credit(testConsumerID, 100_000_000, store.LedgerDeposit, "test-setup"); err != nil {
		t.Fatal(err)
	}
	return srv, srv.ledger
}

func TestNonStreamingResponseLimitAssembly(t *testing.T) {
	const chunk = `data: {"choices":[{"delta":{"content":"ok","reasoning_content":"think"}}]}`
	for _, tc := range []struct {
		name                 string
		first                []string
		rest                 []string
		bytes, count, status int
	}{
		{"normal", nil, []string{chunk}, len(chunk) + 1, 2, 200},
		{"at byte limit", []string{chunk}, nil, len(chunk), 2, 200},
		{"oversized first", []string{chunk}, nil, len(chunk) - 1, 2, 502},
		{"aggregate", []string{chunk}, []string{chunk}, len(chunk)*2 - 1, 3, 502},
		{"at count limit", []string{chunk}, []string{chunk}, len(chunk) * 2, 2, 200},
		{"empty frames", nil, []string{"", "", ""}, 100, 2, 502},
		{"malformed frames", nil, []string{"x", "x", "x"}, 100, 2, 502},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srv, ledger := responseLimitServer(t, responselimit.Limits{MaxBytes: tc.bytes, MaxChunks: tc.count})
			initial := ledger.Balance(testConsumerID)
			if err := ledger.Charge(testConsumerID, 25000, "reserve"); err != nil {
				t.Fatal(err)
			}
			pr := &registry.PendingRequest{RequestID: "limit", Model: "test-model", ConsumerKey: testConsumerID, ReservedMicroUSD: 25000, ChunkCh: make(chan registry.ProviderChunk, len(tc.rest)), CompleteCh: make(chan protocol.UsageInfo, 1), ErrorCh: make(chan protocol.InferenceErrorMessage, 1)}
			for _, c := range tc.rest {
				pr.ChunkCh <- registry.ProviderChunk{Data: c}
			}
			close(pr.ChunkCh)
			pr.CompleteCh <- protocol.UsageInfo{CompletionTokens: 1}
			rr := httptest.NewRecorder()
			srv.NewRelay().NonStream(rr, httptest.NewRequest("POST", "/v1/chat/completions", nil), pr, tc.first, nil)
			if rr.Code != tc.status {
				t.Fatalf("status %d want %d: %s", rr.Code, tc.status, rr.Body.String())
			}
			if tc.status == 502 {
				if ledger.Balance(testConsumerID) != initial {
					t.Fatal("reservation not refunded")
				}
				if srv.reservations.Refund(pr, "duplicate") {
					t.Fatal("duplicate refund")
				}
			} else if !strings.Contains(rr.Body.String(), "think") || !strings.Contains(rr.Body.String(), "ok") {
				t.Fatalf("content/reasoning lost: %s", rr.Body.String())
			}
		})
	}
}

func TestNonStreamingResponseLimitIngressBeforeCompletion(t *testing.T) {
	for _, tc := range []struct {
		name         string
		bytes, count int
		chunks       []string
	}{
		{"first byte overflow", 3, 10, []string{"1234"}},
		{"aggregate bytes", 4, 10, []string{"12", "34", "5"}},
		{"empty count", 10, 2, []string{"", "", ""}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srv, _, ledger := billingTestServer(t)
			initial := ledger.Balance(testConsumerID)
			if err := ledger.Charge(testConsumerID, 25000, "reserve"); err != nil {
				t.Fatal(err)
			}
			pub := testPublicKeyB64()
			p := srv.registry.Register("limit-provider", nil, &protocol.RegisterMessage{Type: protocol.TypeRegister, PublicKey: pub, EncryptedResponseChunks: true, PrivacyCapabilities: testPrivacyCaps()})
			keys, err := e2e.GenerateSessionKeys()
			if err != nil {
				t.Fatal(err)
			}
			pr := &registry.PendingRequest{RequestID: "limit-ingress", ProviderID: p.ID, Model: "test-model", ConsumerKey: testConsumerID, ReservedMicroUSD: 25000, NonStreamingResponseBudget: registry.NewResponseBudget(tc.bytes, tc.count), SessionPrivKey: &keys.PrivateKey, ChunkCh: make(chan registry.ProviderChunk, 8), CompleteCh: make(chan protocol.UsageInfo, 1), ErrorCh: make(chan protocol.InferenceErrorMessage, 1)}
			p.AddPending(pr)
			for _, data := range tc.chunks {
				c := testEncryptedChunk(t, protocol.InferenceRequestMessage{RequestID: pr.RequestID, EncryptedBody: &protocol.EncryptedPayload{EphemeralPublicKey: base64.StdEncoding.EncodeToString(keys.PublicKey[:])}}, pub, data)
				srv.HandleChunk(p.ID, p, &c)
			}
			if p.GetPending(pr.RequestID) != nil {
				t.Fatal("oversized attempt still pending")
			}
			if len(pr.ChunkCh) != len(tc.chunks)-1 {
				t.Fatalf("rejected chunk retained: %d", len(pr.ChunkCh))
			}
			// A completion queued immediately after overflow must not turn into success
			// or settle usage while the non-streaming consumer has not drained yet.
			srv.HandleCompleteAt(p.ID, p, &protocol.InferenceCompleteMessage{RequestID: pr.RequestID}, time.Now())
			rr := httptest.NewRecorder()
			srv.NewRelay().NonStream(rr, httptest.NewRequest("POST", "/v1/chat/completions", nil), pr, nil, nil)
			if rr.Code != http.StatusBadGateway {
				t.Fatalf("status %d: %s", rr.Code, rr.Body.String())
			}
			if ledger.Balance(testConsumerID) != initial {
				t.Fatal("reservation not refunded exactly once")
			}
			srv.HandleCompleteAt(p.ID, p, &protocol.InferenceCompleteMessage{RequestID: pr.RequestID}, time.Now())
			if srv.reservations.Refund(pr, "again") {
				t.Fatal("duplicate refund")
			}
			if ledger.Balance(testConsumerID) != initial {
				t.Fatal("late terminal changed balance")
			}
		})
	}
}

func TestNonStreamingResponseLimitCancelled(t *testing.T) {
	srv, _, _ := billingTestServer(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	pr := &registry.PendingRequest{RequestID: "cancelled", ChunkCh: make(chan registry.ProviderChunk), ErrorCh: make(chan protocol.InferenceErrorMessage)}
	srv.NewRelay().NonStream(httptest.NewRecorder(), httptest.NewRequest("POST", "/", nil).WithContext(ctx), pr, nil, nil)
}

func TestNonStreamingResponseLimitDispatchWiring(t *testing.T) {
	for _, stream := range []bool{false, true} {
		srv, _, _ := billingTestServer(t)
		exclusions := dispatch.NewExclusions()
		called := false
		srv.NewDispatcher().NewPlan(nil).Dispatch(dispatch.Input{
			Request: httptest.NewRequest("POST", "/", nil), Model: "test-model", Body: []byte(`{}`), Stream: stream,
			Exclusions: exclusions, Forecast: firstcontent.NewForecast(estimate.NewContextCalibration(), exclusions.Exclude),
		}, func(pr *registry.PendingRequest, _ []string) (*registry.Provider, registry.RoutingDecision, *registry.DispatchPlan) {
			called = true
			if (pr.NonStreamingResponseBudget == nil) != stream {
				t.Errorf("stream=%v: budget not installed correctly before reservation", stream)
			}
			return nil, registry.RoutingDecision{}, nil
		}, false)
		if !called {
			t.Fatal("dispatch did not reach reservation")
		}
	}
}

// The request's stream flag reaches a dispatched attempt only through the
// owner's dispatch input, so the observation is a real request: the pending
// attempt its provider is serving carries a budget unless the request streams.
func TestNonStreamingResponseLimitBudgetFollowsRequestStream(t *testing.T) {
	reg, _, ts := setupFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	const model = "response-limit-stream-model"
	budgeted := make(chan bool, 2)
	startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "response-limit-provider", Version: "0.8.10", DecodeTPS: 200,
		Models: []failoverModelSpec{{ID: model}},
		Script: func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
			pr := reg.GetProvider(fp.registryID).GetPending(req.RequestID)
			if pr == nil {
				t.Errorf("dispatched request %q has no pending attempt", req.RequestID)
			}
			budgeted <- pr != nil && pr.NonStreamingResponseBudget != nil
			fp.serveFull(ctx, req, model, "served")
		},
	})
	for _, stream := range []bool{false, true} {
		status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, stream, nil))
		if err != nil || status != http.StatusOK {
			t.Fatalf("stream=%v: status=%d err=%v body=%s", stream, status, err, body)
		}
		if got := <-budgeted; got == stream {
			t.Fatalf("stream=%v: dispatched attempt budgeted=%v", stream, got)
		}
	}
}

func TestNonStreamingResponseLimitCompleteObjectsAndEndpoints(t *testing.T) {
	raw := `{"object":"chat.completion","choices":[{"message":{"role":"assistant","content":"answer","reasoning_content":"reason","tool_calls":[{"id":"call1","type":"function","function":{"name":"lookup","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3}}`
	for _, endpoint := range []string{"/v1/chat/completions", inreq.CompletionsEndpoint, inreq.MessagesEndpoint, "/v1/responses"} {
		for _, over := range []bool{false, true} {
			limits := responselimit.Limits{MaxBytes: len(raw)}
			if over {
				limits.MaxBytes--
			}
			srv, _ := responseLimitServer(t, limits)
			pr := &registry.PendingRequest{RequestID: "complete-object", Model: "test-model", ConsumerEndpoint: endpoint, IsResponsesAPI: endpoint == "/v1/responses", ChunkCh: make(chan registry.ProviderChunk), ErrorCh: make(chan protocol.InferenceErrorMessage), CompleteCh: make(chan protocol.UsageInfo, 1)}
			close(pr.ChunkCh)
			pr.CompleteCh <- protocol.UsageInfo{PromptTokens: 1, CompletionTokens: 2}
			rr := httptest.NewRecorder()
			srv.NewRelay().NonStream(rr, httptest.NewRequest("POST", endpoint, nil), pr, []string{raw}, nil)
			want := 200
			if over {
				want = 502
			}
			if rr.Code != want {
				t.Fatalf("endpoint=%s over=%v status=%d body=%s", endpoint, over, rr.Code, rr.Body.String())
			}
			if !over && endpoint == "/v1/chat/completions" && (!strings.Contains(rr.Body.String(), "lookup") || !strings.Contains(rr.Body.String(), "reason") || !strings.Contains(rr.Body.String(), `"completion_tokens":2`)) {
				t.Fatalf("lost response fields: %s", rr.Body.String())
			}
		}
	}
}

func TestNonStreamingResponseLimitSendsCancelAndForgetsKey(t *testing.T) {
	srv, p, peer := dispatchAccountingProvider(t)
	pub := testPublicKeyB64()
	p.Mu().Lock()
	p.PublicKey = pub
	p.Mu().Unlock()
	keys, err := e2e.GenerateSessionKeys()
	if err != nil {
		t.Fatal(err)
	}
	pr := &registry.PendingRequest{RequestID: "wire-limit", ProviderID: p.ID, Model: dispatchAccountingModel, SessionPrivKey: &keys.PrivateKey, NonStreamingResponseBudget: registry.NewResponseBudget(1, 1), ChunkCh: make(chan registry.ProviderChunk, 1), CompleteCh: make(chan protocol.UsageInfo, 1), ErrorCh: make(chan protocol.InferenceErrorMessage, 1)}
	p.AddPending(pr)
	chunk := testEncryptedChunk(t, protocol.InferenceRequestMessage{RequestID: pr.RequestID, EncryptedBody: &protocol.EncryptedPayload{EphemeralPublicKey: base64.StdEncoding.EncodeToString(keys.PublicKey[:])}}, pub, "xx")
	srv.HandleChunk(p.ID, p, &chunk)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_, data, err := peer.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var message protocol.CancelMessage
	if err := json.Unmarshal(data, &message); err != nil {
		t.Fatal(err)
	}
	if message.Type != protocol.TypeCancel || message.RequestID != pr.RequestID {
		t.Fatalf("expected cancel, got %s", data)
	}
	retained := srv.chunkKeys.Contains(pr.SessionPrivKey)
	if retained {
		t.Fatal("decrypt key retained after terminal")
	}
	// The provider ignores cancellation: the next frame is a stray, not retained.
	srv.HandleChunk(p.ID, p, &chunk)
	if len(pr.ChunkCh) != 0 {
		t.Fatal("stray chunk retained")
	}
}

func TestNonStreamingResponseLimitDoesNotCapStreamingIngress(t *testing.T) {
	limits := responselimit.Limits{MaxBytes: 1, MaxChunks: 1}
	srv, _ := responseLimitServer(t, limits)
	pub := testPublicKeyB64()
	p := srv.registry.Register("streaming-provider", nil, &protocol.RegisterMessage{Type: protocol.TypeRegister, PublicKey: pub, EncryptedResponseChunks: true, PrivacyCapabilities: testPrivacyCaps()})
	keys, err := e2e.GenerateSessionKeys()
	if err != nil {
		t.Fatal(err)
	}
	pr := &registry.PendingRequest{RequestID: "streaming", ProviderID: p.ID, Model: "test-model", SessionPrivKey: &keys.PrivateKey, NonStreamingResponseBudget: limits.NewBudget(true), ChunkCh: make(chan registry.ProviderChunk, 2), ErrorCh: make(chan protocol.InferenceErrorMessage, 1)}
	p.AddPending(pr)
	const data = `data: {"choices":[{"delta":{"content":"unaffected"}}]}`
	chunk := testEncryptedChunk(t, protocol.InferenceRequestMessage{RequestID: pr.RequestID, EncryptedBody: &protocol.EncryptedPayload{EphemeralPublicKey: base64.StdEncoding.EncodeToString(keys.PublicKey[:])}}, pub, data)
	srv.HandleChunk(p.ID, p, &chunk)
	srv.HandleChunk(p.ID, p, &chunk)
	if p.GetPending(pr.RequestID) == nil || len(pr.ErrorCh) != 0 || len(pr.ChunkCh) != 2 {
		t.Fatal("non-streaming limits affected streaming ingress")
	}
	for i := 0; i < 2; i++ {
		if got := <-pr.ChunkCh; got.Data != data {
			t.Fatal("streaming payload changed")
		}
	}
	p.RemovePending(pr.RequestID)
}
