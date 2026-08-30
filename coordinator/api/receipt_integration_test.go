package api

import (
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/receipt"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

// Receipt end-to-end: a provider that seals a genuine receipt (signed with
// the same P-256 key its attestation registered) must reach the consumer with
// the receipt attached, and GET /v1/receipts/{address} must report every
// binding check green. A provider that lies inside a well-formed, correctly
// signed receipt must be flagged by the dispatched-request-digest and
// weight-hash bindings — the forgery is internally consistent (that is the
// attack) and the coordinator's cross-checks are what refute it.

const receiptTestModel = "receipt-model"

var receiptTestWeightHash = strings.Repeat("ab", 32)

// runReceiptScenario spins up coordinator + one simulated provider,
// sends one streaming chat completion, and returns the SSE body plus the
// stored receipt record fetched from /v1/receipts/{address}.
// mutateReceipt lets a scenario turn the honest receipt into a lie before
// sealing; the receipt is always canonically encoded and correctly signed.
func runReceiptScenario(
	t *testing.T,
	mutateReceipt func(*receipt.Receipt),
) (sseBody string, stored map[string]any) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	pubKeyB64 := testPublicKeyB64()
	value, ok := testProviderKeys.Load(pubKeyB64)
	if !ok {
		t.Fatalf("missing cached provider keypair for %q", pubKeyB64)
	}
	keypair := value.(testProviderKeyPair)

	models := []protocol.ModelInfo{{
		ID: receiptTestModel, ModelType: "test", Quantization: "4bit",
		WeightHash: receiptTestWeightHash,
	}}
	conn := connectProviderWithAttestation(
		t, ctx, ts.URL, models, pubKeyB64,
		createTestAttestationJSON(t, pubKeyB64))
	defer conn.Close(websocket.StatusNormalClosure, "")

	// The attestation helper registered the P-256 signer under the
	// encryption key; the simulated provider signs receipts with it — the
	// same key the coordinator holds as this provider's attested SE key.
	rawKey, ok := testAttestationChallengeKeys.Load(pubKeyB64)
	if !ok {
		t.Fatal("no challenge signer registered")
	}
	sePriv := rawKey.(*ecdsa.PrivateKey)

	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	// Simulated provider loop: answer challenges; on the inference request,
	// decrypt the body, seal a receipt over the DECRYPTED BYTES (or the
	// scenario's mutation of the honest record), stream one chunk, complete.
	go func() {
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var env struct {
				Type string `json:"type"`
			}
			json.Unmarshal(data, &env)

			if env.Type == protocol.TypeAttestationChallenge {
				conn.Write(ctx, websocket.MessageText,
					makeValidChallengeResponse(data, pubKeyB64))
				continue
			}
			if env.Type != protocol.TypeInferenceRequest {
				continue
			}

			var inferReq protocol.InferenceRequestMessage
			if err := json.Unmarshal(data, &inferReq); err != nil || inferReq.EncryptedBody == nil {
				return
			}
			decrypted, err := e2e.DecryptWithPrivateKey(&e2e.EncryptedPayload{
				EphemeralPublicKey: inferReq.EncryptedBody.EphemeralPublicKey,
				Ciphertext:         inferReq.EncryptedBody.Ciphertext,
			}, keypair.private)
			if err != nil {
				return
			}

			responseText := "ok"
			writeEncryptedTestChunk(t, ctx, conn, protocol.InferenceRequestMessage{
				RequestID:     inferReq.RequestID,
				EncryptedBody: inferReq.EncryptedBody,
			}, pubKeyB64,
				`data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"`+responseText+`"}}]}`+"\n\n")

			rec := receipt.Receipt{
				CompletionTokens: 1,
				ModelID:          receiptTestModel,
				ModelWeightHash:  receiptTestWeightHash,
				PromptTokens:     5,
				RequestID:        inferReq.RequestID,
				RequestSHA256:    receipt.SHA256Hex(decrypted),
				ResponseSHA256:   receipt.SHA256Hex([]byte(responseText)),
				V:                receipt.Version,
			}
			if mutateReceipt != nil {
				mutateReceipt(&rec)
			}
			wire := rec.Canonical()
			addr := receipt.AddressOf(wire)
			digest := sha256.Sum256([]byte(addr))
			r, s, err := ecdsa.Sign(rand.Reader, sePriv, digest[:])
			if err != nil {
				return
			}
			sigDER, _ := asn1.Marshal(ecdsaSigHelper{R: r, S: s})

			complete := protocol.InferenceCompleteMessage{
				Type:         protocol.TypeInferenceComplete,
				RequestID:    inferReq.RequestID,
				Usage:        protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 1},
				SESignature:  base64.StdEncoding.EncodeToString(sigDER),
				ResponseHash: addr,
				Receipt:      string(wire),
			}
			completeData, _ := json.Marshal(complete)
			conn.Write(ctx, websocket.MessageText, completeData)
			return
		}
	}()

	chatBody := `{"model":"` + receiptTestModel + `","messages":[{"role":"user","content":"what is 2+2?"}],"stream":true}`
	httpReq, _ := http.NewRequestWithContext(ctx, http.MethodPost,
		ts.URL+"/v1/chat/completions", strings.NewReader(chatBody))
	httpReq.Header.Set("Authorization", "Bearer test-key")
	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	defer resp.Body.Close()
	bodyBytes, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200; body: %s", resp.StatusCode, bodyBytes)
	}
	sseBody = string(bodyBytes)

	// Pull the receipt out of the stream to learn its address, then fetch
	// the coordinator's stored verdict.
	receiptJSON := extractSSEField(t, sseBody, "receipt")
	address := receipt.AddressOf([]byte(receiptJSON))
	recResp, err := http.Get(ts.URL + "/v1/receipts/" + address)
	if err != nil {
		t.Fatalf("get receipt: %v", err)
	}
	defer recResp.Body.Close()
	if recResp.StatusCode != http.StatusOK {
		t.Fatalf("receipt endpoint status = %d, want 200", recResp.StatusCode)
	}
	if err := json.NewDecoder(recResp.Body).Decode(&stored); err != nil {
		t.Fatalf("decode stored receipt: %v", err)
	}
	return sseBody, stored
}

// extractSSEField scans SSE events for the named string field and returns its
// value, failing the test when absent.
func extractSSEField(t *testing.T, sse, field string) string {
	t.Helper()
	for _, line := range strings.Split(sse, "\n") {
		line = strings.TrimPrefix(strings.TrimSpace(line), "data: ")
		if line == "" || line == "[DONE]" || !strings.HasPrefix(line, "{") {
			continue
		}
		var obj map[string]any
		if err := json.Unmarshal([]byte(line), &obj); err != nil {
			continue
		}
		if v, ok := obj[field].(string); ok && v != "" {
			return v
		}
	}
	t.Fatalf("SSE stream carried no %q field:\n%s", field, sse)
	return ""
}

func storedChecks(t *testing.T, stored map[string]any) map[string]any {
	t.Helper()
	checks, ok := stored["checks"].(map[string]any)
	if !ok {
		t.Fatalf("stored receipt has no checks object: %v", stored)
	}
	return checks
}

func TestIntegration_ReceiptGenuine(t *testing.T) {
	sse, stored := runReceiptScenario(t, nil)

	// The stream must carry receipt + address + signature together.
	receiptJSON := extractSSEField(t, sse, "receipt")
	responseHash := extractSSEField(t, sse, "response_hash")
	_ = extractSSEField(t, sse, "se_signature")
	if receipt.AddressOf([]byte(receiptJSON)) != responseHash {
		t.Errorf("response_hash %q is not the receipt address", responseHash)
	}

	// The receipt must parse canonically and reproduce the request digest
	// semantics: request_sha256 covers the decrypted body bytes.
	rec, err := receipt.Parse([]byte(receiptJSON))
	if err != nil {
		t.Fatalf("consumer-side Parse: %v", err)
	}
	if rec.ModelID != receiptTestModel || rec.ModelWeightHash != receiptTestWeightHash {
		t.Errorf("receipt model binding wrong: %+v", rec)
	}

	// Consumer-side signature verification using only public data from the
	// receipts endpoint — the decentralized-verifier path.
	sePub, _ := stored["se_public_key"].(string)
	seSig, _ := stored["se_signature"].(string)
	if sePub == "" || seSig == "" {
		t.Fatalf("stored receipt missing public key or signature: %v", stored)
	}
	if err := receipt.VerifySignature(responseHash, seSig, sePub); err != nil {
		t.Errorf("third-party signature verification failed: %v", err)
	}

	checks := storedChecks(t, stored)
	for _, key := range []string{
		"address_match",
		"request_digest_match", "request_digest_checked",
		"model_weight_hash_match", "model_weight_hash_checked",
		"signature_valid", "signature_checked",
	} {
		if v, _ := checks[key].(bool); !v {
			t.Errorf("check %s = %v, want true (checks: %v)", key, checks[key], checks)
		}
	}
}

func TestIntegration_ReceiptLyingProviderIsFlagged(t *testing.T) {
	// The provider seals a WELL-FORMED, correctly signed receipt over a lie:
	// a request digest for bytes it never ran and a weight hash for weights
	// it never loaded. Internal consistency holds (address matches, signature
	// verifies) — the coordinator's cross-checks against what it dispatched
	// and what the provider registered are what refute the lie.
	_, stored := runReceiptScenario(t, func(rec *receipt.Receipt) {
		rec.RequestSHA256 = strings.Repeat("ee", 32)
		rec.ModelWeightHash = strings.Repeat("cd", 32)
	})

	checks := storedChecks(t, stored)
	if v, _ := checks["address_match"].(bool); !v {
		t.Errorf("forged receipt should still be internally consistent (address_match)")
	}
	if v, _ := checks["signature_valid"].(bool); !v {
		t.Errorf("forged receipt should still be correctly signed (that is the attack)")
	}
	if v, _ := checks["request_digest_match"].(bool); v {
		t.Errorf("lying request digest passed the dispatched-body binding")
	}
	if v, _ := checks["request_digest_checked"].(bool); !v {
		t.Errorf("request digest binding was not checked")
	}
	if v, _ := checks["model_weight_hash_match"].(bool); v {
		t.Errorf("lying weight hash passed the registered-model binding")
	}
}
