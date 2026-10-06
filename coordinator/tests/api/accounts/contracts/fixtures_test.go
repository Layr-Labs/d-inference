package accounts_test

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
)

type accountTestServer struct {
	*api.Server
	registry *registry.Registry
	sessions *testkit.Sessions
}

func newKeyTestServer(t *testing.T) (*accountTestServer, *memory.MemoryStore) {
	t.Helper()
	f := testkit.New(t, api.ServerConfig{})
	return &accountTestServer{Server: f.Server, registry: f.Registry, sessions: testkit.NewSessions(t, f.Server, f.Store)}, f.Store
}

func (s *accountTestServer) request(method, target, body, accountID string) *http.Request {
	r := httptest.NewRequest(method, target, strings.NewReader(body))
	r.Header.Set("Authorization", "Bearer "+s.sessions.Token(accountID))
	return r
}
