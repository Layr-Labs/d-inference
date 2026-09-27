package api

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/receipts"
	"nhooyr.io/websocket"
)

// TestInferenceReceiptEndToEndNetworkLookup drives a receipt-enabled request
// through the real HTTP handler and provider WebSocket, then verifies the
// published receipt with only public inputs: the saved request body, the
// returned text and the issuer's public key.
func TestInferenceReceiptEndToEndNetworkLookup(t *testing.T) {
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = byte(i + 17)
	}
	privateKey := ed25519.NewKeyFromSeed(seed)
	cfg := ServerConfig{
		BaseURL: "https://receipts.example",
		InferenceReceipts: &receipts.Config{
			Enabled:      true,
			SigningKeyID: "receipt-test-v1",
			SigningKey:   base64.StdEncoding.EncodeToString(seed),
		},
	}
	ts, cleanup, providerDone := setupE2ETest(t, "test-model", func(ctx context.Context, conn *websocket.Conn, inferReq protocol.InferenceRequestMessage, publicKey string) {
		sendChunk(t, ctx, conn, inferReq, publicKey, `data: {"id":"chatcmpl-test","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":"4"},"finish_reason":null}]}`+"\n\n")
		sendChunk(t, ctx, conn, inferReq, publicKey, `data: {"id":"chatcmpl-test","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}`+"\n\n")
		sendComplete(ctx, conn, inferReq.RequestID, protocol.UsageInfo{PromptTokens: 12, CompletionTokens: 1})
	}, cfg)
	defer cleanup()

	nonceBytes := make([]byte, 32)
	for i := range nonceBytes {
		nonceBytes[i] = byte(255 - i)
	}
	nonce := base64.RawURLEncoding.EncodeToString(nonceBytes)
	body := `{"model":"test-model","messages":[{"role":"system","content":"Answer precisely."},{"role":"user","content":"What is 2+2?"}],"temperature":0,"max_tokens":8}`
	req, err := http.NewRequest(http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set(inferenceReceiptHeader, inferenceReceiptRequired)
	req.Header.Set(inferenceReceiptNonceHeader, nonce)
	response, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	responseBody, readErr := io.ReadAll(response.Body)
	response.Body.Close()
	if readErr != nil {
		t.Fatal(readErr)
	}
	if response.StatusCode != http.StatusOK {
		t.Fatalf("inference status=%d body=%s", response.StatusCode, responseBody)
	}
	var chat struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(responseBody, &chat); err != nil {
		t.Fatal(err)
	}
	if len(chat.Choices) != 1 || chat.Choices[0].Message.Content != "4" {
		t.Fatalf("unexpected inference output: %s", responseBody)
	}
	jobID := response.Header.Get(inferenceReceiptJobIDHeader)
	receiptHash := response.Header.Get(inferenceReceiptHashHeader)
	if jobID == "" || receiptHash == "" {
		t.Fatalf("receipt headers missing: job=%q hash=%q", jobID, receiptHash)
	}

	lookup, err := http.Get(ts.URL + "/v1/inference-receipts/jobs/" + jobID)
	if err != nil {
		t.Fatal(err)
	}
	lookupBody, readErr := io.ReadAll(lookup.Body)
	lookup.Body.Close()
	if readErr != nil {
		t.Fatal(readErr)
	}
	if lookup.StatusCode != http.StatusOK {
		t.Fatalf("job lookup status=%d body=%s", lookup.StatusCode, lookupBody)
	}
	if bytes.Contains(lookupBody, []byte("Answer precisely.")) || bytes.Contains(lookupBody, []byte("What is 2+2?")) || bytes.Contains(lookupBody, []byte(`"content":"4"`)) {
		t.Fatalf("receipt lookup exposed request or output plaintext: %s", lookupBody)
	}
	var lookupResult inferenceReceiptLookupResponse
	if err := json.Unmarshal(lookupBody, &lookupResult); err != nil {
		t.Fatal(err)
	}
	var envelope receipts.Envelope
	if err := json.Unmarshal(lookupResult.Receipt, &envelope); err != nil {
		t.Fatal(err)
	}
	if err := receipts.Verify(envelope, privateKey.Public().(ed25519.PublicKey)); err != nil {
		t.Fatalf("receipt signature invalid: %v", err)
	}
	payload := envelope.Payload
	canonicalHash, err := receipts.HashCanonicalJSON([]byte(body))
	if err != nil {
		t.Fatal(err)
	}
	if payload.JobID != jobID || payload.Nonce != nonce || payload.CallerRef != "key_admin_seed" ||
		payload.RequestSHA256 != canonicalHash || payload.RequestBytesSHA256 != receipts.HashBytes([]byte(body)) ||
		payload.OutputSHA256 != receipts.HashBytes([]byte("4")) || payload.RequestedModel != "test-model" || payload.ResolvedModel != "test-model" ||
		payload.Issuer != "https://receipts.example" || payload.FinishReason != "stop" {
		t.Fatalf("receipt does not bind inference: %+v", payload)
	}
	byHash, err := http.Get(ts.URL + "/v1/inference-receipts/hashes/" + receiptHash)
	if err != nil {
		t.Fatal(err)
	}
	defer byHash.Body.Close()
	if byHash.StatusCode != http.StatusOK {
		data, _ := io.ReadAll(byHash.Body)
		t.Fatalf("hash lookup status=%d body=%s", byHash.StatusCode, data)
	}
	select {
	case <-providerDone:
	case <-time.After(2 * time.Second):
		t.Fatal("provider did not finish")
	}
}
