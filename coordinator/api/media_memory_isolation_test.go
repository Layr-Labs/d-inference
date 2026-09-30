package api

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestMediaMemoryRefusalPreservesTextOnSameProvider(t *testing.T) {
	t.Setenv(envQueueBeforeShed, "false")
	reg, _, server := setupFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	const model = "media-memory-isolation"
	fp := startFailoverProvider(t, ctx, server, reg, failoverProviderConfig{
		Name: "media-provider", Version: "0.9.14", DecodeTPS: 100,
		Models: []failoverModelSpec{{ID: model}},
		Script: func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte) {
			if strings.Contains(string(body), `"image_url"`) {
				fp.sendTypedInferenceError(ctx, req, protocol.FailureCodeCapacity,
					errorReasonMediaMemoryUnavailable, http.StatusServiceUnavailable)
				return
			}
			fp.serveFull(ctx, req, model, "text-still-serves")
		},
	})
	p := reg.GetProvider(fp.registryID)
	p.Mu().Lock()
	p.Models[0].IsVision = true
	p.PrefillTPS = 1000
	p.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots:         []protocol.BackendSlotCapacity{{Model: model, State: "idle", ActiveTokenBudgetMax: 200_000}},
	}
	p.Mu().Unlock()
	media, err := json.Marshal(map[string]any{
		"model": model, "stream": true, "max_tokens": 16,
		"messages": []any{map[string]any{"role": "user", "content": []any{
			map[string]any{"type": "text", "text": "Describe this image"},
			map[string]any{"type": "image_url", "image_url": map[string]any{"url": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII="}},
		}}},
	})
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		before := fp.dispatchCount()
		status, body, err := postChat(ctx, server.URL, "test-key", string(media))
		if err != nil || status != http.StatusTooManyRequests || fp.dispatchCount() != before+1 {
			t.Fatalf("media round %d: status=%d dispatched=%d err=%v body=%s", i, status, fp.dispatchCount()-before, err, body)
		}
		if reg.BudgetClampActive(fp.registryID, model) || reg.CapacityCooldownActive(fp.registryID, model) {
			t.Fatal("media-only refusal disabled the provider's text capacity")
		}
		if rate, samples := reg.CapacityRejectRate(fp.registryID, model); rate != 0 || samples != 0 {
			t.Fatalf("media-only refusal altered text capacity history: rate=%v samples=%d", rate, samples)
		}
		status, body, err = postChat(ctx, server.URL, "test-key", buildChatBody(t, model, true, nil))
		if err != nil || status != http.StatusOK || !strings.Contains(body, "text-still-serves") {
			t.Fatalf("text after media refusal %d: status=%d err=%v body=%s", i, status, err, body)
		}
	}
}

func TestMediaMemoryReasonIsBoundedRetryableAndDoesNotHideNativeFault(t *testing.T) {
	zero := int64(0)
	message := protocol.InferenceErrorMessage{
		FailureCode: protocol.FailureCodeCapacity, ErrorReason: errorReasonMediaMemoryUnavailable,
		StatusCode: 503, Error: "PRIVATE_MEDIA_MUST_NOT_ESCAPE",
		RejectionReason: protocol.RejectionReasonTokenBudget, AvailableTokenBudget: &zero,
		FeasibleAfterMS: 100, CapacitySeq: 7,
	}
	safe, invalidCode, invalidCause := sanitizeProviderInferenceError(&message)
	if invalidCode || invalidCause || safe.StatusCode != 503 || safe.ErrorReason != errorReasonMediaMemoryUnavailable {
		t.Fatalf("media reason was lost: %+v", safe)
	}
	if strings.Contains(safe.Error, "PRIVATE_MEDIA") || !isProviderHealthNeutralErrorReason(safe.ErrorReason) {
		t.Fatalf("media refusal did not retain privacy/health semantics: %+v", safe)
	}
	if safe.RejectionReason != "" || safe.AvailableTokenBudget != nil || safe.FeasibleAfterMS != 0 || safe.CapacitySeq != 0 {
		t.Fatalf("media memory refusal carried a false text-capacity observation: %+v", safe)
	}
	if classifyRejection(safe.ErrorReason, safe.Error, 1, 1_000_000, "") != rejectionTransientCapacity {
		t.Fatal("media reservation must allow bounded failover to another provider")
	}
	message.TerminalCause = terminalCauseEngineError
	safe, _, _ = sanitizeProviderInferenceError(&message)
	if isProviderHealthNeutralErrorReason(safe.ErrorReason) || safe.StatusCode != 500 || safe.FailureCode != protocol.FailureCodeGenerationFailure {
		t.Fatalf("a real native fault inherited media refusal exemption: %+v", safe)
	}
}
