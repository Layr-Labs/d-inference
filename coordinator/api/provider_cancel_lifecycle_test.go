package api

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"io"
	"net/http"
	"nhooyr.io/websocket"
	"strings"
	"testing"
	"time"
)

// TestNormalCompletionSendsNoProviderCancel: a stream that ends with the
// provider's own completion never receives a cancel frame from the
// coordinator (the terminal already settled the request); the cancel is
// reserved for a client that goes away mid-stream, which the cancellation
// integration tests cover.
func TestNormalCompletionSendsNoProviderCancel(t *testing.T) {
	_, reg, _, ts := setupTestServer(t)
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	pubKey := testPublicKeyB64()
	const model = "no-cancel-model"
	conn := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}, pubKey)
	defer conn.Close(websocket.StatusNormalClosure, "")
	challengeCtx, challengeCancel := context.WithTimeout(ctx, 5*time.Second)
	waitForChallenge(t, challengeCtx, conn, pubKey)
	challengeCancel()
	time.Sleep(200 * time.Millisecond)
	makeProviderRoutable(reg)

	streamDone := make(chan struct{})
	sawCancel := make(chan bool, 1)
	go func() {
		var inferReq protocol.InferenceRequestMessage
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				sawCancel <- false
				return
			}
			var env struct {
				Type string `json:"type"`
			}
			_ = json.Unmarshal(data, &env)
			if env.Type == protocol.TypeAttestationChallenge {
				_ = conn.Write(ctx, websocket.MessageText, makeValidChallengeResponse(data, pubKey))
				continue
			}
			if env.Type != protocol.TypeInferenceRequest {
				continue
			}
			_ = json.Unmarshal(data, &inferReq)
			break
		}
		writeEncryptedTestChunk(t, ctx, conn, inferReq, pubKey,
			`data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"Hello"}}]}`+"\n\n")
		sendComplete(ctx, conn, inferReq.RequestID, protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 1})
		// After the client has drained the stream, anything cancel-shaped
		// arriving within the grace window is the bug.
		<-streamDone
		readCtx, readCancel := context.WithTimeout(ctx, 500*time.Millisecond)
		defer readCancel()
		for {
			_, data, err := conn.Read(readCtx)
			if err != nil {
				sawCancel <- false
				return
			}
			var env struct {
				Type string `json:"type"`
			}
			_ = json.Unmarshal(data, &env)
			if env.Type == protocol.TypeCancel {
				sawCancel <- true
				return
			}
		}
	}()

	body := `{"model":"` + model + `","messages":[{"role":"user","content":"hi"}],"stream":true}`
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	out, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK || !strings.Contains(string(out), "[DONE]") {
		t.Fatalf("status = %d body = %s", resp.StatusCode, out)
	}
	close(streamDone)

	select {
	case got := <-sawCancel:
		if got {
			t.Fatal("coordinator sent a cancel frame after the provider's own completion settled the request")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("provider goroutine did not report")
	}
}

// TestDecryptFailureStillCancelsProviderGeneration: when a chunk fails to
// decrypt AFTER the stream is committed, the coordinator synthesizes a
// terminal error, which settles the request — so the committed writer's exit
// no longer sends a cancel. The provider is still generating, so the cancel
// must come from the decrypt-failure branch itself. (Before commit the
// dispatch loop's own retry path cancels, which is why the bad chunk here
// follows a good one.)
func TestDecryptFailureStillCancelsProviderGeneration(t *testing.T) {
	_, reg, _, ts := setupTestServer(t)
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	pubKey := testPublicKeyB64()
	const model = "decrypt-failure-model"
	conn := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}, pubKey)
	defer conn.Close(websocket.StatusNormalClosure, "")
	challengeCtx, challengeCancel := context.WithTimeout(ctx, 5*time.Second)
	waitForChallenge(t, challengeCtx, conn, pubKey)
	challengeCancel()
	time.Sleep(200 * time.Millisecond)
	makeProviderRoutable(reg)

	sawCancel := make(chan bool, 1)
	go func() {
		var inferReq protocol.InferenceRequestMessage
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				sawCancel <- false
				return
			}
			var env struct {
				Type string `json:"type"`
			}
			_ = json.Unmarshal(data, &env)
			if env.Type == protocol.TypeAttestationChallenge {
				_ = conn.Write(ctx, websocket.MessageText, makeValidChallengeResponse(data, pubKey))
				continue
			}
			if env.Type != protocol.TypeInferenceRequest {
				continue
			}
			_ = json.Unmarshal(data, &inferReq)
			break
		}
		// Commit the stream with real content first...
		writeEncryptedTestChunk(t, ctx, conn, inferReq, pubKey,
			`data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"Hello"}}]}`+"\n\n")
		// ...then a well-formed envelope whose ciphertext cannot be opened.
		garbageKey := make([]byte, 32)
		garbage := make([]byte, 64)
		_, _ = rand.Read(garbageKey)
		_, _ = rand.Read(garbage)
		bad, _ := json.Marshal(protocol.InferenceResponseChunkMessage{
			Type:      protocol.TypeInferenceResponseChunk,
			RequestID: inferReq.RequestID,
			EncryptedData: &protocol.EncryptedPayload{
				EphemeralPublicKey: base64.StdEncoding.EncodeToString(garbageKey),
				Ciphertext:         base64.StdEncoding.EncodeToString(garbage),
			},
		})
		_ = conn.Write(ctx, websocket.MessageText, bad)
		readCtx, readCancel := context.WithTimeout(ctx, 3*time.Second)
		defer readCancel()
		for {
			_, data, err := conn.Read(readCtx)
			if err != nil {
				sawCancel <- false
				return
			}
			var env struct {
				Type string `json:"type"`
			}
			_ = json.Unmarshal(data, &env)
			if env.Type == protocol.TypeCancel {
				sawCancel <- true
				return
			}
		}
	}()

	body := `{"model":"` + model + `","messages":[{"role":"user","content":"hi"}],"stream":true}`
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	_, _ = io.ReadAll(resp.Body)
	resp.Body.Close()

	select {
	case got := <-sawCancel:
		if !got {
			t.Fatal("provider received no cancel after its chunk failed to decrypt; it would keep generating")
		}
	case <-time.After(6 * time.Second):
		t.Fatal("provider goroutine did not report")
	}
}
