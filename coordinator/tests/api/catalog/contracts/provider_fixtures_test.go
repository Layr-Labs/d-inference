package catalog_test

import (
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
	"nhooyr.io/websocket"
)

func testPublicKeyB64() string {
	key, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		panic(err)
	}
	return base64.StdEncoding.EncodeToString(key.PublicKey().Bytes())
}

// The provider speaks the real registration protocol; trust is local fixture
// state because these tests cover catalog HTTP responses, not attestation.
func connectAndPrepareProvider(t *testing.T, ctx context.Context, url string, reg *registry.Registry, model, key string, tps float64) *websocket.Conn {
	t.Helper()
	conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(url, "http")+"/ws/provider", nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.CloseNow() })
	message := protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{MachineModel: "Mac15,8", ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:   []protocol.ModelInfo{{ID: model, ModelType: "test", Quantization: "4bit"}},
		Backend:  "mlx-swift", PublicKey: key, EncryptedResponseChunks: true, DecodeTPS: tps,
		PrivacyCapabilities: &protocol.PrivacyCapabilities{TextBackendInprocess: true, TextProxyDisabled: true, SIPEnabled: true, AntiDebugEnabled: true, CoreDumpsDisabled: true, EnvScrubbed: true},
	}
	if model == registry.Qwen38NAXModelID {
		message.Hardware.ChipName = "Apple M5 Max"
		message.Hardware.ChipFamily = "M5"
		message.RuntimeCapabilities = []string{registry.ProviderCapabilityAppleM5, registry.ProviderCapabilityMLXNAX}
		message.TemplateHashes = map[string]string{"mlx_metallib": testkit.ModelHash}
	}
	raw, err := json.Marshal(message)
	if err != nil {
		t.Fatal(err)
	}
	if err := conn.Write(ctx, websocket.MessageText, raw); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for len(reg.ProviderIDs()) == 0 {
		if time.Now().After(deadline) {
			t.Fatal("provider registration timed out")
		}
		time.Sleep(time.Millisecond)
	}
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}
	return conn
}
