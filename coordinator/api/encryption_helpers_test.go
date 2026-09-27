package api

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"sync"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"golang.org/x/crypto/nacl/box"
	"nhooyr.io/websocket"
)

type testProviderKeyPair struct {
	public  [32]byte
	private [32]byte
}

var testProviderKeys sync.Map

func testPrivacyCaps() *protocol.PrivacyCapabilities {
	return &protocol.PrivacyCapabilities{
		TextBackendInprocess:    true,
		TextProxyDisabled:       true,
		PythonRuntimeLocked:     true,
		DangerousModulesBlocked: true,
		SIPEnabled:              true,
		AntiDebugEnabled:        true,
		CoreDumpsDisabled:       true,
		EnvScrubbed:             true,
	}
}

// testPublicKeyB64 generates a real X25519 keypair for tests and returns the
// provider public key. The matching private key is cached so test providers can
// encrypt response chunks back to the coordinator.
func testPublicKeyB64() string {
	pub, priv, err := box.GenerateKey(rand.Reader)
	if err != nil {
		panic(err)
	}
	key := base64.StdEncoding.EncodeToString(pub[:])
	testProviderKeys.Store(key, testProviderKeyPair{
		public:  *pub,
		private: *priv,
	})
	return key
}

func testEncryptedChunk(t *testing.T, inferReq protocol.InferenceRequestMessage, providerPublicKey, sseData string) protocol.InferenceResponseChunkMessage {
	t.Helper()
	if inferReq.EncryptedBody == nil {
		t.Fatal("inference request missing encrypted body")
	}

	value, ok := testProviderKeys.Load(providerPublicKey)
	if !ok {
		t.Fatalf("missing provider keypair for %q", providerPublicKey)
	}
	keypair := value.(testProviderKeyPair)
	coordinatorPub, err := e2e.ParsePublicKey(inferReq.EncryptedBody.EphemeralPublicKey)
	if err != nil {
		t.Fatalf("parse coordinator public key: %v", err)
	}
	payload, err := e2e.Encrypt([]byte(sseData), coordinatorPub, &e2e.SessionKeys{
		PublicKey:  keypair.public,
		PrivateKey: keypair.private,
	})
	if err != nil {
		t.Fatalf("encrypt test chunk: %v", err)
	}

	return protocol.InferenceResponseChunkMessage{
		Type:      protocol.TypeInferenceResponseChunk,
		RequestID: inferReq.RequestID,
		EncryptedData: &protocol.EncryptedPayload{
			EphemeralPublicKey: payload.EphemeralPublicKey,
			Ciphertext:         payload.Ciphertext,
		},
	}
}

func writeEncryptedTestChunk(t *testing.T, ctx context.Context, conn *websocket.Conn, inferReq protocol.InferenceRequestMessage, providerPublicKey, sseData string) {
	t.Helper()
	chunk := testEncryptedChunk(t, inferReq, providerPublicKey, sseData)
	data, _ := json.Marshal(chunk)
	if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
		t.Fatalf("write encrypted chunk: %v", err)
	}
}
