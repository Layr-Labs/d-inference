package operations_test

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	api "github.com/eigeninference/d-inference/coordinator/api"
	testkit "github.com/eigeninference/d-inference/coordinator/api/tests/internal/testkit"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestEncryptionKeyEndpoint(t *testing.T) {
	fixture := testkit.New(t, api.ServerConfig{})
	coordKey, err := e2e.DeriveCoordinatorKey("praise warfare warrior rebuild raven garlic kite blast crew impulse pencil hidden")
	if err != nil {
		t.Fatalf("derive coordinator key: %v", err)
	}
	fixture.Server.SetCoordinatorKey(coordKey)
	ts := httptest.NewServer(fixture.Server.Handler())
	t.Cleanup(ts.Close)

	resp, err := http.Get(ts.URL + "/v1/encryption-key")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	var body struct {
		KID       string `json:"kid"`
		PublicKey string `json:"public_key"`
		Algorithm string `json:"algorithm"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if body.KID != coordKey.KID {
		t.Fatalf("kid mismatch: %q != %q", body.KID, coordKey.KID)
	}
	if body.Algorithm != "x25519-nacl-box" {
		t.Fatalf("algorithm = %q", body.Algorithm)
	}
	pub, err := base64.StdEncoding.DecodeString(body.PublicKey)
	if err != nil || len(pub) != 32 {
		t.Fatalf("public_key invalid: err=%v len=%d", err, len(pub))
	}
	if !bytes.Equal(pub, coordKey.PublicKey[:]) {
		t.Fatal("published public key differs from derived public key")
	}
}

func TestEncryptionKeyEndpoint_Disabled(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := testkit.NewServer(t, reg, st, api.ServerConfig{}, logger)
	// No SetCoordinatorKey call → endpoint should report 503.

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/v1/encryption-key")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", resp.StatusCode)
	}
}
