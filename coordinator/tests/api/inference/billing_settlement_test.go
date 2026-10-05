package inference_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestNonStreamingCompleteObjectWithoutUsageDoesNotReturnSuccessAfterRefund(t *testing.T) {
	srv, _, ledger := billingTestServer(t)

	consumerID := testConsumerID
	initialBalance := ledger.Balance(consumerID)
	const reservedMicroUSD int64 = 25_000
	if err := ledger.Charge(consumerID, reservedMicroUSD, "reserve:"+consumerID); err != nil {
		t.Fatalf("reserve balance: %v", err)
	}

	pr := &registry.PendingRequest{
		RequestID:        "missing-usage-complete-object",
		Model:            "missing-usage-model",
		ConsumerKey:      consumerID,
		ReservedMicroUSD: reservedMicroUSD,
		ChunkCh:          make(chan registry.ProviderChunk, 1),
		CompleteCh:       make(chan protocol.UsageInfo, 1),
		ErrorCh:          make(chan protocol.InferenceErrorMessage, 1),
	}
	close(pr.ChunkCh)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil).WithContext(ctx)
	rr := httptest.NewRecorder()
	firstChunk := `data: {"id":"chatcmpl-missing-usage","object":"chat.completion","choices":[{"message":{"role":"assistant","content":"ok"}}]}`

	srv.NewRelay().NonStream(rr, req, pr, []string{firstChunk}, nil)

	if rr.Code == http.StatusOK {
		t.Fatalf("status = 200 with refunded reservation and no completion usage; body = %s", rr.Body.String())
	}
	if got := ledger.Balance(consumerID); got != initialBalance {
		t.Fatalf("balance = %d, want refunded balance %d", got, initialBalance)
	}
}
