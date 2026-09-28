package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"nhooyr.io/websocket"
)

func TestNativePairAPIDefaultDisabledAndUnregisteredFrameRefused(t *testing.T) {
	s, _ := testServer(t)
	defer s.Close()
	if s.nativePairs != nil {
		t.Fatal("default started native authorization")
	}
	if _, e := s.BeginNativePair([2]*registry.Provider{}, "claimed-hash", time.Minute); e == nil {
		t.Fatal("unconfigured selector approved")
	}
	server := httptest.NewServer(http.HandlerFunc(s.handleProviderWS))
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	conn, _, e := websocket.Dial(ctx, "ws"+strings.TrimPrefix(server.URL, "http"), nil)
	if e != nil {
		t.Fatal(e)
	}
	defer conn.CloseNow()
	// Syntactically valid public message does not imply registration, native
	// approval or an active handle. It enters the actual provider read loop.
	b := []byte(`{"type":"native_pair_hello","version":1,"member_nonce":"` + strings.Repeat("1", 64) + `","epoch":"` + strings.Repeat("2", 32) + `","generation":1,"sequence":1,"payload":"","signature":"MAYCAQECAQE="}`)
	if e = conn.Write(ctx, websocket.MessageText, b); e != nil {
		t.Fatal(e)
	}
	_, _, e = conn.Read(ctx)
	if websocket.CloseStatus(e) != websocket.StatusPolicyViolation {
		t.Fatalf("want policy refusal, got %v", e)
	}
}
func TestNativePairActualTLSStateNotForwardedHeader(t *testing.T) {
	r := registry.New(quietLogger())
	nonce := strings.Repeat("3", 64)
	p := r.Register("tls-fixture", nil, &protocol.RegisterMessage{ExecutionRole: protocol.ExecutionRoleClusterMember, MemberRegistrationNonce: nonce})
	defer r.Disconnect(p.ID)
	hash := [32]byte{1}
	catalog, e := registry.NewNativeRuntimeCatalog([]registry.NativeRuntimeApproval{{ID: "fixture", Model: "fixture", Generation: 1, PlanSHA256: hash, ArtifactSHA256: hash, NativeRuntimeSHA256: hash, MetallibSHA256: hash, ResourceLibrarySHA256: hash, CapabilitySHA256: hash, ResourcePolicySHA256: hash, ProfileSHA256: hash, Schedule: 1, MaximumTransportFrame: 4136, MaximumPlaintext: 4096, MaximumRecords: 64, MaximumCumulativePlaintext: 262144, AllowedChips: []string{"fixture"}, NotAfter: time.Now().Add(time.Hour)}})
	if e != nil {
		t.Fatal(e)
	}
	c := registry.NewNativePairCoordinator(r, catalog)
	defer c.Close()
	handler := http.HandlerFunc(func(w http.ResponseWriter, q *http.Request) {
		n, e := c.Attach(p, nonce, q.TLS)
		if e != nil {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		c.Detach(n)
		w.WriteHeader(http.StatusNoContent)
	})
	plain := httptest.NewServer(handler)
	defer plain.Close()
	request, _ := http.NewRequest(http.MethodGet, plain.URL, nil)
	request.Header.Set("X-Forwarded-Proto", "https")
	response, e := plain.Client().Do(request)
	if e != nil {
		t.Fatal(e)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusForbidden {
		t.Fatal("forwarded header became TLS proof")
	}
	secure := httptest.NewTLSServer(handler)
	defer secure.Close()
	response, e = secure.Client().Get(secure.URL)
	if e != nil {
		t.Fatal(e)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		t.Fatal("actual completed TLS handshake refused")
	}
}
