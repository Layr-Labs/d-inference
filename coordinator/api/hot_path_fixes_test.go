package api

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"nhooyr.io/websocket"
)

// TestProviderReadLoopRejectsMalformedFramesAndKeepsConnection: the read loop
// decodes each frame once (ProviderMessage.UnmarshalJSON directly); invalid
// JSON, an unknown type and a type-mismatched payload are still rejected
// without dropping the connection, and the next valid heartbeat is processed.
func TestProviderReadLoopRejectsMalformedFramesAndKeepsConnection(t *testing.T) {
	_, reg, _, ts := setupTestServer(t)
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	pubKey := testPublicKeyB64()
	const model = "frame-decode-model"
	conn := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{{ID: model, ModelType: "chat"}}, pubKey)
	defer conn.Close(websocket.StatusNormalClosure, "")
	ids := reg.ProviderIDs()
	if len(ids) != 1 {
		t.Fatalf("registered providers = %d, want 1", len(ids))
	}
	p := reg.GetProvider(ids[0])
	if p == nil {
		t.Fatal("provider not in registry")
	}
	// Drain coordinator frames (challenges) so the socket never backs up.
	go func() {
		for {
			if _, _, err := conn.Read(ctx); err != nil {
				return
			}
		}
	}()

	p.Mu().Lock()
	before := p.LastHeartbeat
	p.Mu().Unlock()
	time.Sleep(10 * time.Millisecond)

	for _, frame := range []string{
		`this is not json`,
		`{"type":"no_such_message_type","x":1}`,
		`{"type":"heartbeat","status":123}`,
		`{"type":"heartbeat"`,
	} {
		if err := conn.Write(ctx, websocket.MessageText, []byte(frame)); err != nil {
			t.Fatalf("write %q: %v", frame, err)
		}
	}
	// A valid heartbeat after the bad frames proves the loop kept reading.
	hb, _ := json.Marshal(protocol.HeartbeatMessage{
		Type: protocol.TypeHeartbeat, Status: "online",
		SystemMetrics: protocol.SystemMetrics{ThermalState: "nominal"},
	})
	if err := conn.Write(ctx, websocket.MessageText, hb); err != nil {
		t.Fatalf("write heartbeat: %v", err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for {
		p.Mu().Lock()
		advanced := p.LastHeartbeat.After(before)
		p.Mu().Unlock()
		if advanced {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("heartbeat after malformed frames was not processed (read loop stopped or connection dropped)")
		}
		time.Sleep(5 * time.Millisecond)
	}
	if reg.GetProvider(ids[0]) == nil {
		t.Fatal("provider was disconnected by malformed frames")
	}
}

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

// TestRoutingSaturatedShedRecordsNoServabilityWalk: a request shed because the
// routing-scan semaphore is saturated records its rejection without the
// telemetry worker walking the fleet. A servable provider exists, so a walk
// would have reported one candidate; the row must say zero / not evaluated.
func TestRoutingSaturatedShedRecordsNoServabilityWalk(t *testing.T) {
	srv, reg, st, ts := setupTestServer(t)
	defer ts.Close()
	const model = "shed-walk-model"
	makeRoutableProvider(t, reg, "shed-walk-provider", model)
	if cc, _, _, _, _ := reg.QuickCapacityCheckWithTTFTForRequest(model, 10, 64, registry.RequestTraits{}, false); cc != 1 {
		t.Fatalf("fixture: candidate count for %s = %d, want 1 (a walk would find it)", model, cc)
	}

	// Saturate the semaphore from the test so the preflight sheds.
	srv.SetRoutingConcurrency(2)
	for i := 0; i < 2; i++ {
		if got := srv.acquireRoutingScanSlot(0, nil); got != scanSlotAcquired {
			t.Fatalf("slot %d: %v", i, got)
		}
	}
	defer func() {
		srv.releaseRoutingScanSlot()
		srv.releaseRoutingScanSlot()
	}()

	body := `{"model":"` + model + `","messages":[{"role":"user","content":"hi"}],"max_tokens":64}`
	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	out, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusTooManyRequests || !strings.Contains(string(out), "routing capacity") {
		t.Fatalf("status = %d body = %s, want the routing_saturated 429", resp.StatusCode, out)
	}

	deadline := time.Now().Add(5 * time.Second)
	for {
		for _, rec := range st.RejectionRecordsSince(time.Now().Add(-time.Minute)) {
			if rec.ReasonCode != rejectionReasonRoutingSaturated {
				continue
			}
			if rec.CandidateCount != 0 || rec.CouldHaveServed {
				t.Fatalf("shed rejection ran the counterfactual fleet walk: candidate_count=%d could_have_served=%v",
					rec.CandidateCount, rec.CouldHaveServed)
			}
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("routing_saturated rejection was never recorded")
		}
		time.Sleep(10 * time.Millisecond)
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
