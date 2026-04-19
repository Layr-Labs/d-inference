package api

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"log/slog"
	"math/big"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/eigeninference/coordinator/internal/store"
	"nhooyr.io/websocket"
)

// TestRegister_RejectsStaleAttestation simulates a captured-and-replayed
// attestation blob (F5). The signature verifies but the timestamp is older
// than MaxAttestationAge, so trust must drop to none.
func TestRegister_RejectsStaleAttestation(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	// Build a signed attestation with a very old timestamp.
	priv, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	staleTimestamp := time.Now().Add(-48 * time.Hour).UTC().Format(time.RFC3339)

	xBytes := priv.PublicKey.X.Bytes()
	yBytes := priv.PublicKey.Y.Bytes()
	pad := func(b []byte) []byte {
		out := make([]byte, 32)
		copy(out[32-len(b):], b)
		return out
	}
	pkRaw := append(pad(xBytes), pad(yBytes)...)
	pkB64 := base64.StdEncoding.EncodeToString(pkRaw)

	blob := map[string]any{
		"authenticatedRootEnabled": true,
		"chipName":                 "Apple M3 Max",
		"hardwareModel":            "Mac15,8",
		"hypervisorActive":         false,
		"osVersion":                "15.3.0",
		"publicKey":                pkB64,
		"rdmaDisabled":             true,
		"secureBootEnabled":        true,
		"secureEnclaveAvailable":   true,
		"sipEnabled":               true,
		"timestamp":                staleTimestamp,
	}
	blobJSON, _ := json.Marshal(blob)
	h := sha256.Sum256(blobJSON)
	r, s, _ := ecdsa.Sign(rand.Reader, priv, h[:])
	der, _ := asn1.Marshal(struct{ R, S *big.Int }{r, s})
	signed := map[string]any{
		"attestation": blob,
		"signature":   base64.StdEncoding.EncodeToString(der),
	}
	attestData, _ := json.Marshal(signed)

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(t.Context(), wsURL, nil)
	if err != nil {
		t.Fatalf("ws dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	regMsg := protocol.RegisterMessage{
		Type:        protocol.TypeRegister,
		Hardware:    protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64, MemoryBandwidthGBs: 400},
		Backend:     "test",
		PublicKey:   pkB64,
		Attestation: attestData,
	}
	regData, _ := json.Marshal(regMsg)
	conn.Write(t.Context(), websocket.MessageText, regData)
	time.Sleep(200 * time.Millisecond)

	// Find the provider and verify it's NOT trusted.
	for _, id := range reg.ProviderIDs() {
		p := reg.GetProvider(id)
		if p == nil {
			continue
		}
		p.Mu().Lock()
		trust := p.TrustLevel
		p.Mu().Unlock()
		if trust != registry.TrustNone {
			t.Fatalf("expected TrustNone for stale attestation, got %s", trust)
		}
	}
}
