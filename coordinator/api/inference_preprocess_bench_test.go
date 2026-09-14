package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/internal/inferencefixture"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

// newBenchServer builds a coordinator with the desired/previous builds in the
// registry store (desired carries catalog runtime defaults so the
// runtime-defaults rewrite fires) and the alias pointing at them.
func newBenchServer(tb testing.TB) (*Server, *registry.Registry, *store.MemoryStore) {
	tb.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	inferencefixture.SeedModel(tb, st, inferencefixture.DesiredBuild, map[string]any{
		"reasoning_parser": "qwen3",
		"tool_call_parser": "qwen3_coder",
	})
	inferencefixture.SeedModel(tb, st, inferencefixture.PreviousBuild, nil)
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = time.Hour
	srv.SyncModelCatalog()
	reg.SetModelAliases(map[string]registry.AliasTarget{
		inferencefixture.Alias: {Desired: inferencefixture.DesiredBuild, Previous: inferencefixture.PreviousBuild},
	})
	return srv, reg, st
}

type benchEnv struct {
	ts     *httptest.Server
	conn   *websocket.Conn
	cancel context.CancelFunc
	client *http.Client
}

func (e *benchEnv) close() {
	e.cancel()
	_ = e.conn.Close(websocket.StatusNormalClosure, "bench done")
	e.ts.Close()
}

// newBenchEnv starts the coordinator and one trusted, vision-capable fake
// provider that answers challenges and serves every dispatch with a role
// chunk, one content chunk, and a completion.
func newBenchEnv(b *testing.B) *benchEnv {
	b.Helper()
	srv, reg, _ := newBenchServer(b)
	ts := httptest.NewServer(srv.Handler())
	ctx, cancel := context.WithCancel(context.Background())

	pubKey := testPublicKeyB64()
	value, ok := testProviderKeys.Load(pubKey)
	if !ok {
		b.Fatalf("missing cached provider keypair for %q", pubKey)
	}
	keypair := value.(testProviderKeyPair)

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		b.Fatalf("websocket dial: %v", err)
	}
	conn.SetReadLimit(64 << 20)
	regMsg := protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel: "Mac15,8", ChipName: "Apple M3 Max", MemoryGB: 64,
		},
		Models: []protocol.ModelInfo{
			{ID: inferencefixture.DesiredBuild, ModelType: "chat", Quantization: "4bit", IsVision: true},
			{ID: inferencefixture.PreviousBuild, ModelType: "chat", Quantization: "4bit", IsVision: true},
		},
		Backend:                 "mlx-swift",
		Version:                 "0.8.0",
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		DecodeTPS:               100,
		PrivacyCapabilities:     testPrivacyCaps(),
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		b.Fatalf("write register: %v", err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for len(reg.ProviderIDs()) == 0 {
		if time.Now().After(deadline) {
			b.Fatal("provider never registered")
		}
		time.Sleep(10 * time.Millisecond)
	}
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}
	go benchProviderLoop(ctx, conn, pubKey, keypair)
	return &benchEnv{ts: ts, conn: conn, cancel: cancel, client: ts.Client()}
}

func benchEncryptedChunk(req protocol.InferenceRequestMessage, keypair testProviderKeyPair, sse string) ([]byte, error) {
	if req.EncryptedBody == nil {
		return nil, fmt.Errorf("inference request %s missing encrypted body", req.RequestID)
	}
	coordinatorPub, err := e2e.ParsePublicKey(req.EncryptedBody.EphemeralPublicKey)
	if err != nil {
		return nil, err
	}
	payload, err := e2e.Encrypt([]byte(sse), coordinatorPub, &e2e.SessionKeys{
		PublicKey: keypair.public, PrivateKey: keypair.private,
	})
	if err != nil {
		return nil, err
	}
	return json.Marshal(protocol.InferenceResponseChunkMessage{
		Type:      protocol.TypeInferenceResponseChunk,
		RequestID: req.RequestID,
		EncryptedData: &protocol.EncryptedPayload{
			EphemeralPublicKey: payload.EphemeralPublicKey,
			Ciphertext:         payload.Ciphertext,
		},
	})
}

func benchProviderLoop(ctx context.Context, conn *websocket.Conn, pubKey string, keypair testProviderKeyPair) {
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			return
		}
		var envelope struct {
			Type string `json:"type"`
		}
		if json.Unmarshal(data, &envelope) != nil {
			continue
		}
		switch envelope.Type {
		case protocol.TypeAttestationChallenge:
			if err := conn.Write(ctx, websocket.MessageText, makeValidChallengeResponse(data, pubKey)); err != nil {
				return
			}
		case protocol.TypeInferenceRequest:
			var req protocol.InferenceRequestMessage
			if json.Unmarshal(data, &req) != nil {
				continue
			}
			// The body is deliberately NOT decrypted: the benchmark measures the
			// coordinator, and a 3 MB NaCl open on the fake provider would only
			// add provider-side noise to the process-wide allocation numbers.
			for _, sse := range []string{
				roleOnlyChunkSSE(inferencefixture.DesiredBuild),
				contentChunkSSE(inferencefixture.DesiredBuild, "bench"),
			} {
				frame, err := benchEncryptedChunk(req, keypair, sse)
				if err != nil {
					return
				}
				if err := conn.Write(ctx, websocket.MessageText, frame); err != nil {
					return
				}
			}
			complete, _ := json.Marshal(protocol.InferenceCompleteMessage{
				Type: protocol.TypeInferenceComplete, RequestID: req.RequestID,
				Usage: protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 1},
			})
			if err := conn.Write(ctx, websocket.MessageText, complete); err != nil {
				return
			}
		}
	}
}

func (e *benchEnv) post(body []byte) (int, error) {
	req, err := http.NewRequest(http.MethodPost, e.ts.URL+"/v1/chat/completions", bytes.NewReader(body))
	if err != nil {
		return 0, err
	}
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", "application/json")
	resp, err := e.client.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, fmt.Errorf("status %d: %s", resp.StatusCode, msg)
	}
	_, err = io.Copy(io.Discard, resp.Body)
	return resp.StatusCode, err
}

func BenchmarkChatCompletionsHTTP(b *testing.B) {
	bodies := inferencefixture.RequestBodies()
	for _, name := range inferencefixture.BodyNames {
		body := bodies[name]
		b.Run(name, func(b *testing.B) {
			env := newBenchEnv(b)
			defer env.close()
			// Warm the path once (provider registration, alias catalog, HTTP
			// keep-alive) before timing.
			if _, err := env.post(body); err != nil {
				b.Fatal(err)
			}
			b.ReportAllocs()
			b.SetBytes(int64(len(body)))
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				if _, err := env.post(body); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}
