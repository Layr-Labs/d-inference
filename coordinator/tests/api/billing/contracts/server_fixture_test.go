package billing_test

import (
	"log/slog"
	"net/http"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
)

var testConsumerID = store.LegacyAccountID("test-key")

// Keep references to fixture-owned dependencies without exposing server internals.
type billingFixture struct {
	*api.Server
	registry *registry.Registry
	logger   *slog.Logger
	sessions *testkit.Sessions
}

func newBillingFixture(t *testing.T, reg *registry.Registry, st store.Store, cfg api.ServerConfig, logger *slog.Logger) *billingFixture {
	t.Helper()
	srv := testkit.NewServer(t, reg, st, cfg, logger)
	return &billingFixture{Server: srv, registry: reg, logger: logger, sessions: testkit.NewSessions(t, srv, st)}
}

func (f *billingFixture) withUser(req *http.Request, user *store.User) *http.Request {
	req.Header.Set("Authorization", "Bearer "+f.sessions.Token(user.AccountID))
	return req
}

func pricingTestServer(t *testing.T, cfg api.ServerConfig) (*billingFixture, *memory.MemoryStore) {
	t.Helper()
	logger := slog.New(slog.DiscardHandler)
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	return newBillingFixture(t, registry.New(logger), st, cfg, logger), st
}

func waitForCond(timeout time.Duration, condition func() bool) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if condition() {
			return true
		}
		time.Sleep(10 * time.Millisecond)
	}
	return condition()
}
