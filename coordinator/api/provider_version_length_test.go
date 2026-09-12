package api

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"nhooyr.io/websocket"
)

// A provider whose version string exceeds maxProviderVersionLength is refused
// at registration with a policy-violation close and never enters the registry;
// a normal version registers as before.
func TestProviderRegistrationRejectsOversizedVersion(t *testing.T) {
	_, reg, _, ts := setupTestServer(t)
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	register := func(version string) (*websocket.Conn, error) {
		wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
		conn, _, err := websocket.Dial(ctx, wsURL, nil)
		if err != nil {
			t.Fatalf("dial: %v", err)
		}
		regMsg := protocol.RegisterMessage{
			Type:                    protocol.TypeRegister,
			Hardware:                protocol.Hardware{MachineModel: "Mac15,8", ChipName: "Apple M3 Max", MemoryGB: 64},
			Models:                  []protocol.ModelInfo{{ID: "version-len-model", ModelType: "chat"}},
			Backend:                 "mlx-swift",
			Version:                 version,
			PublicKey:               testPublicKeyB64(),
			EncryptedResponseChunks: true,
			PrivacyCapabilities:     testPrivacyCaps(),
		}
		data, _ := json.Marshal(regMsg)
		if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
			t.Fatalf("write register: %v", err)
		}
		// The coordinator either closes the socket (rejection) or starts the
		// challenge loop (accepted): read one frame to observe which.
		_, _, err = conn.Read(ctx)
		return conn, err
	}

	conn, err := register(strings.Repeat("9.", maxProviderVersionLength) + "0")
	if err == nil {
		t.Fatal("oversized version was accepted")
	}
	if status := websocket.CloseStatus(err); status != websocket.StatusPolicyViolation {
		t.Fatalf("close status = %v, want policy violation (err=%v)", status, err)
	}
	conn.Close(websocket.StatusNormalClosure, "")
	if got := reg.OnlineCount(); got != 0 {
		t.Fatalf("rejected provider is online: count=%d", got)
	}

	conn, err = register("0.8.15")
	if err != nil {
		t.Fatalf("normal version rejected: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")
	if got := reg.OnlineCount(); got != 1 {
		t.Fatalf("normal provider not registered: count=%d", got)
	}
}
