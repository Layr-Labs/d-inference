package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Raw backend responses and reconstructed deltas must share the same terminal
// usage requirement; a complete-looking body cannot consume a reservation on
// its own, and a buffered provider error still takes precedence over usage.
func TestNonStreamResponseCompletionContract(t *testing.T) {
	for _, shape := range []struct{ name, chunk string }{
		{"chat object", `data: {"object":"chat.completion","choices":[{"message":{"role":"assistant","content":"answer"}}]}`},
		{"response object", `data: {"object":"response","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"answer"}]}]}`},
		{"chat delta", `data: {"choices":[{"delta":{"content":"answer"}}]}`},
	} {
		for _, terminal := range []string{"usage", "missing usage", "provider error"} {
			t.Run(shape.name+"/"+terminal, func(t *testing.T) {
				srv, _, ledger := billingTestServer(t)
				initial := ledger.Balance(testConsumerID)
				const reserved int64 = 25000
				if err := ledger.Charge(testConsumerID, reserved, "reserve:completion-contract"); err != nil {
					t.Fatal(err)
				}
				pr := &registry.PendingRequest{RequestID: "completion-contract", Model: "m", ConsumerKey: testConsumerID, ReservedMicroUSD: reserved, ChunkCh: make(chan registry.ProviderChunk), CompleteCh: make(chan protocol.UsageInfo, 1), ErrorCh: make(chan protocol.InferenceErrorMessage, 1)}
				close(pr.ChunkCh)
				if terminal != "missing usage" {
					pr.CompleteCh <- protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 1}
				}
				close(pr.CompleteCh)
				if terminal == "provider error" {
					pr.ErrorCh <- protocol.InferenceErrorMessage{StatusCode: 500, Error: "provider failed"}
				}
				w := httptest.NewRecorder()
				srv.handleNonStreamingResponseWithFirstChunkAndError(w, httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil), pr, []string{shape.chunk}, nil)
				wantStatus, wantBalance := http.StatusOK, initial-reserved
				if terminal == "missing usage" {
					wantStatus, wantBalance = http.StatusBadGateway, initial
				}
				if terminal == "provider error" {
					wantStatus, wantBalance = http.StatusInternalServerError, initial
				}
				if w.Code != wantStatus || ledger.Balance(testConsumerID) != wantBalance {
					t.Fatalf("status=%d balance=%d; want%d/%d body=%s", w.Code, ledger.Balance(testConsumerID), wantStatus, wantBalance, w.Body.String())
				}
				if terminal == "usage" && !strings.Contains(w.Body.String(), "answer") {
					t.Fatalf("response content lost: %s", w.Body.String())
				}
				if terminal != "usage" && strings.Contains(w.Body.String(), "answer") {
					t.Fatalf("failed response leaked content: %s", w.Body.String())
				}
			})
		}
	}
}
