package api

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/coordinator/internal/payments"
	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/eigeninference/coordinator/internal/store"
	"nhooyr.io/websocket"
)

func TestParseWeaverConfigDefaults(t *testing.T) {
	cfg, ok, err := parseWeaverConfig(map[string]any{
		"weaver": map[string]any{"mode": "deep"},
	})
	if err != nil {
		t.Fatalf("parseWeaverConfig: %v", err)
	}
	if !ok {
		t.Fatal("expected weaver config")
	}
	if cfg.CandidateCount != 4 {
		t.Fatalf("candidate count = %d, want 4", cfg.CandidateCount)
	}
	if cfg.VerifierCount != 3 {
		t.Fatalf("verifier count = %d, want 3", cfg.VerifierCount)
	}
}

func TestSelectWeaverWinnerDeterministicTie(t *testing.T) {
	results := []weaverRunResult{
		{Candidate: weaverCandidate{ID: "candidate-1", Index: 0, Content: "a"}},
		{Candidate: weaverCandidate{ID: "candidate-2", Index: 1, Content: "b"}},
	}
	scores := []weaverVerifierScore{
		{CandidateID: "candidate-2", Score: 8},
		{CandidateID: "candidate-1", Score: 8},
	}
	winner, _ := selectWeaverWinner(results, scores)
	if winner.Candidate.ID != "candidate-1" {
		t.Fatalf("winner = %s, want candidate-1", winner.Candidate.ID)
	}
}

func TestSelectWeaverVerifierModelsUsesCatalogDiversityAndSize(t *testing.T) {
	srv := weaverSelectionServer(t, []store.SupportedModel{
		{ID: "base", DisplayName: "Base", ModelType: "text", SizeGB: 27, Family: "qwen", CanVerify: true, Active: true},
		{ID: "same-family-small", DisplayName: "Same", ModelType: "text", SizeGB: 4, Family: "qwen", CanVerify: true, Active: true},
		{ID: "different-family-large", DisplayName: "Large", ModelType: "text", SizeGB: 26, Family: "trinity", CanVerify: true, Active: true},
		{ID: "different-family-small", DisplayName: "Small", ModelType: "text", SizeGB: 8, Family: "gemma", CanVerify: true, Active: true},
		{ID: "disabled-verifier", DisplayName: "Disabled", ModelType: "text", SizeGB: 1, Family: "minimax", CanVerify: false, Active: true},
		{ID: "image-model", DisplayName: "Image", ModelType: "image", SizeGB: 1, Family: "image", CanVerify: true, Active: true},
	})

	got := srv.selectWeaverVerifierModels("base", 3)
	want := []string{"different-family-small", "different-family-large", "same-family-small"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("verifiers = %v, want %v", got, want)
	}
}

func TestSelectWeaverVerifierModelsFallsBackToBase(t *testing.T) {
	srv := weaverSelectionServer(t, []store.SupportedModel{
		{ID: "base", DisplayName: "Base", ModelType: "text", SizeGB: 27, Family: "qwen", CanVerify: true, Active: true},
		{ID: "disabled-verifier", DisplayName: "Disabled", ModelType: "text", SizeGB: 1, Family: "gemma", CanVerify: false, Active: true},
	})

	got := srv.selectWeaverVerifierModels("base", 3)
	if len(got) != 1 || got[0] != "base" {
		t.Fatalf("verifiers = %v, want [base]", got)
	}
}

func weaverSelectionServer(t *testing.T, models []store.SupportedModel) *Server {
	t.Helper()

	logger := slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	reg.MinTrustLevel = registry.TrustNone
	srv := NewServer(reg, st, logger)

	for i := range models {
		if err := st.SetSupportedModel(&models[i]); err != nil {
			t.Fatalf("SetSupportedModel(%q): %v", models[i].ID, err)
		}
	}
	srv.SyncModelCatalog()

	for _, model := range models {
		if !model.Active {
			continue
		}
		registerSelectionProvider(t, reg, model.ID)
	}
	return srv
}

func registerSelectionProvider(t *testing.T, reg *registry.Registry, modelID string) {
	t.Helper()
	providerID := "provider-" + strings.NewReplacer("/", "-", " ", "-").Replace(modelID)
	msg := &protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel: "Mac15,8",
			ChipName:     "Apple M3 Max",
			MemoryGB:     64,
		},
		Models: []protocol.ModelInfo{
			{ID: modelID, SizeBytes: 1000, ModelType: "text", Quantization: "4bit"},
		},
		Backend:                 "inprocess-mlx",
		PublicKey:               testPublicKeyB64(),
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	}
	reg.Register(providerID, nil, msg)
	reg.RecordChallengeSuccess(providerID)
}

func TestWeaverStreamingE2E(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	pubKey := testPublicKeyB64()
	regMsg := protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel: "Mac15,8",
			ChipName:     "Apple M3 Max",
			MemoryGB:     64,
		},
		Models: []protocol.ModelInfo{
			{ID: "test-model", SizeBytes: 1000, ModelType: "test", Quantization: "4bit"},
		},
		Backend:                 "inprocess-mlx",
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}

	time.Sleep(100 * time.Millisecond)
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	providerDone := make(chan struct{})
	go func() {
		defer close(providerDone)
		served := 0
		for served < 2 {
			_, data, err := conn.Read(ctx)
			if err != nil {
				t.Errorf("provider read: %v", err)
				return
			}
			var raw map[string]any
			if err := json.Unmarshal(data, &raw); err == nil {
				msgType, _ := raw["type"].(string)
				if msgType == protocol.TypeAttestationChallenge {
					respData := makeValidChallengeResponse(data, pubKey)
					_ = conn.Write(ctx, websocket.MessageText, respData)
					continue
				}
				if msgType == protocol.TypeRuntimeStatus || msgType == protocol.TypeCancel {
					continue
				}
			}
			var inferReq protocol.InferenceRequestMessage
			if err := json.Unmarshal(data, &inferReq); err != nil {
				t.Errorf("unmarshal inference request: %v", err)
				return
			}
			if served == 0 {
				writeEncryptedTestChunk(t, ctx, conn, inferReq, pubKey,
					`data: {"id":"chatcmpl-candidate","choices":[{"delta":{"content":"Answer A"}}]}`+"\n\n")
			} else {
				writeEncryptedTestChunk(t, ctx, conn, inferReq, pubKey,
					`data: {"id":"chatcmpl-verifier","choices":[{"delta":{"content":"{\"score\":9,\"rationale\":\"clear\"}"}}]}`+"\n\n")
			}
			complete := protocol.InferenceCompleteMessage{
				Type:      protocol.TypeInferenceComplete,
				RequestID: inferReq.RequestID,
				Usage:     protocol.UsageInfo{PromptTokens: 3, CompletionTokens: 2},
			}
			completeData, _ := json.Marshal(complete)
			if err := conn.Write(ctx, websocket.MessageText, completeData); err != nil {
				t.Errorf("write complete: %v", err)
				return
			}
			served++
		}
	}()

	chatBody := `{"model":"test-model","messages":[{"role":"user","content":"hi"}],"stream":true,"weaver":{"mode":"deep","candidate_count":1,"verifier_count":1,"trace":true}}`
	httpReq, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(chatBody))
	httpReq.Header.Set("Authorization", "Bearer test-key")

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status = %d, body = %s", resp.StatusCode, body)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	response := string(body)
	for _, want := range []string{"event: weaver_init", "event: candidate_delta", "event: verifier_score", "event: weaver_final", "Answer A"} {
		if !strings.Contains(response, want) {
			t.Fatalf("response missing %q:\n%s", want, response)
		}
	}
	<-providerDone

	if got := len(st.UsageRecords()); got != 2 {
		t.Fatalf("usage records = %d, want 2", got)
	}
}

func TestWeaverAllCandidatesFailTerminates(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	chatBody := `{"model":"missing-model","messages":[{"role":"user","content":"hi"}],"stream":true,"weaver":{"mode":"deep","candidate_count":2,"verifier_count":1,"trace":true}}`
	httpReq, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(chatBody))
	httpReq.Header.Set("Authorization", "Bearer test-key")

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status = %d, body = %s", resp.StatusCode, body)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	response := string(body)
	for _, want := range []string{"event: candidate_error", "event: weaver_status\ndata: {\"status\":\"failed\"}", "event: done\ndata: {\"status\":\"failed\"}"} {
		if !strings.Contains(response, want) {
			t.Fatalf("response missing %q:\n%s", want, response)
		}
	}
}

func TestWeaverMalformedVerifierOutputAbstains(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	pubKey := testPublicKeyB64()
	regMsg := protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel: "Mac15,8",
			ChipName:     "Apple M3 Max",
			MemoryGB:     64,
		},
		Models: []protocol.ModelInfo{
			{ID: "test-model", SizeBytes: 1000, ModelType: "test", Quantization: "4bit"},
		},
		Backend:                 "inprocess-mlx",
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}

	time.Sleep(100 * time.Millisecond)
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	providerDone := make(chan struct{})
	go func() {
		defer close(providerDone)
		served := 0
		for served < 2 {
			_, data, err := conn.Read(ctx)
			if err != nil {
				t.Errorf("provider read: %v", err)
				return
			}
			var raw map[string]any
			if err := json.Unmarshal(data, &raw); err == nil {
				msgType, _ := raw["type"].(string)
				if msgType == protocol.TypeAttestationChallenge {
					respData := makeValidChallengeResponse(data, pubKey)
					_ = conn.Write(ctx, websocket.MessageText, respData)
					continue
				}
				if msgType == protocol.TypeRuntimeStatus || msgType == protocol.TypeCancel {
					continue
				}
			}
			var inferReq protocol.InferenceRequestMessage
			if err := json.Unmarshal(data, &inferReq); err != nil {
				t.Errorf("unmarshal inference request: %v", err)
				return
			}
			chunk := `data: {"id":"chatcmpl-candidate","choices":[{"delta":{"content":"Answer A"}}]}` + "\n\n"
			if served == 1 {
				chunk = `data: {"id":"chatcmpl-verifier","choices":[{"delta":{"content":"not json"}}]}` + "\n\n"
			}
			writeEncryptedTestChunk(t, ctx, conn, inferReq, pubKey, chunk)
			complete := protocol.InferenceCompleteMessage{
				Type:      protocol.TypeInferenceComplete,
				RequestID: inferReq.RequestID,
				Usage:     protocol.UsageInfo{PromptTokens: 3, CompletionTokens: 2},
			}
			completeData, _ := json.Marshal(complete)
			if err := conn.Write(ctx, websocket.MessageText, completeData); err != nil {
				t.Errorf("write complete: %v", err)
				return
			}
			served++
		}
	}()

	chatBody := `{"model":"test-model","messages":[{"role":"user","content":"hi"}],"stream":true,"weaver":{"mode":"deep","candidate_count":1,"verifier_count":1,"trace":true}}`
	httpReq, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(chatBody))
	httpReq.Header.Set("Authorization", "Bearer test-key")

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status = %d, body = %s", resp.StatusCode, body)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	response := string(body)
	if !strings.Contains(response, "abstained: malformed verifier output") {
		t.Fatalf("response missing malformed abstention:\n%s", response)
	}
	if !strings.Contains(response, "event: weaver_final") {
		t.Fatalf("response missing final event:\n%s", response)
	}
	<-providerDone
}

func TestWeaverBillingChargesGenerationAndVerifierCalls(t *testing.T) {
	srv, _, ledger := billingTestServer(t)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	const consumerID = "test-key"
	const model = "billing-weaver-model"
	initialBalance := ledger.Balance(consumerID)
	if initialBalance <= 0 {
		t.Fatalf("initial balance = %d, want > 0", initialBalance)
	}

	conn, _, pubKey := setupProviderForBilling(t, ctx, ts, srv.registry, model)
	defer conn.Close(websocket.StatusNormalClosure, "")

	candidateUsage := protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 5}
	verifierUsage := protocol.UsageInfo{PromptTokens: 20, CompletionTokens: 3}
	providerDone := serveWeaverBillingInferences(ctx, t, conn, pubKey, candidateUsage, verifierUsage)

	chatBody := `{"model":"` + model + `","messages":[{"role":"user","content":"hi"}],"stream":true,"max_tokens":16,"weaver":{"mode":"deep","candidate_count":1,"verifier_count":1,"trace":true}}`
	httpReq, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(chatBody))
	httpReq.Header.Set("Authorization", "Bearer "+consumerID)

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status = %d, body = %s", resp.StatusCode, body)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	response := string(body)
	for _, want := range []string{"event: weaver_final", "billing candidate"} {
		if !strings.Contains(response, want) {
			t.Fatalf("response missing %q:\n%s", want, response)
		}
	}
	<-providerDone

	expectedCost := payments.CalculateCost(model, candidateUsage.PromptTokens, candidateUsage.CompletionTokens) +
		payments.CalculateCost(model, verifierUsage.PromptTokens, verifierUsage.CompletionTokens)
	actualBalance := ledger.Balance(consumerID)
	if actualBalance != initialBalance-expectedCost {
		t.Fatalf("consumer balance = %d, want %d", actualBalance, initialBalance-expectedCost)
	}

	usageEntries := ledger.Usage(consumerID)
	if len(usageEntries) != 2 {
		t.Fatalf("usage entries = %d, want 2", len(usageEntries))
	}
	var actualCost int64
	for _, entry := range usageEntries {
		actualCost += entry.CostMicroUSD
	}
	if actualCost != expectedCost {
		t.Fatalf("usage cost = %d, want %d", actualCost, expectedCost)
	}
}

func serveWeaverBillingInferences(ctx context.Context, t *testing.T, conn *websocket.Conn, pubKey string, candidateUsage, verifierUsage protocol.UsageInfo) <-chan struct{} {
	t.Helper()
	done := make(chan struct{})
	go func() {
		defer close(done)
		served := 0
		for served < 2 {
			_, data, err := conn.Read(ctx)
			if err != nil {
				t.Errorf("provider read: %v", err)
				return
			}
			var raw map[string]any
			if err := json.Unmarshal(data, &raw); err == nil {
				msgType, _ := raw["type"].(string)
				if msgType == protocol.TypeAttestationChallenge {
					respData := makeValidChallengeResponse(data, pubKey)
					_ = conn.Write(ctx, websocket.MessageText, respData)
					continue
				}
				if msgType == protocol.TypeRuntimeStatus || msgType == protocol.TypeCancel {
					continue
				}
			}
			var inferReq protocol.InferenceRequestMessage
			if err := json.Unmarshal(data, &inferReq); err != nil {
				t.Errorf("unmarshal inference request: %v", err)
				return
			}
			usage := candidateUsage
			chunk := `data: {"id":"chatcmpl-candidate","choices":[{"delta":{"content":"billing candidate"}}]}` + "\n\n"
			if served == 1 {
				usage = verifierUsage
				chunk = `data: {"id":"chatcmpl-verifier","choices":[{"delta":{"content":"{\"score\":9,\"rationale\":\"clear\"}"}}]}` + "\n\n"
			}
			writeEncryptedTestChunk(t, ctx, conn, inferReq, pubKey, chunk)
			complete := protocol.InferenceCompleteMessage{
				Type:      protocol.TypeInferenceComplete,
				RequestID: inferReq.RequestID,
				Usage:     usage,
			}
			completeData, _ := json.Marshal(complete)
			if err := conn.Write(ctx, websocket.MessageText, completeData); err != nil {
				t.Errorf("write complete: %v", err)
				return
			}
			served++
		}
	}()
	return done
}
