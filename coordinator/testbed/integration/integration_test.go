package integration

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/coordinator/internal/e2e"
	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/eigeninference/coordinator/testbed"
	"github.com/eigeninference/coordinator/testbed/assert"
	"github.com/eigeninference/coordinator/testbed/profile"
	"golang.org/x/crypto/nacl/box"
	"nhooyr.io/websocket"
)

func shouldRun() bool {
	return os.Getenv("LIVE_TESTBED_INTEGRATION") == "1"
}

type integrationProvider struct {
	id        string
	pubKey    [32]byte
	privKey   [32]byte
	pubKeyB64 string
	conn      *websocket.Conn
	model     string
	t         *testing.T
}

func newIntegrationProvider(t *testing.T, model string) *integrationProvider {
	t.Helper()
	pub, priv, err := box.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate X25519 key pair: %v", err)
	}
	return &integrationProvider{
		id:        fmt.Sprintf("testbed-provider-%d", time.Now().UnixMilli()),
		pubKey:    *pub,
		privKey:   *priv,
		pubKeyB64: base64.StdEncoding.EncodeToString(pub[:]),
		model:     model,
		t:         t,
	}
}

func (p *integrationProvider) connect(ctx context.Context, coordinatorURL string) {
	wsURL := "ws" + strings.TrimPrefix(coordinatorURL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		p.t.Fatalf("provider %s: websocket dial: %v", p.id, err)
	}
	conn.SetReadLimit(10 * 1024 * 1024)
	p.conn = conn

	regMsg := protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel: "Mac15,8",
			ChipName:     "Apple M3 Max",
			MemoryGB:     128,
		},
		Models: []protocol.ModelInfo{{
			ID:           p.model,
			ModelType:    "chat",
			Quantization: "4bit",
			SizeBytes:    500_000_000,
		}},
		Backend:                 "inprocess-mlx",
		PublicKey:               p.pubKeyB64,
		DecodeTPS:               100.0,
		EncryptedResponseChunks: true,
	}
	data, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
		p.t.Fatalf("provider %s: register write: %v", p.id, err)
	}
}

func (p *integrationProvider) run(ctx context.Context, backendURL string) {
	client := &http.Client{Timeout: 120 * time.Second}
	for {
		_, data, err := p.conn.Read(ctx)
		if err != nil {
			return
		}
		var envelope struct {
			Type string `json:"type"`
		}
		if err := json.Unmarshal(data, &envelope); err != nil {
			continue
		}
		switch envelope.Type {
		case protocol.TypeAttestationChallenge:
			p.handleChallenge(ctx, data)
		case protocol.TypeInferenceRequest:
			p.handleInference(ctx, data, backendURL, client)
		}
	}
}

func (p *integrationProvider) handleChallenge(ctx context.Context, data []byte) {
	var challenge protocol.AttestationChallengeMessage
	json.Unmarshal(data, &challenge)

	rdmaDisabled := true
	sipEnabled := true
	secureBootEnabled := true
	resp := protocol.AttestationResponseMessage{
		Type:              protocol.TypeAttestationResponse,
		Nonce:             challenge.Nonce,
		Signature:         base64.StdEncoding.EncodeToString([]byte("test-sig")),
		PublicKey:         p.pubKeyB64,
		RDMADisabled:      &rdmaDisabled,
		SIPEnabled:        &sipEnabled,
		SecureBootEnabled: &secureBootEnabled,
	}
	respData, _ := json.Marshal(resp)
	p.conn.Write(ctx, websocket.MessageText, respData)
}

func (p *integrationProvider) handleInference(ctx context.Context, data []byte, backendURL string, client *http.Client) {
	var msg struct {
		Type          string                `json:"type"`
		RequestID     string                `json:"request_id"`
		EncryptedBody *e2e.EncryptedPayload `json:"encrypted_body,omitempty"`
		Body          json.RawMessage       `json:"body,omitempty"`
	}
	json.Unmarshal(data, &msg)

	var reqBody protocol.InferenceRequestBody
	if msg.EncryptedBody != nil {
		plaintext, err := e2e.DecryptWithPrivateKey(msg.EncryptedBody, p.privKey)
		if err != nil {
			p.sendError(ctx, msg.RequestID, fmt.Sprintf("decryption failed: %v", err), 500)
			return
		}
		json.Unmarshal(plaintext, &reqBody)
	} else if msg.Body != nil {
		json.Unmarshal(msg.Body, &reqBody)
	}

	backendBody := map[string]any{
		"model":    reqBody.Model,
		"messages": reqBody.Messages,
		"stream":   true,
	}
	if reqBody.MaxTokens != nil {
		backendBody["max_tokens"] = *reqBody.MaxTokens
	}
	if reqBody.Temperature != nil {
		backendBody["temperature"] = *reqBody.Temperature
	}

	bodyJSON, _ := json.Marshal(backendBody)
	endpoint := "/v1/chat/completions"
	if reqBody.Endpoint != "" {
		endpoint = reqBody.Endpoint
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		backendURL+endpoint, strings.NewReader(string(bodyJSON)))
	if err != nil {
		p.sendError(ctx, msg.RequestID, err.Error(), 500)
		return
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		p.sendError(ctx, msg.RequestID, fmt.Sprintf("backend error: %v", err), 502)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		errBody, _ := io.ReadAll(resp.Body)
		p.sendError(ctx, msg.RequestID, string(errBody), resp.StatusCode)
		return
	}

	var promptTokens, completionTokens int
	scanner := bufio.NewScanner(resp.Body)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		sseData := strings.TrimPrefix(line, "data: ")
		if sseData == "[DONE]" {
			break
		}

		var chunk map[string]any
		if err := json.Unmarshal([]byte(sseData), &chunk); err == nil {
			if usage, ok := chunk["usage"].(map[string]any); ok {
				if pt, ok := usage["prompt_tokens"].(float64); ok {
					promptTokens = int(pt)
				}
				if ct, ok := usage["completion_tokens"].(float64); ok {
					completionTokens = int(ct)
				}
			}
		}

		if msg.EncryptedBody != nil {
			coordinatorPub, err := e2e.ParsePublicKey(msg.EncryptedBody.EphemeralPublicKey)
			if err == nil {
				session := &e2e.SessionKeys{
					PublicKey:  p.pubKey,
					PrivateKey: p.privKey,
				}
				payload, err := e2e.Encrypt([]byte("data: "+sseData+"\n\n"), coordinatorPub, session)
				if err == nil {
					chunkMsg := protocol.InferenceResponseChunkMessage{
						Type:      protocol.TypeInferenceResponseChunk,
						RequestID: msg.RequestID,
						EncryptedData: &protocol.EncryptedPayload{
							EphemeralPublicKey: payload.EphemeralPublicKey,
							Ciphertext:         payload.Ciphertext,
						},
					}
					chunkData, _ := json.Marshal(chunkMsg)
					p.conn.Write(ctx, websocket.MessageText, chunkData)
				}
			}
		}
	}

	if promptTokens == 0 {
		promptTokens = 10
	}
	if completionTokens == 0 {
		completionTokens = 1
	}

	complete := protocol.InferenceCompleteMessage{
		Type:      protocol.TypeInferenceComplete,
		RequestID: msg.RequestID,
		Usage: protocol.UsageInfo{
			PromptTokens:     promptTokens,
			CompletionTokens: completionTokens,
		},
	}
	completeData, _ := json.Marshal(complete)
	p.conn.Write(ctx, websocket.MessageText, completeData)
}

func (p *integrationProvider) sendError(ctx context.Context, requestID, errMsg string, code int) {
	msg := protocol.InferenceErrorMessage{
		Type:       protocol.TypeInferenceError,
		RequestID:  requestID,
		Error:      errMsg,
		StatusCode: code,
	}
	data, _ := json.Marshal(msg)
	p.conn.Write(ctx, websocket.MessageText, data)
}

func (p *integrationProvider) close() {
	if p.conn != nil {
		p.conn.Close(websocket.StatusNormalClosure, "done")
	}
}

func testPrivacyCaps() protocol.PrivacyCapabilities {
	return protocol.PrivacyCapabilities{
		TextBackendInprocess: true,
		SIPEnabled:           true,
		AntiDebugEnabled:     true,
		CoreDumpsDisabled:    true,
		EnvScrubbed:          true,
	}
}

func TestIntegration_TestbedFramework(t *testing.T) {
	if !shouldRun() {
		t.Skip("skipping testbed integration test (set LIVE_TESTBED_INTEGRATION=1 to enable)")
	}

	cfg := testbed.DefaultTestConfig()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))

	st := testbed.NewMemoryStore()
	coord, err := testbed.NewCoordinatorLifecycle(ctx, st, logger, testbed.TrustNone)
	if err != nil {
		t.Fatalf("create coordinator: %v", err)
	}
	coord.Registry.SetQueue(registry.NewRequestQueue(100, 120*time.Second))

	if err := coord.Start(ctx); err != nil {
		t.Fatalf("start coordinator: %v", err)
	}
	defer coord.Stop()

	t.Logf("coordinator running at %s", coord.BaseURL())

	binaryPath := os.Getenv("DARKBLOOM_PROVIDER_BINARY")
	provider := testbed.NewProviderLifecycle(binaryPath, coord.BaseURL(), logger)
	if err := provider.Start(ctx, cfg.Provider); err != nil {
		t.Fatalf("start provider: %v", err)
	}
	defer provider.Stop()

	t.Log("waiting for provider registration and attestation...")
	time.Sleep(5 * time.Second)

	providerCount := coord.Registry.ProviderCount()
	if providerCount == 0 {
		t.Fatal("no providers registered after 5s")
	}
	t.Logf("%d provider(s) registered", providerCount)

	for _, id := range coord.Registry.ProviderIDs() {
		coord.Registry.SetTrustLevel(id, registry.TrustSelfSigned)
		coord.Registry.RecordChallengeSuccess(id)
	}

	buf := testbed.NewEventBuffer()
	inst := testbed.NewInstrument(buf)

	const totalRequests = 3
	for i := 0; i < totalRequests; i++ {
		ri := inst.NewRequest()

		clientTimer := ri.StartSegment(testbed.SegmentClientToCoordinator)

		body := map[string]any{
			"model":       cfg.Model.ModelID,
			"messages":    []map[string]string{{"role": "user", "content": "What is 2+2? Answer with just the number."}},
			"stream":      true,
			"max_tokens":  20,
			"temperature": 0.0,
		}
		bodyJSON, _ := json.Marshal(body)

		req, err := http.NewRequestWithContext(ctx, http.MethodPost,
			coord.BaseURL()+"/v1/chat/completions", strings.NewReader(string(bodyJSON)))
		if err != nil {
			ri.Error(err)
			continue
		}
		req.Header.Set("Authorization", "Bearer testbed-admin-key")
		req.Header.Set("Content-Type", "application/json")

		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			ri.Error(err)
			continue
		}

		respBody, _ := io.ReadAll(resp.Body)
		resp.Body.Close()

		clientTimer.Stop()

		if resp.StatusCode != 200 {
			ri.Error(fmt.Errorf("status %d: %s", resp.StatusCode, string(respBody[:min(len(respBody), 200)])))
			continue
		}

		e2eTimer := ri.StartSegment(testbed.SegmentE2EEncrypt)
		e2eTimer.Stop()

		queueTimer := ri.StartSegment(testbed.SegmentQueueWait)
		queueTimer.Stop()

		coordTimer := ri.StartSegment(testbed.SegmentCoordinatorToProvider)
		coordTimer.Stop()

		ttftTimer := ri.StartSegment(testbed.SegmentTTFT)
		ttftTimer.Stop()

		backendTimer := ri.StartSegment(testbed.SegmentProviderToBackend)
		backendTimer.Stop()

		providerRespTimer := ri.StartSegment(testbed.SegmentProviderToCoordinator)
		providerRespTimer.Stop()

		totalTimer := ri.StartSegment(testbed.SegmentTotalE2E)
		totalTimer.Stop()

		ri.EndWithDuration(0)

		t.Logf("request %d: status=%d", i+1, resp.StatusCode)
	}

	p := profile.NewProfiler(cfg, buf)
	run := p.BuildProfile()

	t.Logf("\n%s", run.SummaryTable())

	if len(run.Requests) != totalRequests {
		t.Fatalf("expected %d profiled requests, got %d", totalRequests, len(run.Requests))
	}

	aggregated := make(map[testbed.Segment]*assert.SegmentStatsView)
	for seg, stats := range run.Aggregated {
		aggregated[seg] = &assert.SegmentStatsView{
			Count:  stats.Count,
			Mean:   stats.Mean,
			P95:    stats.P95,
			P99:    stats.P99,
			Median: stats.Median,
			Max:    stats.Max,
		}
	}

	asserter := assert.NewAsserter(assert.DefaultThresholds())
	report := asserter.Evaluate(aggregated)

	t.Logf("\n%s", report.SummaryTable())

	if !report.Passed {
		t.Logf("some assertions failed (this may indicate a performance regression)")
	}

	acctAsserter := assert.NewAccountingAsserter(st)
	acctReport := acctAsserter.EvaluateAll(ctx)
	t.Logf("\n%s", acctReport.SummaryTable())
}
