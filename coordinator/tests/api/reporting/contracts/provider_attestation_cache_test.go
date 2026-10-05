package reporting_test

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
)

// Trust-level changes appear after the public projection's two-second TTL.
func TestProviderAttestationCache_RepeatHitThenExpiry(t *testing.T) {
	f := testkit.New(t, api.ServerConfig{})
	f.Server.SetSkipChallenge(true)
	ts := httptest.NewServer(f.Server.Handler())
	t.Cleanup(ts.Close)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	conn := testkit.ConnectProvider(t, ctx, ts.URL, []protocol.ModelInfo{{ID: "attest-model"}}, testkit.PublicKeyB64())
	t.Cleanup(func() { conn.CloseNow() })
	deadline := time.Now().Add(5 * time.Second)
	for testkit.FindProviderByModel(f.Registry, "attest-model") == nil {
		if time.Now().After(deadline) {
			t.Fatal("provider registration timed out")
		}
		time.Sleep(time.Millisecond)
	}
	ids := f.Registry.ProviderIDs()
	if len(ids) != 1 {
		t.Fatalf("providers = %v", ids)
	}
	f.Registry.SetTrustLevel(ids[0], registry.TrustHardware)
	read := func() []byte {
		t.Helper()
		r := httptest.NewRecorder()
		f.Server.Handler().ServeHTTP(r, httptest.NewRequest(http.MethodGet, "/v1/providers/attestation", nil))
		if r.Code != http.StatusOK {
			t.Fatalf("status = %d body = %s", r.Code, r.Body.String())
		}
		return r.Body.Bytes()
	}
	first := read()
	if !strings.Contains(string(first), `"trust_level":"hardware"`) {
		t.Fatalf("expected hardware trust: %s", first)
	}
	second := read()
	if !bytes.Equal(first, second) {
		t.Fatalf("repeat diverged:\n%s\n%s", first, second)
	}
	f.Registry.SetTrustLevel(ids[0], registry.TrustSelfSigned)
	if !bytes.Equal(first, read()) {
		t.Fatal("attestation changed inside the TTL; expected the cached body")
	}
	time.Sleep(2100 * time.Millisecond)
	fresh := read()
	if !strings.Contains(string(fresh), `"trust_level":"self_signed"`) {
		t.Fatalf("post-expiry attestation still stale: %s", fresh)
	}
}
