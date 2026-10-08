package app_test

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/app"
	"github.com/eigeninference/d-inference/coordinator/config"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
	"nhooyr.io/websocket"
)

// Run must not reinstall the old Gemma default or honor a stale host setting.
// Exercise its real store, registry, server, attestation and encrypted dispatch,
// rather than constructing a registry whose default already has no policy.
func TestRegistryStartupIgnoresRetiredDedicatedModels(t *testing.T) {
	const adminKey = "registry-startup-test-key"
	const publishingKey = "registry-startup-publishing-key"
	const gemma, qwen = "gemma-4-26b-startup-test", "qwen-3-startup-test"
	fileHash := sha256.Sum256([]byte("{}"))
	modelHash := fmt.Sprintf("%x", sha256.Sum256(fileHash[:]))
	cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		for _, model := range []string{gemma, qwen} {
			prefix := testkit.ModelPrefix(model, "v1")
			switch r.URL.Path {
			case "/" + prefix + "/manifest.json":
				_ = json.NewEncoder(w).Encode(store.ModelManifest{
					SchemaVersion: 1, ModelID: model, Version: "v1", R2Prefix: prefix,
					AggregateSHA256: modelHash, TotalSizeBytes: 2, FileCount: 1,
					Files: []store.ManifestFile{{Path: "config.json", SizeBytes: 2, SHA256: fmt.Sprintf("%x", fileHash), Role: "config"}},
				})
				return
			case "/" + prefix + "/config.json":
				w.Header().Set("Content-Length", "2")
				_, _ = io.WriteString(w, "{}")
				return
			}
		}
		http.NotFound(w, r)
	}))
	t.Cleanup(cdn.Close)
	t.Setenv("MODEL_REGISTRY_CDN_BASE_URL", cdn.URL)
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", publishingKey)
	for key, value := range map[string]string{
		"EIGENINFERENCE_DATABASE_URL":           "",
		"EIGENINFERENCE_ALLOW_MEMORY_STORE":     "true",
		"EIGENINFERENCE_ADMIN_KEY":              adminKey,
		"EIGENINFERENCE_DRAIN_GRACE":            "1s",
		"EIGENINFERENCE_MIN_TRUST":              "self_signed",
		"EIGENINFERENCE_KNOWN_TEMPLATE_HASHES":  "mlx_metallib=" + testkit.ModelHash,
		"EIGENINFERENCE_KNOWN_BINARY_HASHES":    "",
		"EIGENINFERENCE_BINARYHASH_ENFORCE":     "false",
		"EIGENINFERENCE_RELEASE_POLICY_MODE":    "shadow",
		"EIGENINFERENCE_REJECT_MODELS":          "",
		"EIGENINFERENCE_TTFT_HARD_REJECT":       "false",
		"EIGENINFERENCE_MDM_URL":                "",
		"EIGENINFERENCE_PPROF_ADDR":             "",
		"EIGENINFERENCE_PROMPT_SIDECAR_ENABLED": "false",
		"EIGENINFERENCE_WARM_POOL_ENABLED":      "false",
		"EIGENINFERENCE_CACHE_ROUTING_MODE":     "off",
		"EIGENINFERENCE_CACHE_ROUTING_PERSIST":  "false",
		"DD_API_KEY":                            "",
		"DD_AGENT_HOST":                         "",
		"PRIVY_APP_ID":                          "",
		"APNS_KEY_ID":                           "",
		"APNS_TEAM_ID":                          "",
	} {
		t.Setenv(key, value)
	}

	guard := make(chan os.Signal, 16)
	signal.Notify(guard, syscall.SIGTERM)
	t.Cleanup(func() { signal.Stop(guard) })

	for _, tc := range []struct {
		name, value string
		unset       bool
	}{
		{name: "absent", unset: true},
		{name: "empty"},
		{name: "previously disabled", value: "none"},
		{name: "stale family list", value: " GEMMA-4 , legacy-model "},
	} {
		t.Run(tc.name, func(t *testing.T) {
			const legacyEnv = "EIGENINFERENCE_DEDICATED_MODELS"
			t.Setenv(legacyEnv, tc.value)
			if tc.unset {
				if err := os.Unsetenv(legacyEnv); err != nil {
					t.Fatal(err)
				}
			}
			t.Setenv("EIGENINFERENCE_PORT", testkit.FreeListenPort(t))
			cfg := config.ReadAppConfig()
			cfg.RegistryCfg.Autopilot.Enabled = false
			if err := cfg.Check(); err != nil {
				t.Fatalf("config: %v", err)
			}

			var logs startupLog
			done := make(chan struct{})
			go func() {
				defer close(done)
				app.Run(cfg, slog.New(slog.NewTextHandler(&logs, nil)))
			}()
			t.Cleanup(func() {
				tick := time.NewTicker(50 * time.Millisecond)
				defer tick.Stop()
				timeout := time.NewTimer(30 * time.Second)
				defer timeout.Stop()
				for {
					select {
					case <-done:
						if !strings.Contains(logs.String(), "coordinator stopped") {
							t.Errorf("Run did not shut down cleanly:\n%s", logs.String())
						}
						return
					case <-tick.C:
						_ = syscall.Kill(os.Getpid(), syscall.SIGTERM)
					case <-timeout.C:
						t.Fatalf("Run did not stop after SIGTERM:\n%s", logs.String())
					}
				}
			})

			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			baseURL := "http://127.0.0.1:" + cfg.ServerConfig.Port
			client := &http.Client{Timeout: 2 * time.Second}
			waitFor := func(what string, ready func() bool) {
				t.Helper()
				for !ready() {
					select {
					case <-done:
						t.Fatalf("Run stopped before %s:\n%s", what, logs.String())
					case <-ctx.Done():
						t.Fatalf("timed out waiting for %s:\n%s", what, logs.String())
					case <-time.After(50 * time.Millisecond):
					}
				}
			}
			waitFor("healthy server", func() bool {
				resp, err := client.Get(baseURL + "/health")
				if err != nil {
					return false
				}
				resp.Body.Close()
				return resp.StatusCode == http.StatusOK
			})

			post := func(path string, body any, key string, wantStatus int) []byte {
				t.Helper()
				payload, err := json.Marshal(body)
				if err != nil {
					t.Fatal(err)
				}
				req, err := testkit.NewAuthRequest(t, ctx, baseURL+path, string(payload), key)
				if err != nil {
					t.Fatal(err)
				}
				resp, err := client.Do(req)
				if err != nil {
					t.Fatal(err)
				}
				data, err := io.ReadAll(resp.Body)
				resp.Body.Close()
				if err != nil || resp.StatusCode != wantStatus {
					t.Fatalf("%s = %d %s: %v\n%s", path, resp.StatusCode, data, err, logs.String())
				}
				return data
			}
			for _, model := range []string{gemma, qwen} {
				post("/v1/admin/models/register", map[string]any{
					"model_id": model, "version": "v1", "quantization": "4bit",
					"hugging_face_artifact": &store.HuggingFaceArtifact{RepoID: "Example/startup-test", Revision: strings.Repeat("a", 40), PathPrefix: "mlx"},
					"max_context_length":    32768, "max_output_length": 8192, "min_ram_gb": 16,
					"capabilities": []string{"chat"}, "promote": true,
					"input_price": 50000, "output_price": 200000,
				}, publishingKey, http.StatusOK)
			}
			post("/v1/admin/invite-codes", map[string]any{"code": "STARTUP-TEST", "amount_usd": 1}, adminKey, http.StatusCreated)
			post("/v1/invite/redeem", map[string]any{"code": "STARTUP-TEST"}, adminKey, http.StatusOK)
			pubKey := testkit.PublicKeyB64()
			runtimeHashes := map[string]string{"mlx_metallib": testkit.ModelHash}
			conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(baseURL, "http")+"/ws/provider", nil)
			if err != nil {
				t.Fatal(err)
			}
			defer conn.CloseNow()
			write := func(msg any) {
				t.Helper()
				data, err := json.Marshal(msg)
				if err != nil {
					t.Fatal(err)
				}
				if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
					t.Fatal(err)
				}
			}
			registration := protocol.RegisterMessage{
				Type: protocol.TypeRegister,
				Hardware: protocol.Hardware{
					MachineModel: "Mac15,8", ChipName: "Apple M3 Max", MemoryGB: 64,
				},
				Models: []protocol.ModelInfo{
					{ID: gemma, ModelType: "chat", Quantization: "4bit", SizeBytes: 2, WeightHash: modelHash},
					{ID: qwen, ModelType: "chat", Quantization: "4bit", SizeBytes: 2, WeightHash: modelHash},
				},
				Backend:                 registry.BackendMLXSwift,
				Version:                 api.LatestProviderVersion,
				PublicKey:               pubKey,
				Attestation:             testkit.CreateAttestationJSON(t, pubKey),
				EncryptedResponseChunks: true,
				PrivacyCapabilities:     testkit.PrivacyCaps(),
				TemplateHashes:          runtimeHashes,
				DecodeTPS:               200,
				PrefillTPS:              1000,
			}
			write(registration)
			write(protocol.HeartbeatMessage{
				Type: protocol.TypeHeartbeat, Status: "serving", WarmModels: []string{gemma, qwen},
				SystemMetrics: protocol.SystemMetrics{MemoryPressure: 0.1, CPUUsage: 0.1, ThermalState: "nominal"},
				BackendCapacity: &protocol.BackendCapacity{
					TotalMemoryGB: 64,
					Slots: []protocol.BackendSlotCapacity{
						{Model: gemma, State: "running", MaxConcurrency: 8, ActiveTokenBudgetMax: 32_768},
						{Model: qwen, State: "running", MaxConcurrency: 8, ActiveTokenBudgetMax: 32_768},
					},
				},
			})
			providerDone := make(chan struct{})
			go func() {
				defer close(providerDone)
				serveRegistryStartupProvider(t, ctx, conn, registration)
			}()
			defer func() {
				conn.CloseNow()
				<-providerDone
			}()

			waitFor("attested mixed provider", func() bool {
				resp, err := client.Get(baseURL + "/v1/models/capacity")
				if err != nil {
					return false
				}
				defer resp.Body.Close()
				var capacity struct {
					Models []registry.ModelCapacity `json:"models"`
				}
				if json.NewDecoder(resp.Body).Decode(&capacity) != nil {
					return false
				}
				for _, model := range capacity.Models {
					if model.ModelID == qwen && model.CanAccept && model.WarmProviders == 1 {
						return true
					}
				}
				return false
			})

			for _, model := range []string{gemma, qwen} {
				data := post("/v1/chat/completions", map[string]any{
					"model": model, "stream": true, "max_tokens": 64,
					"messages": []map[string]string{{"role": "user", "content": "hello"}},
				}, adminKey, http.StatusOK)
				if !strings.Contains(string(data), "mixed-startup-served") {
					t.Fatalf("%s lost encrypted provider content: %s", model, data)
				}
			}
			if strings.Contains(logs.String(), "dedicated-model routing") {
				t.Fatalf("retired routing policy still logged during startup:\n%s", logs.String())
			}
		})
	}
}

func serveRegistryStartupProvider(t *testing.T, ctx context.Context, conn *websocket.Conn, registration protocol.RegisterMessage) {
	t.Helper()
	modelHashes := make(map[string]string, len(registration.Models))
	for _, model := range registration.Models {
		modelHashes[model.ID] = model.WeightHash
	}
	publicKey := registration.PublicKey
	testkit.HandleProviderMessages(ctx, t, conn, func(kind string, data []byte) []byte {
		switch kind {
		case protocol.TypeAttestationChallenge:
			var challenge protocol.AttestationChallengeMessage
			if err := json.Unmarshal(data, &challenge); err != nil {
				t.Errorf("decode challenge: %v", err)
				return nil
			}
			verified := true
			response := protocol.AttestationResponseMessage{
				Type: protocol.TypeAttestationResponse, Nonce: challenge.Nonce, PublicKey: publicKey,
				Signature:         testkit.ChallengeSignature(challenge.Nonce, challenge.Timestamp, publicKey),
				RDMADisabled:      &verified,
				SIPEnabled:        &verified,
				SecureBootEnabled: &verified,
				TemplateHashes:    registration.TemplateHashes,
				ModelHashes:       modelHashes,
			}
			response.StatusSignature = testkit.ResponseStatusSignature(challenge.Nonce, challenge.Timestamp, publicKey, &response)
			out, _ := json.Marshal(response)
			return out
		case protocol.TypeInferenceRequest:
			var request protocol.InferenceRequestMessage
			if err := json.Unmarshal(data, &request); err != nil {
				t.Errorf("decode inference: %v", err)
				return nil
			}
			testkit.WriteEncryptedChunk(t, ctx, conn, request, publicKey,
				"data: {\"choices\":[{\"delta\":{\"content\":\"mixed-startup-served\"}}]}\n\n")
			out, _ := json.Marshal(protocol.InferenceCompleteMessage{
				Type: protocol.TypeInferenceComplete, RequestID: request.RequestID,
				Usage: protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 5},
			})
			return out
		}
		return nil
	})
}
