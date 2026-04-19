package api

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/asn1"
	"encoding/base64"
	"io"
	"log/slog"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/eigeninference/coordinator/internal/attestation"
	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/eigeninference/coordinator/internal/store"
)

// signWith returns a base64 DER signature for the given message under the
// given P-256 private key.
func signWith(t *testing.T, priv *ecdsa.PrivateKey, msg []byte) string {
	t.Helper()
	h := sha256.Sum256(msg)
	r, s, err := ecdsa.Sign(rand.Reader, priv, h[:])
	if err != nil {
		t.Fatal(err)
	}
	der, err := asn1.Marshal(struct{ R, S *big.Int }{r, s})
	if err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(der)
}

func rawPubKey(priv *ecdsa.PrivateKey) string {
	x := priv.PublicKey.X.Bytes()
	y := priv.PublicKey.Y.Bytes()
	pad := func(b []byte) []byte {
		out := make([]byte, 32)
		copy(out[32-len(b):], b)
		return out
	}
	raw := append(pad(x), pad(y)...)
	return base64.StdEncoding.EncodeToString(raw)
}

func TestImageUpload_RequiresValidProviderSignature(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

	// Set up a provider with a real SE pubkey on its attestation result.
	priv, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	pubB64 := rawPubKey(priv)

	regMsg := &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64, MemoryBandwidthGBs: 400},
		Backend:  "test",
	}
	p := reg.Register("p-image", nil, regMsg)
	p.Mu().Lock()
	p.AttestationResult = &attestation.VerificationResult{PublicKey: pubB64}
	p.Mu().Unlock()
	pr := &registry.PendingRequest{RequestID: "img-1", Model: "m"}
	p.AddPending(pr)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	imageBytes := []byte("PNG-DATA-NOT-REALLY")

	// 1) No signature → 401.
	resp, err := http.Post(ts.URL+"/v1/provider/image-upload?request_id=img-1", "image/png", bytes.NewReader(imageBytes))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 401 {
		t.Errorf("missing signature: status = %d, want 401", resp.StatusCode)
	}

	// 2) Wrong signature → 401.
	otherPriv, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	wrongSig := signWith(t, otherPriv, []byte("img-1"))
	req, _ := http.NewRequest("POST", ts.URL+"/v1/provider/image-upload?request_id=img-1", bytes.NewReader(imageBytes))
	req.Header.Set("X-Provider-Signature", wrongSig)
	req.Header.Set("Content-Type", "image/png")
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 401 {
		t.Errorf("wrong signature: status = %d, want 401", resp.StatusCode)
	}

	// 3) Correct signature → 200.
	correctSig := signWith(t, priv, []byte("img-1"))
	req, _ = http.NewRequest("POST", ts.URL+"/v1/provider/image-upload?request_id=img-1", bytes.NewReader(imageBytes))
	req.Header.Set("X-Provider-Signature", correctSig)
	req.Header.Set("Content-Type", "image/png")
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Errorf("correct signature: status = %d, want 200", resp.StatusCode)
	}

	// 4) Wrong request_id → 403.
	resp, err = http.Post(ts.URL+"/v1/provider/image-upload?request_id=does-not-exist", "image/png", bytes.NewReader(imageBytes))
	if err != nil {
		t.Fatal(err)
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 403 {
		t.Errorf("unknown request_id: status = %d, want 403", resp.StatusCode)
	}
}
