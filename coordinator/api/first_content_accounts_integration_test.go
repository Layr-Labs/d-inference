package api

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestFirstContentSLAExemptEndpointsSurviveOldDeadline(t *testing.T) {
	for _, endpoint := range []string{"/v1/chat/completions", "/v1/responses", "/v1/completions", "/v1/messages"} {
		for _, stream := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/stream=%t", endpoint, stream), func(t *testing.T) {
				reg, st, srv, ts := setupTTFTFailoverServerWithConfig(t, ServerConfig{FirstContentDeadlineBase: 20 * time.Millisecond, FirstContentSLAAccounts: []string{"partner@example.invalid"}})
				srv.SetTTFTHardReject(true)
				// Other service accounts must also be exempt, regardless of role.
				if err := st.CreateUser(&store.User{AccountID: testConsumerID, PrivyUserID: "did:other-partner", Email: "other@example.com", Role: store.RoleService}); err != nil {
					t.Fatal(err)
				}
				ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				defer cancel()
				const model = "exempt-deadline-model"
				seen := make(chan struct{}, 1)
				p := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{Name: "slow-but-valid", Version: "0.8.15", DecodeTPS: 200, Models: []failoverModelSpec{{ID: model}}, Script: func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
					pr := reg.GetProvider(fp.registryID).GetPending(req.RequestID)
					if req.FirstContentBudgetMS != 0 || pr == nil || !pr.FirstContentDeadline.IsZero() || pr.MaxTTFTMs != 0 {
						t.Errorf("exempt dispatch retained deadline: wire=%d pending=%+v", req.FirstContentBudgetMS, pr)
					}
					seen <- struct{}{}
					fp.sendAccepted(ctx, req)
					select {
					case <-ctx.Done():
						return
					case <-time.After(120 * time.Millisecond):
					}
					fp.serveFull(ctx, req, model, "EXEMPT_OK")
				}})
				makeProviderTTFTSlow(t, reg, p.registryID, model)
				field := `"messages":[{"role":"user","content":"hello"}]`
				if endpoint == "/v1/completions" {
					field = `"prompt":"hello"`
				}
				if endpoint == "/v1/responses" {
					field = `"input":"hello"`
				}
				body := fmt.Sprintf(`{"model":%q,%s,"max_tokens":16,"stream":%t}`, model, field, stream)
				status, response, err := postGenericInference(ctx, ts.URL, endpoint, body)
				if err != nil || status != http.StatusOK || !strings.Contains(response, "EXEMPT_OK") {
					t.Fatalf("status=%d err=%v body=%s", status, err, response)
				}
				select {
				case <-seen:
				default:
					t.Fatal("request never dispatched")
				}
			})
		}
	}
}

func TestFirstContentSLAOpenRouterEmailStillTimesOut(t *testing.T) {
	reg, st, _, ts := setupTTFTFailoverServerWithConfig(t, ServerConfig{FirstContentDeadlineBase: 75 * time.Millisecond, FirstContentSLAAccounts: []string{"partner@example.invalid"}})
	if err := st.CreateUser(&store.User{AccountID: testConsumerID, PrivyUserID: "did:openrouter", Email: "partner@example.invalid", Role: store.RoleService}); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	const model = "openrouter-account-timeout"
	startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{Name: "silent-upstream-provider", Version: "0.8.15", DecodeTPS: 200, Models: []failoverModelSpec{{ID: model}}, Script: func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
		if req.FirstContentBudgetMS <= 0 {
			t.Error("OpenRouter wire budget omitted")
		}
		fp.sendAccepted(ctx, req)
		select {
		case <-ctx.Done():
		case <-time.After(time.Second):
		}
	}})
	status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil || status != http.StatusTooManyRequests {
		t.Fatalf("OpenRouter deadline: status=%d err=%v body=%s", status, err, body)
	}
}

func TestFirstContentSLAExemptionSurvivesFailover(t *testing.T) {
	reg, _, _, ts := setupTTFTFailoverServerWithConfig(t, ServerConfig{FirstContentDeadlineBase: 50 * time.Millisecond, FirstContentSLAAccounts: []string{}})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	const model = "exempt-retry-model"
	var attempts deadlineAttemptRecorder
	script := func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
		attempt := attempts.capture(t, reg, fp, req)
		if attempt == 1 {
			fp.sendTypedInferenceError(ctx, req, protocol.FailureCodeCapacity, errorReasonCapacityBusy, http.StatusServiceUnavailable)
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(120 * time.Millisecond):
		}
		fp.serveFull(ctx, req, model, "RETRY_OK")
	}
	for i := 0; i < 2; i++ {
		startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{Name: fmt.Sprintf("exempt-retry-%d", i), Version: "0.8.15", DecodeTPS: float64(200 - i*50), Models: []failoverModelSpec{{ID: model}}, Script: script})
	}
	status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil || status != http.StatusOK || !strings.Contains(body, "RETRY_OK") {
		t.Fatalf("retry: %d %v %s", status, err, body)
	}
	seen := attempts.snapshot()
	if len(seen) != 2 {
		t.Fatalf("attempts=%+v", seen)
	}
	for _, attempt := range seen {
		if attempt.wireMS != 0 || attempt.maxTTFTMS != 0 {
			t.Fatalf("retry reinstated SLA: %+v", attempt)
		}
	}
}
