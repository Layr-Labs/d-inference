package api

import (
	"context"
	"encoding/json"
	"fmt"
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
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

func TestServiceReasoningPolicyProviderBody(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = 200 * time.Millisecond

	const serviceAccount = "service-reasoning-test"
	if err := st.CreateUser(&store.User{
		AccountID:   serviceAccount,
		PrivyUserID: "did:privy:" + serviceAccount,
		Role:        store.RoleService,
	}); err != nil {
		t.Fatal(err)
	}
	serviceKey, _, err := st.CreateAPIKey(serviceAccount, store.APIKeyCreate{Name: "reasoning-test"})
	if err != nil {
		t.Fatal(err)
	}
	if err := st.Credit(serviceAccount, 100_000_000, store.LedgerDeposit, "reasoning-test"); err != nil {
		t.Fatal(err)
	}

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	publicKey := testPublicKeyB64()
	value, ok := testProviderKeys.Load(publicKey)
	if !ok {
		t.Fatalf("missing cached provider keypair for %q", publicKey)
	}
	keypair := value.(testProviderKeyPair)
	const otherModel = "reasoning-policy-other-model"
	const qwenAlias = "reasoning-policy-qwen-alias"
	conn := connectProvider(t, ctx, ts.URL, reg, []protocol.ModelInfo{
		{ID: serviceReasoningOptInModel},
		{ID: otherModel},
	}, publicKey)
	defer conn.Close(websocket.StatusNormalClosure, "")
	reg.SetModelAliases(map[string]registry.AliasTarget{
		qwenAlias: {Desired: serviceReasoningOptInModel},
	})
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	type providerResult struct {
		body []byte
		err  error
	}
	results := make(chan providerResult, 7)
	go func() {
		for {
			_, data, readErr := conn.Read(ctx)
			if readErr != nil {
				results <- providerResult{err: readErr}
				return
			}
			var envelope struct {
				Type string `json:"type"`
			}
			if unmarshalErr := json.Unmarshal(data, &envelope); unmarshalErr != nil {
				results <- providerResult{err: unmarshalErr}
				return
			}
			if envelope.Type == protocol.TypeAttestationChallenge {
				if writeErr := conn.Write(ctx, websocket.MessageText, makeValidChallengeResponse(data, publicKey)); writeErr != nil {
					results <- providerResult{err: writeErr}
					return
				}
				continue
			}
			if envelope.Type != protocol.TypeInferenceRequest {
				continue
			}

			var request protocol.InferenceRequestMessage
			if unmarshalErr := json.Unmarshal(data, &request); unmarshalErr != nil {
				results <- providerResult{err: unmarshalErr}
				return
			}
			if request.EncryptedBody == nil {
				results <- providerResult{err: errMissingEncryptedProviderBody}
				return
			}
			decrypted, decryptErr := e2e.DecryptWithPrivateKey(&e2e.EncryptedPayload{
				EphemeralPublicKey: request.EncryptedBody.EphemeralPublicKey,
				Ciphertext:         request.EncryptedBody.Ciphertext,
			}, keypair.private)
			results <- providerResult{body: decrypted, err: decryptErr}
			if decryptErr != nil {
				return
			}

			writeEncryptedTestChunk(t, ctx, conn.Conn, request, publicKey, `data: {"id":"chatcmpl-reasoning-policy","choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}`+"\n\n")
			complete, _ := json.Marshal(protocol.InferenceCompleteMessage{
				Type:      protocol.TypeInferenceComplete,
				RequestID: request.RequestID,
				Usage:     protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 1},
			})
			if writeErr := conn.Write(ctx, websocket.MessageText, complete); writeErr != nil {
				return
			}
		}
	}()

	tests := []struct {
		name          string
		key           string
		path          string
		model         string
		reasoning     string
		responsesBody bool
		wantReasoning string
		wantModel     string
	}{
		{name: "service Qwen omission disables reasoning", key: serviceKey, model: serviceReasoningOptInModel, wantReasoning: `{"enabled":false}`, wantModel: serviceReasoningOptInModel},
		{name: "service Qwen explicit true is preserved", key: serviceKey, model: serviceReasoningOptInModel, reasoning: `,"reasoning":{"enabled":true}`, wantReasoning: `{"enabled":true}`, wantModel: serviceReasoningOptInModel},
		{name: "service Qwen explicit false is preserved", key: serviceKey, model: serviceReasoningOptInModel, reasoning: `,"reasoning":{"enabled":false}`, wantReasoning: `{"enabled":false}`, wantModel: serviceReasoningOptInModel},
		{name: "non-service Qwen omission is unchanged", key: "test-key", model: serviceReasoningOptInModel, wantModel: serviceReasoningOptInModel},
		{name: "service other model omission is unchanged", key: serviceKey, model: otherModel, wantModel: otherModel},
		{name: "service alias resolved to Qwen disables reasoning", key: serviceKey, model: qwenAlias, wantReasoning: `{"enabled":false}`, wantModel: serviceReasoningOptInModel},
		{name: "service Responses route remains unchanged", key: serviceKey, path: "/v1/responses", model: serviceReasoningOptInModel, responsesBody: true, wantModel: serviceReasoningOptInModel},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			path := test.path
			if path == "" {
				path = "/v1/chat/completions"
			}
			requestBody := fmt.Sprintf(
				`{"model":%q,"messages":[{"role":"user","content":"hello"}],"stream":true,"max_tokens":32%s}`,
				test.model, test.reasoning)
			if test.responsesBody {
				requestBody = fmt.Sprintf(
					`{"model":%q,"input":"hello","stream":true,"max_output_tokens":32}`,
					test.model)
			}
			request, requestErr := http.NewRequestWithContext(
				ctx, http.MethodPost, ts.URL+path, strings.NewReader(requestBody))
			if requestErr != nil {
				t.Fatal(requestErr)
			}
			request.Header.Set("Authorization", "Bearer "+test.key)
			response, requestErr := http.DefaultClient.Do(request)
			if requestErr != nil {
				t.Fatal(requestErr)
			}
			responseBody, readErr := io.ReadAll(response.Body)
			response.Body.Close()
			if readErr != nil {
				t.Fatal(readErr)
			}
			if response.StatusCode != http.StatusOK {
				t.Fatalf("status = %d, want 200: %s", response.StatusCode, responseBody)
			}

			var result providerResult
			select {
			case result = <-results:
			case <-time.After(5 * time.Second):
				t.Fatal("timed out waiting for provider body")
			}
			if result.err != nil {
				t.Fatalf("decrypt provider body: %v", result.err)
			}
			var fields map[string]json.RawMessage
			if unmarshalErr := json.Unmarshal(result.body, &fields); unmarshalErr != nil {
				t.Fatalf("decode provider body: %v\n%s", unmarshalErr, result.body)
			}
			var gotModel string
			if unmarshalErr := json.Unmarshal(fields["model"], &gotModel); unmarshalErr != nil {
				t.Fatalf("decode provider model: %v", unmarshalErr)
			}
			if gotModel != test.wantModel {
				t.Errorf("provider model = %q, want %q", gotModel, test.wantModel)
			}
			gotReasoning, exists := fields["reasoning"]
			if test.wantReasoning == "" {
				if exists {
					t.Errorf("provider body unexpectedly contains reasoning: %s", gotReasoning)
				}
			} else if !exists || string(gotReasoning) != test.wantReasoning {
				t.Errorf("provider reasoning = %s (exists=%v), want %s", gotReasoning, exists, test.wantReasoning)
			}
		})
	}
}

func TestServiceReasoningPolicyTracksAliasCapacityFallback(t *testing.T) {
	tests := []struct {
		name          string
		desiredModel  string
		previousModel string
		wantReasoning string
	}{
		{
			name:          "fallback away from Qwen removes injected default",
			desiredModel:  serviceReasoningOptInModel,
			previousModel: "reasoning-fallback-other",
		},
		{
			name:          "fallback toward Qwen injects default",
			desiredModel:  "reasoning-fallback-other",
			previousModel: serviceReasoningOptInModel,
			wantReasoning: `{"enabled":false}`,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
			st := store.NewMemory(store.Config{AdminKey: "test-key"})
			reg := registry.New(logger)
			srv := NewServer(reg, st, ServerConfig{}, logger)
			srv.challengeInterval = 30 * time.Second

			const serviceAccount = "service-reasoning-fallback"
			if err := st.CreateUser(&store.User{
				AccountID:   serviceAccount,
				PrivyUserID: "did:privy:" + serviceAccount,
				Role:        store.RoleService,
			}); err != nil {
				t.Fatal(err)
			}
			serviceKey, _, err := st.CreateAPIKey(serviceAccount, store.APIKeyCreate{Name: "reasoning-fallback"})
			if err != nil {
				t.Fatal(err)
			}
			if err := st.Credit(serviceAccount, 100_000_000, store.LedgerDeposit, "reasoning-fallback"); err != nil {
				t.Fatal(err)
			}

			ts := httptest.NewServer(srv.Handler())
			t.Cleanup(ts.Close)
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()

			registerBuildsProvider(srv, "reasoning-fallback-desired", test.desiredModel)
			desired := reg.GetProvider("reasoning-fallback-desired")
			desired.Mu().Lock()
			desired.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = 1_000
			desired.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 1_000
			desired.Mu().Unlock()

			previous := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
				Name:      "reasoning-fallback-previous",
				Version:   "0.6.4",
				DecodeTPS: 100,
				Models:    []failoverModelSpec{{ID: test.previousModel}},
				Script:    fullServeScript(test.previousModel),
			})
			const alias = "reasoning-policy-fallback-alias"
			reg.SetModelAliases(map[string]registry.AliasTarget{
				alias: {Desired: test.desiredModel, Previous: test.previousModel},
			})

			requestBody := fmt.Sprintf(
				`{"model":%q,"messages":[{"role":"user","content":"hello"}],"stream":true,"max_tokens":32}`,
				alias)
			status, responseBody, err := postChat(ctx, ts.URL, serviceKey, requestBody)
			if err != nil {
				t.Fatalf("chat request: %v", err)
			}
			if status != http.StatusOK {
				t.Fatalf("status = %d, want 200: %s", status, responseBody)
			}

			var providerBody []byte
			select {
			case providerBody = <-previous.bodies:
			case <-time.After(5 * time.Second):
				t.Fatal("previous provider never received fallback dispatch")
			}
			if providerBody == nil {
				t.Fatal("previous provider could not decrypt fallback body")
			}
			var fields map[string]json.RawMessage
			if err := json.Unmarshal(providerBody, &fields); err != nil {
				t.Fatalf("decode provider body: %v\n%s", err, providerBody)
			}
			var gotModel string
			if err := json.Unmarshal(fields["model"], &gotModel); err != nil {
				t.Fatal(err)
			}
			if gotModel != test.previousModel {
				t.Errorf("provider model = %q, want fallback model %q", gotModel, test.previousModel)
			}
			gotReasoning, exists := fields["reasoning"]
			if test.wantReasoning == "" {
				if exists {
					t.Errorf("fallback provider body retained reasoning: %s", gotReasoning)
				}
			} else if !exists || string(gotReasoning) != test.wantReasoning {
				t.Errorf("fallback provider reasoning = %s (exists=%v), want %s", gotReasoning, exists, test.wantReasoning)
			}
		})
	}
}

func TestApplyResolvedModelReasoningPolicyPreservesExplicitValuesAndUntouchedBytes(t *testing.T) {
	tests := []struct {
		name     string
		body     string
		model    string
		service  bool
		provided bool
	}{
		{name: "explicit null", body: `{"model":"qwen","reasoning":null}`, model: serviceReasoningOptInModel, service: true, provided: true},
		{name: "explicit scalar", body: `{"model":"qwen","reasoning":"malformed"}`, model: serviceReasoningOptInModel, service: true, provided: true},
		{name: "non-service target", body: `{ "model" : "qwen" }`, model: serviceReasoningOptInModel},
		{name: "service other model", body: `{ "model" : "other" }`, model: "other", service: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			parsed, err := decodeInferenceJSONObject([]byte(test.body))
			if err != nil {
				t.Fatal(err)
			}
			got, changed, err := applyResolvedModelReasoningPolicy(
				parsed, []byte(test.body), test.model, test.service, test.provided)
			if err != nil {
				t.Fatal(err)
			}
			if changed {
				t.Fatal("policy reported a mutation")
			}
			if string(got) != test.body {
				t.Fatalf("body changed: got %q, want original %q", got, test.body)
			}
		})
	}
}
